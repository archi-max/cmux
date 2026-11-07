// run.sh fsdb-scopes: fsdb-helper-v2 lists each scope path once. VCS writes every interface
// modport port as a scope tree of its own that re-enters its path from the root
// (tb > u_soc > up[1] > slave), after the design's tree, so the reader's top level holds the
// testbench scope once per port plus once for the design. A stand-in addon replays that shape
// (taken from a real dump's scope offsets; no FSDB is needed or kept) through tree.js's
// scopeTree, which helper.js's open/children answer from.
// Usage: node check.js <fsdb-helper-v2 folder>
'use strict';
const path = require('node:path');

const dir = path.resolve(process.argv[2]);
let fails = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) { fails++; } };

// Scope offsets and parents as the reader reports them. 0 is the reader's `$` root scope.
// 1-6: the design's tree; 7-10, 11-14: one port tree each, re-entering tb and u_soc.
const S = [
  { name: '$root', parent: -1 },
  { name: 'tb', parent: -1, vars: ['clk', 'rst_n', 'done'] },
  { name: 'u_soc', parent: 1, vars: ['clk', 'rst_n', 'done'] },
  { name: 'up[1]', parent: 2, vars: ['valid', 'ready'] },
  { name: 'slave', parent: 3, vars: ['valid', 'ready'] },
  { name: 'up[0]', parent: 2, vars: ['valid', 'ready'], arrays: ['mem[3:0]'] },
  { name: 'slave', parent: 5, vars: ['valid', 'ready'] },
  { name: 'tb', parent: -1, vars: [] },
  { name: 'u_soc', parent: 7, vars: [] },
  { name: 'up[1]', parent: 8, vars: [] },
  { name: 'slave', parent: 9, vars: ['valid', 'ready', 'extra'] },
  { name: 'tb', parent: -1, vars: [] },
  { name: 'u_soc', parent: 11, vars: [] },
  { name: 'up[0]', parent: 12, vars: [], arrays: ['mem[3:0]'] },
  { name: 'slave', parent: 13, vars: ['valid', 'ready'] },
];
const scopeObj = (i) => ({ name: S[i].name, type: 'module', netlistId: i, scopeOffsetIdx: i });
let signal = 100;
const addon = {
  readScopes: () => S.map((s, i) => [s, i]).filter(([s]) => s.parent === -1).map(([, i]) => scopeObj(i)),
  getScopeChildren(idx, start) {
    const kids = S.map((s, i) => [s, i]).filter(([s]) => s.parent === idx).map(([, i]) => scopeObj(i)).slice(start);
    return { scopes: kids, totalReturned: kids.length, remainingItems: 0 };
  },
  readVars(scopePath, idx, onVar, onArrayBegin, onArrayEnd) {
    for (const v of S[idx].vars || []) { onVar(v, 'reg', 'BitVector', scopePath, signal, signal++, 1, 0, 0); }
    for (const a of S[idx].arrays || []) { onArrayBegin(a); onVar(a.replace('[3:0]', '[0]'), 'reg', 'BitVector', scopePath, signal, signal++, 1, 0, 0); onArrayEnd(2); }
  },
};

const tree = require(path.join(dir, 'tree.js'));
check(typeof tree.scopeTree === 'function', 'tree.js exports scopeTree');

// The view the helper's open/children answer. Before scopeTree, helper.js listed
// readScopes() minus `$` scopes, and a scope's children as the reader gave them.
const view = tree.scopeTree ? tree.scopeTree(addon) : {
  top: () => addon.readScopes().filter((s) => !s.name.startsWith('$')),
  children: (idx, p, onVar) => {
    const t = tree.readScopeTree(addon, p, idx, onVar);
    return { scopes: addon.getScopeChildren(idx, 0).scopes.concat(t.scopes), vars: t.vars };
  },
};
const onVar = (name, type, encoding, varPath, netlistId, signalId) => ({ name, signalId });
const top = view.top();
check(JSON.stringify(top.map((s) => s.name)) === JSON.stringify(['tb']), `the top level lists tb once: ${top.map((s) => s.name + '#' + s.scopeOffsetIdx)}`);
check(top[0] && top[0].scopeOffsetIdx === 1, 'the design\'s own tb (the first) is the one shown');
const kids = (s, p) => view.children(s.scopeOffsetIdx, p, onVar);
const tb = top[0] ? kids(top[0], 'tb') : { scopes: [], vars: [] };
check(JSON.stringify(tb.scopes.map((s) => s.name)) === JSON.stringify(['u_soc']), `tb has one u_soc: ${tb.scopes.map((s) => s.name)}`);
check(JSON.stringify(tb.vars.map((v) => v.name)) === JSON.stringify(['clk', 'rst_n', 'done']), `tb's vars once each: ${tb.vars.map((v) => v.name)}`);
const soc = tb.scopes[0] ? kids(tb.scopes[0], 'tb.u_soc') : { scopes: [], vars: [] };
check(JSON.stringify(soc.scopes.map((s) => s.name)) === JSON.stringify(['up[1]', 'up[0]']), `u_soc has up[1] and up[0] once each: ${soc.scopes.map((s) => s.name)}`);
const up1 = soc.scopes.find((s) => s.name === 'up[1]');
const up1k = up1 ? kids(up1, 'tb.u_soc.up[1]') : { scopes: [], vars: [] };
check(JSON.stringify(up1k.scopes.map((s) => s.name)) === JSON.stringify(['slave']), `up[1] has one slave: ${up1k.scopes.map((s) => s.name)}`);
const slave = up1k.scopes[0] ? kids(up1k.scopes[0], 'tb.u_soc.up[1].slave') : { scopes: [], vars: [] };
check(JSON.stringify(slave.vars.map((v) => v.name)) === JSON.stringify(['valid', 'ready', 'extra']),
  `slave's vars: the design tree's, then any only a port tree has, each once: ${slave.vars.map((v) => v.name)}`);
const up0 = soc.scopes.find((s) => s.name === 'up[0]');
const up0k = up0 ? kids(up0, 'tb.u_soc.up[0]') : { scopes: [], vars: [] };
check(JSON.stringify(up0k.scopes.map((s) => s.name + ':' + (s.type || ''))) === JSON.stringify(['slave:module', 'mem[3:0]:array']),
  `up[0]: its child scope once, then its array once: ${up0k.scopes.map((s) => s.name)}`);
// A second open (a reload) starts over: the same answers, not members added twice.
const again = view.top();
const tb2 = again[0] ? kids(again[0], 'tb') : { scopes: [] };
check(again.length === 1 && tb2.scopes.length === 1, 'listing the top level again gives the same single tb and u_soc');

// helper.js wires it: the coordinator's index has each path once (a unique suffix such as
// `up[1].slave.valid` stays unique) and its open/children answers come from scopeTree.
const src = require('node:fs').readFileSync(path.join(dir, 'helper.js'), 'utf8');
check(/scopeTree\(addon\)/.test(src) && /\.top\(\)/.test(src), 'helper.js answers open from scopeTree');
check(/\.children\(scopeOffsetIdx, scopePath/.test(src), 'helper.js answers children from scopeTree');
check(/if \(byPath\.has\(v\.path\)\) \{ return; \}/.test(src), 'helper.js indexes each path once');

console.log(fails ? `FSDB SCOPES CHECKS FAILED: ${fails}` : 'FSDB SCOPES CHECKS PASSED');
process.exit(fails ? 1 : 0);
