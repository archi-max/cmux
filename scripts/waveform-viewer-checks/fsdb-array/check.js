// run.sh fsdb-array: fsdb-helper-v2's tree.js nests a scope's vars the way the FSDB reader
// reports them. The reader's callbacks are replayed by a stand-in addon from the order a real
// dump gave (VCS, packed arrays dumped with FSDB_PACKED_MODE=0 and +packedmda): an ARRAY_BEGIN
// before an array's elements and an ARRAY_END after, nested for each dimension. No FSDB file
// is needed or kept.
// Usage: node check.js <fsdb-helper-v2 folder>
'use strict';
const path = require('node:path');
const assert = require('node:assert');

const { readScopeTree } = require(path.resolve(process.argv[2], 'tree.js'));

// The reader's callbacks for scope `tb.u` of that dump, in order.
const events = [
  ['var', 'clk', 1, 0, 0], ['var', 'rst', 1, 0, 0],
  ['begin', 'dfp_addr[1:0]'], ['var', 'dfp_addr[1][31:0]', 32, 31, 0], ['var', 'dfp_addr[0][31:0]', 32, 31, 0], ['end', 2],
  ['begin', 'cube[1:0]'],
  ['begin', 'cube[1][2:0]'], ['var', 'cube[1][2][3:0]', 4, 3, 0], ['var', 'cube[1][1][3:0]', 4, 3, 0], ['var', 'cube[1][0][3:0]', 4, 3, 0], ['end', 3],
  ['begin', 'cube[0][2:0]'], ['var', 'cube[0][2][3:0]', 4, 3, 0], ['var', 'cube[0][1][3:0]', 4, 3, 0], ['var', 'cube[0][0][3:0]', 4, 3, 0], ['end', 3],
  ['end', 2],
  // An array with no elements dumped, and an array of packed structs (the reader brackets each
  // element's fields with STRUCT events, which open no scope; the fields stay in the array).
  // The field names here are illustrative: no real struct-array dump has been read yet.
  ['begin', 'none[1:0]'], ['end', 2],
  ['begin', 'pairs[1:0]'],
  ['sbegin', 'pairs[1]'], ['var', 'pairs[1].a[3:0]', 4, 3, 0], ['var', 'pairs[1].b[3:0]', 4, 3, 0], ['send'],
  ['sbegin', 'pairs[0]'], ['var', 'pairs[0].a[3:0]', 4, 3, 0], ['var', 'pairs[0].b[3:0]', 4, 3, 0], ['send'],
  ['end', 2],
  ['var', 'flat[7:0]', 8, 7, 0],
  // An END with no BEGIN (a reader quirk) must not pop the scope itself.
  ['end', 0], ['var', 'late', 1, 0, 0],
];
let netlistId = 1;
const addon = {
  readVars(scopePath, offset, onVar, onArrayBegin, onArrayEnd, onStructBegin, onStructEnd) {
    assert.strictEqual(scopePath, 'tb.u');
    assert.strictEqual(offset, 7);
    for (const e of events) {
      if (e[0] === 'var') { onVar(e[1], 'reg', 'BitVector', scopePath, netlistId++, netlistId, e[2], e[3], e[4]); }
      if (e[0] === 'begin') { onArrayBegin(e[1], scopePath, netlistId++); }
      if (e[0] === 'end') { onArrayEnd(e[1]); }
      if (e[0] === 'sbegin') { onStructBegin(e[1], scopePath, netlistId++); }
      if (e[0] === 'send') { onStructEnd(); }
    }
  },
};
const strip = (name, width, msb, lsb) => (width > 1 && name.endsWith(`[${msb}:${lsb}]`) ? name.slice(0, -`[${msb}:${lsb}]`.length) : name);
const tree = readScopeTree(addon, 'tb.u', 7, (name, type, encoding, varPath, nid, signalId, width, msb, lsb) => ({ name: strip(name, width, msb, lsb), width }));

let fails = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) { fails++; } };
const names = (list) => list.map((x) => x.name);
const shape = (node) => ({ name: node.name, type: node.type, scopes: node.inline.scopes.map(shape), vars: names(node.inline.vars) });

check(JSON.stringify(names(tree.vars)) === JSON.stringify(['clk', 'rst', 'flat', 'late']), `the scope's own vars stay in it: ${names(tree.vars)}`);
check(JSON.stringify(names(tree.scopes)) === JSON.stringify(['dfp_addr[1:0]', 'cube[1:0]', 'none[1:0]', 'pairs[1:0]']), `each array is a scope of the reply: ${names(tree.scopes)}`);
const addr = tree.scopes[0] && shape(tree.scopes[0]);
check(JSON.stringify(addr) === JSON.stringify({ name: 'dfp_addr[1:0]', type: 'array', scopes: [], vars: ['dfp_addr[1]', 'dfp_addr[0]'] }),
  `a packed 2-D array holds its elements, by their full names: ${JSON.stringify(addr)}`);
const cube = tree.scopes[1] && shape(tree.scopes[1]);
check(JSON.stringify(cube) === JSON.stringify({ name: 'cube[1:0]', type: 'array', scopes: [
  { name: 'cube[1][2:0]', type: 'array', scopes: [], vars: ['cube[1][2]', 'cube[1][1]', 'cube[1][0]'] },
  { name: 'cube[0][2:0]', type: 'array', scopes: [], vars: ['cube[0][2]', 'cube[0][1]', 'cube[0][0]'] }], vars: [] }),
  `a 3-D array nests by dimension: ${JSON.stringify(cube)}`);
const none = tree.scopes[2] && shape(tree.scopes[2]);
check(JSON.stringify(none) === JSON.stringify({ name: 'none[1:0]', type: 'array', scopes: [], vars: [] }),
  `an array with no elements is an empty node: ${JSON.stringify(none)}`);
const pairs = tree.scopes[3] && shape(tree.scopes[3]);
check(JSON.stringify(pairs) === JSON.stringify({ name: 'pairs[1:0]', type: 'array', scopes: [], vars: ['pairs[1].a', 'pairs[1].b', 'pairs[0].a', 'pairs[0].b'] }),
  `an array of structs holds its fields, in order, and the struct events open nothing: ${JSON.stringify(pairs)}`);
console.log(fails ? `FSDB ARRAY CHECKS FAILED: ${fails}` : 'FSDB ARRAY CHECKS PASSED');
process.exit(fails ? 1 : 0);
