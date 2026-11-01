// Synthetic RVFI commit streams for the machine-state checks (our own). Each variant is a random but
// self-consistent run: hidden initial registers and memory, ALU ops, loads and stores of every size
// (unaligned within a word), AMOs, traps that leave junk on the rd and mem buses, an rd = x0 write,
// stalls, valid held high across cycles, a self-loop, x before reset, NRET 2 with same-cycle commits.
// It writes the signals as a VCD (or hands them over in memory) together with what a correct replay
// must show, computed here by brute force (a second implementation of the rules in §3.1).
//
//   node make-rvfi-vcd.js <outdir>           writes <variant>.vcd and <variant>.json for every variant
//   makeRvfi(variant) -> { signals: [{ path, width, changes }], edges, image, expect }   (JSC, node)
(function (root) {
  'use strict';

  const VARIANTS = {
    // NRET 1, rvfi_ prefix, byte-relative masks.
    prefixed: { nret: 1, naming: 'prefixed', mask: 'byte', seed: 11, n: 700 },
    // NRET 2 as packed vectors (the spec's way), word-relative masks.
    packed2: { nret: 2, naming: 'prefixed', mask: 'word', seed: 23, n: 900, swap: true },
    // NRET 2 as per-channel array elements valid[0], valid[1] with `inst` for insn (field set, no prefix).
    array2: { nret: 2, naming: 'array', mask: 'byte', seed: 37, n: 900 },
    // A struct dumped as a scope (tb.core.rvfi.valid ...), NRET 1, word-relative.
    struct: { nret: 1, naming: 'struct', mask: 'word', seed: 41, n: 600 },
    // A common prefix (monitor_valid ...), no order: sorted by time.
    monitor: { nret: 1, naming: 'monitor', mask: 'byte', seed: 53, n: 600, noOrder: true },
    // A forwarding bug: one rs1_rdata disagrees with the register's value.
    forward: { nret: 1, naming: 'prefixed', mask: 'byte', seed: 67, n: 400, bug: 'forward' },
  };

  function rng(seed) {
    let x = seed >>> 0 || 1;
    return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
  }

  function makeRvfi(name) {
    const v = VARIANTS[name];
    const rand = rng(v.seed);
    const ri = (n) => Math.floor(rand() * n);
    const u32 = () => (ri(65536) * 65536 + ri(65536)) >>> 0;
    // The hidden truth: registers and a data region a load may read before anything writes it.
    const regs = [0];
    for (let r = 1; r < 32; r++) { regs.push(u32()); }
    const mem = new Map();
    const DATA = 0x1000, DATA_LEN = 0x80, IMAGE = 0x2000, IMAGE_LEN = 0x40;
    for (let a = DATA; a < DATA + DATA_LEN; a++) { mem.set(a, ri(256)); }
    const image = [];
    for (let a = IMAGE; a < IMAGE + IMAGE_LEN; a++) { const b = ri(256); mem.set(a, b); image.push(b); }
    const commits = [];
    let pc = 0x80000000;
    let order = 0;
    const loopAt = Math.floor(v.n / 3);
    let bugAt = -1;
    for (let i = 0; i < v.n; i++) {
      const c = { pc, order: order++, insn: 0x00000013, rs1: 0, rs2: 0, rs1v: 0, rs2v: 0, rd: 0, rdv: 0, addr: 0, rmask: 0, wmask: 0, rdata: 0, wdata: 0, trap: 0 };
      const kind = i === loopAt || i === loopAt + 1 ? 'loop' : (['alu', 'alu', 'alu', 'load', 'load', 'store', 'store', 'amo', 'trap', 'rd0'])[ri(10)];
      c.rs1 = ri(32); c.rs2 = ri(32);
      c.rs1v = regs[c.rs1]; c.rs2v = regs[c.rs2];
      if (v.bug === 'forward' && bugAt < 0 && i > 50 && c.rs1 !== 0) { bugAt = i; c.rs1v = (c.rs1v ^ 0x100) >>> 0; }
      const sizes = [1, 2, 4];
      const access = () => {
        const size = sizes[ri(3)];
        const region = ri(3) === 0 ? IMAGE : DATA;
        const len = region === IMAGE ? IMAGE_LEN : DATA_LEN;
        let a = region + ri(len / 4) * 4;
        if (size < 4) { a += ri(4 / size) * size; }
        return { a, size };
      };
      const lane = (a) => (v.mask === 'word' ? a & 3 : 0);
      const base = (a) => (v.mask === 'word' ? a & ~3 : a);
      if (kind === 'alu') {
        c.insn = 0x00000033 | (ri(32) << 7);
        c.rd = 1 + ri(31); c.rdv = u32();
      } else if (kind === 'load' || kind === 'amo') {
        const { a, size } = kind === 'amo' ? { a: DATA + ri(DATA_LEN / 4) * 4, size: 4 } : access();
        c.insn = kind === 'amo' ? 0x0000202f : 0x00002003;
        c.addr = a; c.rmask = ((1 << size) - 1) << lane(a);
        let value = 0;
        for (let j = 0; j < size; j++) { const b = mem.get(a + j); value |= b << (8 * j); c.rdata |= b << (8 * (lane(a) + j)); }
        c.rdata >>>= 0;
        c.rd = ri(4) === 0 ? 0 : 1 + ri(31); c.rdv = c.rd ? value >>> 0 : 0;
        if (kind === 'amo') {
          c.wmask = 0xf; c.wdata = (value + 1) >>> 0;
          for (let j = 0; j < 4; j++) { mem.set(a + j, (c.wdata >>> (8 * j)) & 0xff); }
        }
        void base;
      } else if (kind === 'store') {
        const { a, size } = access();
        c.insn = 0x00002023;
        c.addr = a; c.wmask = ((1 << size) - 1) << lane(a);
        const value = u32();
        for (let j = 0; j < size; j++) { const b = (value >>> (8 * j)) & 0xff; mem.set(a + j, b); c.wdata |= b << (8 * (lane(a) + j)); }
        c.wdata >>>= 0;
        // A store's other bytes on the bus are junk.
        for (let j = 0; j < 4; j++) { if (!(c.wmask & (1 << j))) { c.wdata = (c.wdata | (ri(256) << (8 * j))) >>> 0; } }
      } else if (kind === 'trap') {
        // Retires with no architectural effect; the buses carry junk that must be ignored.
        c.trap = 1; c.insn = 0xffffffff;
        c.rd = 1 + ri(31); c.rdv = u32();
        c.addr = DATA + ri(DATA_LEN / 4) * 4; c.wmask = 0xf; c.wdata = u32();
      } else if (kind === 'rd0') {
        c.rd = 0; c.rdv = 0x55;  // the spec forbids it; the value is ignored either way
      } else if (kind === 'loop') {
        c.insn = 0x0000006f;  // jal x0, 0: the same instruction twice, back to back
        if (i === loopAt + 1) { c.pc = commits[i - 1].pc; }
      }
      if (!c.trap && c.rd) { regs[c.rd] = c.rdv; }
      commits.push(c);
      pc = kind === 'loop' && i === loopAt ? pc : (pc + 4) >>> 0;
    }
    // Cycles: posedges at 5 + 10 i. Up to nret commits per cycle; stalls; valid held high.
    const edges = [];
    const placed = [];  // { cycle, channel }
    let cycle = 3;  // three cycles of reset first (pc x)
    let i = 0;
    while (i < commits.length) {
      const stall = ri(5) === 0;
      if (stall) { cycle++; continue; }
      const k = v.nret === 2 && ri(2) === 0 ? 2 : 1;
      // swap: the older of two commits sometimes retires on channel 1 (order, not the channel, is program order).
      const swap = v.swap && k === 2 && i + 1 < commits.length && ri(2) === 0;
      for (let ch = 0; ch < k && i < commits.length; ch++) { placed.push({ cycle, channel: swap ? 1 - ch : ch, c: commits[i++] }); }
      cycle++;
    }
    const cycles = cycle + 2;
    for (let n = 0; n < cycles; n++) { edges.push(5 + 10 * n); }
    // Signals: per channel, each role's value per cycle (held when idle), as changes at the posedge.
    const W = { valid: 1, order: 64, insn: 32, trap: 1, rs1_addr: 5, rs2_addr: 5, rs1_rdata: 32, rs2_rdata: 32, rd_addr: 5, rd_wdata: 32,
      pc_rdata: 32, pc_wdata: 32, mem_addr: 32, mem_rmask: 4, mem_wmask: 4, mem_rdata: 32, mem_wdata: 32 };
    const field = { order: 'order', insn: 'insn', trap: 'trap', rs1_addr: 'rs1', rs2_addr: 'rs2', rs1_rdata: 'rs1v', rs2_rdata: 'rs2v',
      rd_addr: 'rd', rd_wdata: 'rdv', pc_rdata: 'pc', pc_wdata: null, mem_addr: 'addr', mem_rmask: 'rmask', mem_wmask: 'wmask', mem_rdata: 'rdata', mem_wdata: 'wdata' };
    const roles = Object.keys(W).filter((r) => !(v.noOrder && r === 'order'));
    const bin = (x, w) => (typeof x === 'string' ? x : BigInt(x).toString(2).padStart(w, '0').slice(-w));
    // perCycle[role][channel][cycle] = bits
    const per = {};
    for (const role of roles) {
      per[role] = [];
      for (let ch = 0; ch < v.nret; ch++) {
        const arr = new Array(cycles).fill(null);
        for (let n = 0; n < cycles; n++) { arr[n] = role === 'valid' ? '0' : null; }
        per[role].push(arr);
      }
    }
    // Before reset: valid and pc are x.
    for (let ch = 0; ch < v.nret; ch++) { for (let n = 0; n < 3; n++) { per.valid[ch][n] = 'x'; per.pc_rdata[ch][n] = 'x'.repeat(32); } }
    for (const p of placed) {
      per.valid[p.channel][p.cycle] = '1';
      for (const role of roles) {
        if (role === 'valid') { continue; }
        const f = field[role];
        const value = role === 'pc_wdata' ? (p.c.pc + 4) >>> 0 : p.c[f];
        per[role][p.channel][p.cycle] = bin(value, W[role]);
      }
    }
    // Held high: when a channel is idle right after a commit, valid stays low except in the self-loop,
    // where the waveform shows valid high on both cycles (two commits, same pc and insn).
    const signals = [];
    const scopeOf = { prefixed: ['tb', 'dut'], array: ['tb', 'mon'], struct: ['tb', 'core', 'rvfi'], monitor: ['tb', 'dut'] }[v.naming];
    const nameOf = (role) => {
      const r = v.naming === 'array' && role === 'insn' ? 'inst' : role;
      return v.naming === 'prefixed' ? 'rvfi_' + r : (v.naming === 'monitor' ? 'monitor_' + r : r);
    };
    const changesOf = (series, w) => {
      const out = [];
      let last = null;
      series.forEach((bits, n) => {
        const b = bits === null ? last : bits;
        if (b === null) { return; }
        if (b !== last) { out.push([edges[n] - (n % 3 === 0 ? 0 : 3), b.length < w ? b.padStart(w, b[0] === 'x' ? 'x' : '0') : b]); last = b; }
      });
      return out;
    };
    signals.push({ path: ['tb', 'clk'], width: 1, changes: (() => { const out = [[0, '0']]; for (const e of edges) { out.push([e, '1'], [e + 5, '0']); } return out; })() });
    for (const role of roles) {
      if (v.nret > 1 && v.naming === 'prefixed') {
        // Packed: channel c at [c*W +: W].
        const series = [];
        for (let n = 0; n < cycles; n++) {
          let bits = '';
          let any = false;
          for (let ch = v.nret - 1; ch >= 0; ch--) {
            let b = per[role][ch][n];
            if (b === null) { for (let m = n - 1; m >= 0 && b === null; m--) { b = per[role][ch][m]; } }
            if (b === null) { b = 'x'.repeat(W[role]); } else { any = true; }
            bits += b.length === 1 && W[role] > 1 ? b.repeat(W[role]) : b;
          }
          series.push(any || role === 'valid' ? bits : null);
        }
        signals.push({ path: scopeOf.concat([nameOf(role)]), width: W[role] * v.nret, changes: changesOf(series, W[role] * v.nret) });
      } else {
        for (let ch = 0; ch < v.nret; ch++) {
          const name = nameOf(role) + (v.nret > 1 || v.naming === 'array' ? '[' + ch + ']' : '');
          signals.push({ path: scopeOf.concat([name]), width: W[role], changes: changesOf(per[role][ch], W[role]) });
        }
      }
    }
    // What a correct replay shows. Program order = commits[]; the cycle's time labels each.
    const program = placed.map((p) => ({ time: edges[p.cycle], channel: p.channel, c: p.c }));
    if (v.noOrder) { program.sort((a, b) => a.time - b.time || a.channel - b.channel); }
    const expectCommits = program.map((p) => ({ time: p.time, channel: p.channel, pc: p.c.pc, order: v.noOrder ? null : p.c.order }));
    const cs = program.map((p) => p.c);
    const firstWrite = (r) => cs.findIndex((c) => !c.trap && c.rd === r);
    const regAt = (r, k) => {
      if (r === 0) { return 0; }
      for (let j = k - 1; j >= 0; j--) { if (!cs[j].trap && cs[j].rd === r) { return cs[j].rdv; } }
      const fw = firstWrite(r);
      for (let j = 0; j < (fw < 0 ? cs.length : fw); j++) {
        if (cs[j].rs1 === r) { return cs[j].rs1v; }
        if (cs[j].rs2 === r) { return cs[j].rs2v; }
      }
      return null;
    };
    const laneBase = (c) => (v.mask === 'word' ? c.addr & ~3 : c.addr);
    const touches = (c, mask, a) => { const j = a - laneBase(c); return j >= 0 && j < 4 && (mask & (1 << j)) !== 0; };
    const byteAt = (a, k) => {
      for (let j = k - 1; j >= 0; j--) {
        const c = cs[j];
        if (!c.trap && c.wmask && touches(c, c.wmask, a)) { return (c.wdata >>> (8 * (a - laneBase(c)))) & 0xff; }
      }
      if (a >= IMAGE && a < IMAGE + IMAGE_LEN) { return image[a - IMAGE]; }
      let fw = cs.length;
      for (let j = 0; j < cs.length; j++) { if (!cs[j].trap && cs[j].wmask && touches(cs[j], cs[j].wmask, a)) { fw = j; break; } }
      for (let j = 0; j < fw; j++) { const c = cs[j]; if (c.rmask && touches(c, c.rmask, a)) { return (c.rdata >>> (8 * (a - laneBase(c)))) & 0xff; } }
      return null;
    };
    const probes = [];
    const probeRand = rng(v.seed + 1000);
    for (let n = 0; n < 60; n++) { probes.push(Math.floor(probeRand() * (cs.length + 1))); }
    probes.push(0, cs.length, bugAt < 0 ? 1 : bugAt);
    const addrs = [];
    for (let a = DATA; a < DATA + DATA_LEN; a += 3) { addrs.push(a); }
    for (let a = IMAGE; a < IMAGE + IMAGE_LEN; a += 5) { addrs.push(a); }
    addrs.push(0x3000);  // never touched
    const states = probes.map((k) => ({ k, regs: Array.from({ length: 32 }, (_, r) => regAt(r, k)),
      mem: addrs.map((a) => [a, byteAt(a, k)]) }));
    const expect = { variant: name, nret: v.nret, mask: v.mask, count: cs.length, commits: expectCommits, states,
      forwardBug: bugAt < 0 ? null : { k: program.findIndex((p) => p.c.order === commits[bugAt].order), reg: commits[bugAt].rs1 },
      traps: cs.filter((c) => c.trap).length,
      swapped: program.filter((p, i) => i > 0 && program[i - 1].time === p.time && program[i - 1].channel > p.channel).length, rdZeroWrites: cs.filter((c) => !c.trap && c.rd === 0 && c.rdv !== 0).length,
      scope: scopeOf, image: { addr: IMAGE, bytes: image } };
    return { signals, edges, image: [{ addr: IMAGE, bytes: image }], expect };
  }

  // A VCD of the signals (1 ns units).
  function toVcd(run) {
    const lines = ['$timescale 1ns $end'];
    const ids = new Map();
    let n = 0;
    const id = () => { let x = n++, s = ''; do { s += String.fromCharCode(33 + (x % 94)); x = Math.floor(x / 94); } while (x); return s; };
    // Scopes as a tree.
    const tree = { children: new Map(), vars: [] };
    for (const s of run.signals) {
      let node = tree;
      for (const seg of s.path.slice(0, -1)) { if (!node.children.has(seg)) { node.children.set(seg, { children: new Map(), vars: [] }); } node = node.children.get(seg); }
      node.vars.push(s);
    }
    const walk = (node) => {
      for (const s of node.vars) {
        const i = id(); ids.set(s, i);
        const m = /^(.*?)(\[\d+\])$/.exec(s.path[s.path.length - 1]);
        const name = m ? m[1] + ' ' + m[2] : s.path[s.path.length - 1];
        lines.push('$var wire ' + s.width + ' ' + i + ' ' + name + (s.width > 1 && !m ? ' [' + (s.width - 1) + ':0]' : '') + ' $end');
      }
      for (const [name, child] of node.children) { lines.push('$scope module ' + name + ' $end'); walk(child); lines.push('$upscope $end'); }
    };
    walk(tree);
    lines.push('$enddefinitions $end');
    const byTime = new Map();
    // As a simulator's $dumpvars: every signal has a value at the first time, x until it changes.
    // (wellen 0.25.7 merges split bits valid [0], valid [1] into valid[1:0], and its merge starts each
    // bit at its second value when no bit changes at the first time: transform_bv_signal's offsets.)
    const t0 = Math.min(...run.signals.map((s) => (s.changes.length ? s.changes[0][0] : Infinity)));
    for (const s of run.signals) {
      const changes = s.changes.length && s.changes[0][0] > t0 ? [[t0, 'x'.repeat(s.width)]].concat(s.changes) : s.changes;
      for (const [t, bits] of changes) {
        if (!byTime.has(t)) { byTime.set(t, []); }
        byTime.get(t).push(s.width === 1 ? bits + ids.get(s) : 'b' + bits + ' ' + ids.get(s));
      }
    }
    for (const t of Array.from(byTime.keys()).sort((a, b) => a - b)) { lines.push('#' + t); lines.push(...byTime.get(t)); }
    return lines.join('\n') + '\n';
  }

  root.makeRvfi = makeRvfi;
  root.rvfiVariants = Object.keys(VARIANTS);
  root.rvfiToVcd = toVcd;
  if (typeof module !== 'undefined' && typeof require === 'function' && require.main === module) {
    const fs = require('fs'), path = require('path');
    const out = process.argv[2] || '.';
    for (const name of Object.keys(VARIANTS)) {
      const run = makeRvfi(name);
      fs.writeFileSync(path.join(out, name + '.vcd'), toVcd(run));
      fs.writeFileSync(path.join(out, name + '.json'), JSON.stringify(run.expect));
    }
  }
})(typeof window !== 'undefined' ? window : globalThis);
