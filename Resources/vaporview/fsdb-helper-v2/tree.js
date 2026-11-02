// Part of cmux's FSDB helper v2, written for cmux. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), whose helper it extends; see ../LICENSE.
// cmux: a scope's variables as the FSDB reader nests them. readVars reports an
// ARRAY_BEGIN before an array's elements and an ARRAY_END after (nested for each
// dimension). Each array becomes a scope of the `children` reply, `type: 'array'`,
// with its contents `inline` ({ scopes, vars }): the reader has no scope offset for
// it to be asked for later. Elements keep their full names (`dfp_addr[1]`), so their
// paths (scope.name) are the same as when the arrays were left out of the tree.
// A packed array is written this way only by a dump made with FSDB_PACKED_MODE=0
// and packed MDA dumping on; otherwise it comes as one vector.
'use strict';

const MAX_DEPTH = 16;

// onVar(...readVars' var arguments) -> the var's reply entry, or null to leave it out.
function readScopeTree(addon, scopePath, scopeOffsetIdx, onVar) {
  const top = { scopes: [], vars: [] };
  const stack = [top];
  let ignored = 0;  // BEGINs past MAX_DEPTH, whose ENDs are ignored too
  addon.readVars(scopePath, scopeOffsetIdx,
    (...args) => { const v = onVar(...args); if (v) { stack[stack.length - 1].vars.push(v); } },
    (name) => {
      if (stack.length > MAX_DEPTH) { ignored++; return; }
      const node = { name: String(name), type: 'array', inline: { scopes: [], vars: [] } };
      stack[stack.length - 1].scopes.push(node);
      stack.push(node.inline);
    },
    () => {
      if (ignored > 0) { ignored--; } else if (stack.length > 1) { stack.pop(); }
    },
    () => {}, () => {});
  return top;
}

module.exports = { readScopeTree };
