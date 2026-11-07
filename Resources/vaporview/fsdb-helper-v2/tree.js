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

// cmux: the netlist with one node per scope path. A dump can hold several scope trees
// that re-enter the same path from the root: VCS writes each interface modport port
// (tb.u_soc.up[1].slave) as a tree of its own, tb > u_soc > up[1] > slave, after the
// design's tree, so the reader's top level held the testbench scope ten times. Scopes
// with the same name under the same (merged) parent are one node, shown with the
// first one's scopeOffsetIdx; asking for its children reads every member and lists
// each child scope, array and var name once (the first member's wins). Pure JS over
// the addon's readScopes / getScopeChildren / readVars; `$` scopes are left out.
function scopeTree(addon) {
  const members = new Map();  // shown scopeOffsetIdx -> the offsets that make up its path
  const merge = (list) => {
    const byName = new Map();
    const out = [];
    for (const s of list) {
      if (String(s.name).startsWith('$')) { continue; }
      const first = byName.get(s.name);
      if (first) { members.get(first.scopeOffsetIdx).push(s.scopeOffsetIdx); continue; }
      byName.set(s.name, s);
      members.set(s.scopeOffsetIdx, [s.scopeOffsetIdx]);
      out.push(s);
    }
    return out;
  };
  const childScopes = (idx) => {
    const scopes = [];
    for (let start = 0, guard = 256; guard-- > 0;) {
      const r = addon.getScopeChildren(idx, start);
      scopes.push(...r.scopes);
      start += r.totalReturned;
      if (!r.totalReturned || !(r.remainingItems > 0)) { break; }
    }
    return scopes;
  };
  return {
    top() { members.clear(); return merge(addon.readScopes()); },
    // The offsets read for a shown scope (itself only, for one not listed yet).
    members: (idx) => members.get(idx) || [idx],
    children(idx, scopePath, onVar) {
      const ids = members.get(idx) || [idx];
      const scopes = merge(ids.flatMap(childScopes));
      const arrays = [], vars = [], seenArrays = new Set(), seenVars = new Set();
      for (const id of ids) {
        const tree = readScopeTree(addon, scopePath, id, onVar);
        for (const a of tree.scopes) { if (!seenArrays.has(a.name)) { seenArrays.add(a.name); arrays.push(a); } }
        for (const v of tree.vars) { if (!seenVars.has(v.name)) { seenVars.add(v.name); vars.push(v); } }
      }
      return { scopes: scopes.concat(arrays), vars };
    },
  };
}

module.exports = { readScopeTree, scopeTree };
