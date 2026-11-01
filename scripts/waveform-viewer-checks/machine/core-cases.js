// Machine-state core checks (see main.swift). runMachineCases(fixturesDir, only) -> ['ok ...' | 'FAIL ...'].
// Needs cmux-expr.js, cmux-machine-core.js and make-rvfi-vcd.js loaded first, and readFile(path).
(function (root) {
  'use strict';
  const M = () => root.cmuxMachineCore;
  const X = () => root.cmuxExpr;

  // ---- a small VCD reader (checks only): signals as { path, width, changes } ----
  function readVcd(text) {
    const byId = new Map();
    const signals = [];
    const scopes = [];
    let i = 0;
    const lines = text.split('\n');
    for (; i < lines.length; i++) {
      const t = lines[i].trim().split(/\s+/);
      if (t[0] === '$scope') { scopes.push(t[2]); } else if (t[0] === '$upscope') { scopes.pop(); } else if (t[0] === '$var') {
        const width = Number(t[2]);
        let name = t[4];
        if (t[5] && /^\[\d+\]$/.test(t[5])) { name += t[5]; }
        const s = { path: scopes.concat([name]), width, changes: [] };
        if (byId.has(t[3])) { s.changes = byId.get(t[3]).changes; s.alias = true; } else { byId.set(t[3], s); }
        signals.push(s);
      } else if (t[0] === '$enddefinitions') { i++; break; }
    }
    let time = 0;
    for (; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) { continue; }
      const c = line[0];
      if (c === '#') { time = Number(line.slice(1)); continue; }
      if (c === '$') { continue; }
      let id, bits;
      if (c === 'b' || c === 'B') { const sp = line.indexOf(' '); bits = line.slice(1, sp).toLowerCase(); id = line.slice(sp + 1).trim(); } else if ('01xzXZ'.includes(c)) { bits = c.toLowerCase(); id = line.slice(1).trim(); } else { continue; }
      const s = byId.get(id);
      if (!s) { continue; }
      const last = s.changes[s.changes.length - 1];
      if (last && last[0] === time) { last[1] = bits; } else { s.changes.push([time, bits]); }
    }
    return signals.filter((s) => !s.alias);
  }

  function posedges(clock) {
    const out = [];
    let prev = null;
    for (const [t, v] of clock.changes) { if (v === '1' && prev !== null && prev !== '1') { out.push(t); } prev = v; }
    return Float64Array.from(out);
  }

  // Scopes for detect() from flat signals (the page reads them from the netlist).
  function scopesOf(signals) {
    const map = new Map();
    for (const s of signals) {
      const scope = s.path.slice(0, -1);
      const key = JSON.stringify(scope);
      if (!map.has(key)) { map.set(key, { path: scope, depth: scope.length - 1, vars: [] }); }
      map.get(key).vars.push({ name: s.path[s.path.length - 1], width: s.width });
    }
    return Array.from(map.values());
  }

  // The whole page path without the page: detect, sample, table, index.
  function load(signals, edges, options) {
    const sources = M().detect(scopesOf(signals));
    const source = (options && options.source) || sources[0];
    if (!source || source.family === 'offer') { return { sources }; }
    const byPath = new Map(signals.map((s) => [JSON.stringify(s.path), s]));
    const columns = {};
    for (const ref of M().mapping(source)) {
      const s = byPath.get(JSON.stringify(ref.path));
      const [col] = M().sample(s.changes, edges, s.width, [ref], options && options.preEdge);
      columns[ref.role + '/' + ref.channel] = col;
    }
    const table = M().buildTable(source, columns, edges);
    const index = new (M().StateIndex)(table, options || {});
    return { sources, source, table, index };
  }

  const hex = (v) => (v === null || v === undefined ? String(v) : '0x' + BigInt(v).toString(16));

  // ---- Spike's --log-commits, replayed independently of the core under test ----
  function spikeReplay(text, minPc) {
    const lowest = minPc === undefined ? 0x80000000 : minPc;
    const commits = [];
    for (const line of text.split('\n')) {
      const m = /^core\s+\d+:\s+\d+\s+0x([0-9a-f]+)\s+\((0x[0-9a-f]+)\)(.*)$/.exec(line);
      if (!m) { continue; }
      const pc = parseInt(m[1], 16);
      if (pc < lowest) { continue; }  // the boot ROM
      const c = { pc, insn: parseInt(m[2], 16), rd: null, rdv: null, mem: [], csrs: [] };
      const rest = m[3];
      let r;
      const rr = /\bx\s*(\d+)\s+0x([0-9a-f]+)/g;
      while ((r = rr.exec(rest))) { c.rd = Number(r[1]); c.rdv = BigInt('0x' + r[2]); }
      const mr = /\bmem\s+0x([0-9a-f]+)(?:\s+0x([0-9a-f]+))?/g;
      while ((r = mr.exec(rest))) { c.mem.push({ addr: parseInt(r[1], 16), value: r[2] === undefined ? null : BigInt('0x' + r[2]), size: r[2] === undefined ? 0 : r[2].length / 2 }); }
      const cr = /\bc(\d+)_([a-z0-9]+)\s+0x([0-9a-f]+)/g;
      while ((r = cr.exec(rest))) { c.csrs.push({ name: r[2], value: BigInt('0x' + r[3]) }); }
      commits.push(c);
    }
    return commits;
  }

  // A load's size and signedness from its encoding (RV32I and RVC loads).
  function loadKind(insn) {
    if ((insn & 3) !== 3) {
      const op = insn & 3, f3 = (insn >> 13) & 7;
      if ((op === 0 && f3 === 2) || (op === 2 && f3 === 2)) { return { size: 4, signed: true }; }
      return null;
    }
    if ((insn & 0x7f) !== 0x03) { return null; }
    const f3 = (insn >> 12) & 7;
    return ({ 0: { size: 1, signed: true }, 1: { size: 2, signed: true }, 2: { size: 4, signed: true }, 4: { size: 1, signed: false }, 5: { size: 2, signed: false } })[f3] || null;
  }

  // ELF PT_LOAD segments of a 32-bit little-endian ELF, for the checks only (the app asks the
  // toolchain's readelf; this is the checks' cross-check of that path's result).
  function elfSegments(bytes) {
    const u16 = (o) => bytes[o] | (bytes[o + 1] << 8);
    const u32 = (o) => (bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16) | (bytes[o + 3] << 24)) >>> 0;
    const phoff = u32(28), phentsize = u16(42), phnum = u16(44);
    const out = [];
    for (let i = 0; i < phnum; i++) {
      const o = phoff + i * phentsize;
      if (u32(o) !== 1) { continue; }
      const off = u32(o + 4), vaddr = u32(o + 8), filesz = u32(o + 16), memsz = u32(o + 20);
      out.push({ addr: vaddr, bytes: Array.from(bytes.slice(off, off + filesz)), memsz });
    }
    // Symbols: .symtab via section headers.
    const shoff = u32(32), shentsize = u16(46), shnum = u16(48);
    const symbols = [];
    for (let i = 0; i < shnum; i++) {
      const o = shoff + i * shentsize;
      if (u32(o + 4) !== 2) { continue; }
      const off = u32(o + 16), size = u32(o + 20), link = u32(o + 24);
      const strOff = u32(shoff + link * shentsize + 16);
      for (let s = off; s < off + size; s += 16) {
        const nameAt = strOff + u32(s);
        let name = '';
        for (let j = nameAt; bytes[j]; j++) { name += String.fromCharCode(bytes[j]); }
        const type = bytes[s + 12] & 0xf;
        if (name && (type === 1 || type === 2 || type === 0) && u32(s + 4) >= 0x80000000) { symbols.push({ name, addr: u32(s + 4), size: u32(s + 8) }); }
      }
    }
    return { segments: out, symbols };
  }

  function runMachineCases(fixtures, only) {
    const out = [];
    const ok = (cond, what) => { out.push((cond ? 'ok   ' : 'FAIL ') + what); return cond; };
    const want = (name) => !only || only.split(',').includes(name);

    // ---- synthetic streams ----
    if (want('synthetic')) {
      for (const name of root.rvfiVariants) {
        const run = root.makeRvfi(name);
        const e = run.expect;
        const edges = Float64Array.from(run.edges);
        const t0 = root.nowMs ? root.nowMs() : 0;
        const { sources, source, table, index } = load(run.signals, edges, { image: run.image });
        ok(source && source.nret === e.nret && JSON.stringify(source.scope) === JSON.stringify(e.scope),
          name + ': detected nret ' + (source && source.nret) + ' in ' + (source && source.scope.join('.')) + ' (' + (sources.length) + ' sources)');
        if (!table) { continue; }
        ok(table.count === e.count, name + ': ' + table.count + ' commits, expected ' + e.count);
        let bad = 0;
        e.commits.forEach((c, k) => {
          const pc = M().num(table.cols.pc_rdata, k);
          if (table.time[k] !== c.time || table.channel[k] !== c.channel || pc !== c.pc || (c.order !== null && M().num(table.cols.order, k) !== c.order)) {
            if (bad++ < 3) { out.push('     commit ' + k + ': got t ' + table.time[k] + ' ch ' + table.channel[k] + ' pc ' + hex(pc) + ', want ' + JSON.stringify(c)); }
          }
        });
        ok(bad === 0, name + ': every commit has the expected time, channel, pc and order (' + bad + ' differ' + (e.swapped ? ', ' + e.swapped + ' cycles retire the older on channel 1' : '') + ')');
        ok(index.memMask === e.mask, name + ': mask convention detected as ' + index.memMask + ' (' + JSON.stringify(index.maskEvidence) + ')');
        let regBad = 0, memBad = 0, unknownOk = 0;
        for (const st of e.states) {
          for (let r = 0; r < 32; r++) {
            const got = index.reg(r, st.k);
            const exp = st.regs[r];
            const same = exp === null ? !got.known : got.known && got.value === BigInt(exp);
            if (exp === null && same) { unknownOk++; }
            if (!same && regBad++ < 4) { out.push('     k ' + st.k + ' x' + r + ': got ' + (got.known ? hex(got.value) + ' (' + got.from + ')' : 'unknown') + ', want ' + (exp === null ? 'unknown' : hex(exp))); }
          }
          for (const [a, exp] of st.mem) {
            const got = index.byte(a, st.k);
            const same = exp === null ? !got.known : got.known && got.value === exp;
            if (!same && memBad++ < 4) { out.push('     k ' + st.k + ' [' + hex(a) + ']: got ' + (got.known ? hex(got.value) + ' (' + got.from + ')' : 'unknown') + ', want ' + (exp === null ? 'unknown' : hex(exp))); }
          }
        }
        ok(regBad === 0, name + ': registers at ' + e.states.length + ' commits match the model (' + regBad + ' differ, ' + unknownOk + ' rightly unknown)');
        ok(memBad === 0, name + ': memory bytes at ' + e.states.length + ' commits match the model (' + memBad + ' differ)');
        ok(table.diagnostics.rdZeroWrites === e.rdZeroWrites, name + ': rd = x0 writes flagged: ' + table.diagnostics.rdZeroWrites + ' of ' + e.rdZeroWrites);
        if (e.commits[0].order !== null) { ok(table.diagnostics.orderContiguous === true, name + ': order contiguous'); }
        if (e.forwardBug) {
          const d = index.regDisagreements.find((x) => x.k === e.forwardBug.k && x.reg === e.forwardBug.reg);
          ok(!!d && index.regDisagreements.length === 1, name + ': the forwarding bug is flagged at commit ' + e.forwardBug.k + ' x' + e.forwardBug.reg + ' (' + JSON.stringify(index.regDisagreements.map((x) => [x.k, x.reg])) + ')');
        } else {
          ok(index.regDisagreements.length === 0 && index.memDisagreements.length === 0, name + ': no disagreements (' + index.regDisagreements.length + ', ' + index.memDisagreements.length + ')');
        }
        // Who last wrote / next write against brute force.
        let wBad = 0;
        for (const st of e.states.slice(0, 20)) {
          for (let r = 1; r < 32; r++) {
            let last = null, next = null;
            for (let j = 0; j < table.count; j++) {
              const writes = !index.trapped(j) && M().num(table.cols.rd_addr, j) === r;
              if (writes && j < st.k) { last = j; }
              if (writes && j >= st.k && next === null) { next = j; }
            }
            if (index.lastRegWrite(r, st.k) !== last || index.nextRegWrite(r, st.k) !== next) { wBad++; }
          }
        }
        ok(wBad === 0, name + ': last/next register writes equal brute force (' + wBad + ' differ)');
        // A time inside each commit's cycle maps back to its first commit there.
        let cBad = 0;
        for (let k = 0; k < table.count; k++) {
          const first = index.commitAt(table.time[k]);
          if (table.time[first] !== table.time[k] || first > k || (first > 0 && table.time[first - 1] === table.time[k])) { cBad++; }
        }
        ok(cBad === 0, name + ': commitAt(cycle) is the cycle\'s first commit (' + cBad + ' differ)');
        out.push('     ' + name + ': built in ' + ((root.nowMs ? root.nowMs() : 0) - t0).toFixed(0) + ' ms');
      }
      // Trap writes applied when asked: the model's state then differs.
      const run = root.makeRvfi('prefixed');
      const a = load(run.signals, Float64Array.from(run.edges), { image: run.image, trapWrites: 'apply' });
      ok(a.index.regWrites.reduce((n, l) => n + l.n, 0) > load(run.signals, Float64Array.from(run.edges), { image: run.image }).index.regWrites.reduce((n, l) => n + l.n, 0),
        'trapWrites apply: traps\' rd writes are counted');
      // Forcing the wrong mask convention breaks the state (so detection matters).
      const w = root.makeRvfi('packed2');
      const forced = load(w.signals, Float64Array.from(w.edges), { image: w.image, memMask: 'byte' });
      let diff = 0;
      for (const st of w.expect.states) { for (const [addr, exp] of st.mem) { const g = forced.index.byte(addr, st.k); if (exp !== null && (!g.known || g.value !== exp)) { diff++; } } }
      ok(diff > 0, 'packed2 with byte masks forced: ' + diff + ' bytes differ from the word-relative truth');
      // The offer rule never auto-uses a lone commit_valid/pc pair.
      const offer = M().detect([{ path: ['tb', 'core'], depth: 1, vars: [{ name: 'commit_valid', width: 1 }, { name: 'commit_pc', width: 32 }] }]);
      ok(offer.length === 1 && offer[0].family === 'offer', 'commit_valid + commit_pc is offered, not used: ' + JSON.stringify(offer.map((s) => s.family)));
      // A packed role whose width doesn't divide by NRET rejects the source.
      const bad = M().detect([{ path: ['t'], depth: 0, vars: [{ name: 'rvfi_valid', width: 2 }, { name: 'rvfi_pc_rdata', width: 48 }, { name: 'rvfi_order', width: 128 }] }]);
      ok(bad.length && bad[0].xlen === 24 ? false : !bad.length, 'pc_rdata of 48 bits over NRET 2 (24-bit pc) is rejected: ' + JSON.stringify(bad));
      // Ranking: more roles first; then shallower.
      const two = M().detect([
        { path: ['tb', 'mon'], depth: 1, vars: ['valid', 'pc_rdata', 'order', 'insn'].map((n) => ({ name: n, width: n === 'valid' ? 1 : 32 })) },
        { path: ['tb', 'dut'], depth: 1, vars: ['valid', 'pc_rdata', 'order', 'insn', 'rd_addr', 'rd_wdata'].map((n) => ({ name: 'rvfi_' + n, width: n === 'valid' ? 1 : 32 })) },
      ]);
      ok(two.length === 2 && two[0].scope.join('.') === 'tb.dut', 'the source with more roles ranks first: ' + two.map((s) => s.label).join(', '));
    }

    // ---- $ names in cmux-expr ----
    if (want('expr')) {
      const P = (t) => X().parse(t);
      const env = (path) => (path[0] === '$a0' ? { width: 32, value: X().fromBits((0x1234).toString(2), 32) } : (path[0] === '$sp' ? { width: 32, value: X().fromBits((0x8000fff0 >>> 0).toString(2), 32) } : null));
      env.memory = (bytes, addr) => (addr.b === 0n && addr.a === 0x8000fff8n ? { width: bytes * 8, value: X().fromBits('1010', bytes * 8) } : null);
      const r1 = X().evaluate(P('$a0 + 4').ast, env);
      ok(r1.value && r1.value.a === 0x1238n, '$a0 + 4 = ' + (r1.value ? X().format(r1.value, 'hex') : JSON.stringify(r1)));
      const r2 = X().evaluate(P('$mem32($sp + 8)').ast, env);
      ok(r2.value && r2.value.a === 10n && r2.value.w === 32, '$mem32($sp + 8) = ' + (r2.value ? X().format(r2.value, 'hex') : JSON.stringify(r2)));
      ok(JSON.stringify(X().names(P('$mem8($sp) + $a0').ast)) === '[["$sp"],["$a0"]]', '$ names are listed: ' + JSON.stringify(X().names(P('$mem8($sp) + $a0').ast)));
      const r3 = X().evaluate(P('$mem16($a0)').ast, env);
      ok(r3.error === 'unknownName', 'memory with no value is unknownName: ' + JSON.stringify(r3));
      ok(P('$signed(a)').error === 'unsupported' && P('$mem32').error === 'syntax', '$signed( stays unsupported, a bare $mem32 is a syntax error: ' + JSON.stringify([P('$signed(a)'), P('$mem32')]));
      ok(P('$a0.b').error === 'syntax', 'a $ name has no dotted path');
    }

    // ---- the fixture cores against Spike ----
    for (const core of ['nerv', 'picorv32', 'ibex']) {
      if (!want(core)) { continue; }
      const dir = fixtures + '/' + core;
      const vcd = root.readFile(dir + '/' + core + '.vcd');
      const log = root.readFile(dir + '/spike.log');
      const elf = root.readBytes(dir + '/prog.elf');
      if (!vcd || !log || !elf) { ok(false, core + ': fixture files missing in ' + dir); continue; }
      const t0 = root.nowMs ? root.nowMs() : 0;
      const signals = readVcd(vcd);
      const clock = signals.find((s) => /^(clk|clock|clk_i)$/.test(s.path[s.path.length - 1]));
      const edges = posedges(clock);
      const { segments, symbols } = elfSegments(Uint8Array.from(elf));
      const { source, table, index } = load(signals, edges, { image: segments, symbols });
      const ms = (root.nowMs ? root.nowMs() : 0) - t0;
      const spike = spikeReplay(log);
      if (!ok(!!table, core + ': a commit stream is found (' + (source ? source.label : 'none') + ')')) { continue; }
      // Both end in the same self-loop; either may run it a few more times than the other.
      const loopPc = spike[spike.length - 1].pc;
      let tail = true;
      for (let k = Math.min(table.count, spike.length); k < Math.max(table.count, spike.length); k++) {
        tail = tail && (k < table.count ? M().num(table.cols.pc_rdata, k) : spike[k].pc) === loopPc;
      }
      ok(table.count > 1000 && tail, core + ': ' + table.count + ' commits, Spike ' + spike.length + ' (the difference is the final self-loop)');
      let pcBad = 0;
      for (let k = 0; k < table.count; k++) {
        if (!spike[k]) { continue; }
        if (M().num(table.cols.pc_rdata, k) !== spike[k].pc || M().num(table.cols.insn, k) !== spike[k].insn) { if (pcBad++ < 3) { out.push('     ' + core + ' commit ' + k + ': pc ' + hex(M().num(table.cols.pc_rdata, k)) + ' insn ' + hex(M().num(table.cols.insn, k)) + ', spike ' + hex(spike[k].pc) + ' ' + hex(spike[k].insn)); } }
      }
      ok(pcBad === 0, core + ': pc and insn of every commit equal Spike\'s (' + pcBad + ' differ)');
      // Registers: whatever Spike has written before k, ours shows the same value.
      const regs = new Array(32).fill(null);
      const memory = new Map();
      const csrs = new Map();
      let xs = 0, regChecks = 0, regBad = 0, memChecks = 0, memBad = 0, loadChecks = 0, loadBad = 0, csrChecks = 0, csrBad = 0, fromRead = 0;
      for (let k = 0; k <= table.count; k++) {
        if (k % 7 === 0 || k === table.count) {
          for (let r = 1; r < 32; r++) {
            const got = index.reg(r, k);
            if (regs[r] === null) { if (got.known && got.from === 'read') { fromRead++; } continue; }
            // x in the dump (the core's own reset state, e.g. a callee-saved register saved by main): Spike has 0.
            if (got.known && got.value === null) { xs++; continue; }
            regChecks++;
            if (!got.known || got.value !== regs[r]) { if (regBad++ < 4) { out.push('     ' + core + ' k ' + k + ' x' + r + ': got ' + (got.known ? hex(got.value) : 'unknown') + ', spike ' + hex(regs[r])); } }
          }
          for (const [a, b] of memory) {
            const got = index.byte(a, k);
            if (got.known && got.value === null) { xs++; continue; }
            memChecks++;
            if (!got.known || got.value !== b) { if (memBad++ < 4) { out.push('     ' + core + ' k ' + k + ' [' + hex(a) + ']: got ' + (got.known ? hex(got.value) : 'unknown') + ', spike ' + hex(b)); } }
          }
          for (const [name, v] of csrs) {
            csrChecks++;
            const got = index.csr(name, k);
            if (!got || got.value !== v) { if (csrBad++ < 4) { out.push('     ' + core + ' k ' + k + ' ' + name + ': got ' + (got ? hex(got.value) : 'none') + ', spike ' + hex(v)); } }
          }
        }
        if (k === table.count || !spike[k]) { break; }
        const c = spike[k];
        // A load: the bytes ours has at its address before k, extended, are what Spike loaded.
        const lk = loadKind(c.insn);
        if (lk && c.rd && c.mem.length) {
          loadChecks++;
          const got = index.load(c.mem[0].addr, lk.size, k);
          let v = got.value;
          if (v !== null && lk.signed && lk.size < 4) { v = BigInt.asUintN(32, BigInt.asIntN(lk.size * 8, v)); }
          if (got.known && got.value === null) { xs++; } else if (!got.known || v !== c.rdv) { if (loadBad++ < 4) { out.push('     ' + core + ' load at k ' + k + ' [' + hex(c.mem[0].addr) + '/' + lk.size + ']: got ' + (got.known ? hex(v) : 'unknown') + ', spike ' + hex(c.rdv)); } }
        }
        if (c.rd) { regs[c.rd] = c.rdv; }
        for (const m of c.mem) { if (m.value !== null) { for (let j = 0; j < m.size; j++) { memory.set(m.addr + j, Number((m.value >> BigInt(8 * j)) & 0xffn)); } } }
        for (const x of c.csrs) { csrs.set(x.name, x.value); }
      }
      ok(regBad === 0 && regChecks > 1000, core + ': registers equal Spike\'s at every 7th commit (' + regChecks + ' checks, ' + regBad + ' differ, ' + fromRead + ' known only from reads, ' + xs + ' x in the dump)');
      ok(memBad === 0 && memChecks > 100, core + ': stored bytes equal Spike\'s (' + memChecks + ' checks, ' + memBad + ' differ)');
      ok(loadBad === 0 && loadChecks > 20, core + ': every load reads what Spike loaded, from writes and the ELF image (' + loadChecks + ' loads, ' + loadBad + ' differ)');
      if (core === 'nerv') { ok(csrBad === 0 && csrChecks > 0, core + ': mscratch equals Spike\'s after its writes (' + csrChecks + ' checks, ' + csrBad + ' differ)'); }
      ok(index.regDisagreements.length === 0 && index.memDisagreements.length === 0 && !index.elfMismatch,
        core + ': no read disagrees with the replay or the image (' + index.regDisagreements.length + ' reg, ' + index.memDisagreements.length + ' mem; gated ' + JSON.stringify(index.gated) + ')');
      if (core === 'ibex') {
        ok(index.gated.nonMemory > 100, 'ibex: its stale rvfi_mem_* on non-memory instructions are gated out (' + index.gated.nonMemory + ')');
        const raw = load(signals, edges, { image: segments, symbols, gateByInsn: false }).index;
        ok(raw.memDisagreements.length > 0, 'ibex: without the gate they read as disagreements (' + raw.memDisagreements.length + ')');
      }
      ok(table.diagnostics.orderContiguous === true, core + ': order is contiguous');
      // gdb: the table symbol, x/4xw on it at the end, and x/2i at the entry.
      const tableAddr = index.symbolAddr('table');
      const g = M().gdb('x/4xw &table', { index, k: table.count, evaluate: (t) => { const p = X().parse(t); const r = X().evaluate(p.ast, () => null); return { value: r.value ? r.value.a : null, error: r.error }; } });
      ok(tableAddr !== null && g && g.lines[0] === '0x' + tableAddr.toString(16) + ' <table>:\t0x01234567\t0x89abcdef\t0xdeadbeef\t0x00c0ffee', core + ': x/4xw &table: ' + JSON.stringify(g && g.lines));
      out.push('     ' + core + ': read ' + signals.length + ' signals, ' + edges.length + ' edges; built in ' + ms.toFixed(0) + ' ms (replay ' + index.buildMs + ' ms)');
    }

    // ---- gdb commands on a hand-made table ----
    if (want('gdb')) {
      const sig = (name, width, changes) => ({ path: ['tb', 'dut', 'rvfi_' + name], width, changes });
      const b = (v, w) => BigInt(v).toString(2).padStart(w, '0');
      const s = [
        { path: ['tb', 'clk'], width: 1, changes: [[0, '0'], [5, '1'], [10, '0'], [15, '1'], [20, '0'], [25, '1'], [30, '0'], [35, '1'], [40, '0']] },
        sig('valid', 1, [[0, '0'], [5, '1'], [35, '0']]),
        sig('order', 64, [[5, b(0, 64)], [15, b(1, 64)], [25, b(2, 64)]]),
        sig('insn', 32, [[5, b(0x00a00513, 32)], [15, b(0x00a12023, 32)], [25, b(0x00012583, 32)]]),
        sig('pc_rdata', 32, [[5, b(0x80000000, 32)], [15, b(0x80000004, 32)], [25, b(0x80000008, 32)]]),
        sig('rd_addr', 5, [[5, b(10, 5)], [15, b(0, 5)], [25, b(11, 5)]]),
        sig('rd_wdata', 32, [[5, b(10, 32)], [15, b(0, 32)], [25, b(0x41, 32)]]),
        sig('rs1_addr', 5, [[5, b(0, 5)], [15, b(2, 5)], [25, b(2, 5)]]),
        sig('rs1_rdata', 32, [[5, b(0, 32)], [15, b(0x1000, 32)], [25, b(0x1000, 32)]]),
        sig('mem_addr', 32, [[5, b(0, 32)], [15, b(0x1000, 32)], [25, b(0x1000, 32)]]),
        sig('mem_wmask', 4, [[5, b(0, 4)], [15, b(15, 4)], [25, b(0, 4)]]),
        sig('mem_rmask', 4, [[5, b(0, 4)], [15, b(0, 4)], [25, b(15, 4)]]),
        sig('mem_wdata', 32, [[5, b(0, 32)], [15, b(0x41, 32)]]),
        sig('mem_rdata', 32, [[5, b(0, 32)], [25, b(0x41, 32)]]),
      ];
      const edges = Float64Array.from([5, 15, 25, 35]);
      const { index } = load(s, edges, { symbols: [{ name: 'buf', addr: 0x1000, size: 16 }] });
      const evaluate = (t) => { const p = X().parse(t); if (p.error) { return { error: p.error }; } const r = X().evaluate(p.ast, () => null); return r.error ? { error: r.error } : { value: r.value.b ? null : r.value.a, width: r.value.w }; };
      const ctx = { index, k: 1, evaluate, disasm: (w) => (w === 0x00a12023 ? 'sw\ta0,0(sp)' : null) };
      const ir = M().gdb('info registers a0 a1 pc', ctx);
      ok(ir && ir.lines.join('|') === 'a0             0x0000000a         10|a1             —|pc             0x80000004         ', 'info registers a0 a1 pc at k 1: ' + JSON.stringify(ir && ir.lines));
      ctx.k = 2;
      const ir2 = M().gdb('i r a1', ctx);
      ok(ir2 && ir2.lines[0] === 'a1             —  → 0x00000041', 'i r a1 at k 2 shows the pending write: ' + JSON.stringify(ir2 && ir2.lines));
      const x1 = M().gdb('x/4xb 0x1000', ctx);
      ok(x1 && x1.lines[0] === '0x1000 <buf>:\t0x41\t0x00\t0x00\t0x00', 'x/4xb 0x1000 after the store: ' + JSON.stringify(x1 && x1.lines));
      ctx.k = 1;
      const x0 = M().gdb('x/2xw buf', ctx);
      ok(x0 && x0.lines[0] === '0x1000 <buf>:\t—\t—', 'x/2xw buf before the store: unknown: ' + JSON.stringify(x0 && x0.lines));
      const xi = M().gdb('x/1i 0x80000004', ctx);
      ok(xi && xi.lines[0] === '=> 0x80000004:\tsw\ta0,0(sp)', 'x/1i at pc uses the fetched insn and marks pc: ' + JSON.stringify(xi && xi.lines));
      const p = M().gdb('p/x 0x10 + 2', ctx);
      ok(p && p.lines[0] === '$1 = 0x12', 'p/x 0x10 + 2: ' + JSON.stringify(p && p.lines));
      const p2 = M().gdb('p 0xfffffffe', Object.assign({}, ctx, { history: 1 }));
      ok(p2 && /^\$2 = /.test(p2.lines[0]), 'p numbers its results: ' + JSON.stringify(p2 && p2.lines));
      const sym = M().gdb('info symbol 0x1004', ctx);
      ok(sym && sym.lines[0] === 'buf + 4', 'info symbol 0x1004: ' + JSON.stringify(sym && sym.lines));
      ok(M().isGdb('x/4i $pc') && M().isGdb('p $a0') && M().isGdb('info registers') && !M().isGdb('x') && !M().isGdb('p') && !M().isGdb('state == 3') && !M().isGdb('pc + 4'),
        'gdb commands are told from SV expressions');
      const cont = M().gdb('x', Object.assign(ctx, { last: { fmt: 'x', unit: 'b', addr: 0x1002 } }));
      ok(cont === null, 'a bare x is a signal name, not a command');
      ok(index.pending(1).mem.length === 4 && index.pending(1).mem[0].value === 0x41, 'pending store bytes at k 1');
      // x/z: an x rd_wdata makes the register x (known, from that commit); an x rd_addr makes every
      // register uncertain until it is written again. A CSR's wdata counts only under wmask.
      const z = [
        { path: ['tb', 'clk'], width: 1, changes: [[0, '0'], [5, '1'], [10, '0'], [15, '1'], [20, '0'], [25, '1'], [30, '0'], [35, '1'], [40, '0'], [45, '1'], [50, '0']] },
        sig('valid', 1, [[0, '0'], [5, '1'], [45, '0']]),
        sig('order', 64, [[5, b(0, 64)], [15, b(1, 64)], [25, b(2, 64)], [35, b(3, 64)]]),
        sig('insn', 32, [[5, b(0x13, 32)]]),
        sig('pc_rdata', 32, [[5, b(0x100, 32)], [15, b(0x104, 32)], [25, b(0x108, 32)], [35, b(0x10c, 32)]]),
        sig('rd_addr', 5, [[5, b(5, 5)], [15, b(6, 5)], [25, 'xxxxx'], [35, b(6, 5)]]),
        sig('rd_wdata', 32, [[5, 'x'.repeat(32)], [15, b(7, 32)], [25, b(1, 32)], [35, b(9, 32)]]),
        sig('csr_mstatus_wmask', 32, [[5, b(0xff, 32)], [15, b(0, 32)], [25, b(0xff00, 32)], [35, b(0, 32)]]),
        sig('csr_mstatus_wdata', 32, [[5, b(0x12345678, 32)], [25, b(0xabcdef00, 32)]]),
        sig('csr_mstatus_rmask', 32, [[5, b(0xffffff00, 32)], [15, b(0, 32)]]),
        sig('csr_mstatus_rdata', 32, [[5, b(0x11223300, 32)]]),
      ];
      const zi = load(z, Float64Array.from([5, 15, 25, 35, 45])).index;
      const r5 = zi.reg(5, 1), r6 = zi.reg(6, 3), r6b = zi.reg(6, 4), r5c = zi.reg(5, 4);
      ok(r5.known && r5.value === null && r5.writer === 0, 'an x rd_wdata: x5 is x, written by commit 0: ' + JSON.stringify(r5, (k, v) => (typeof v === 'bigint' ? hex(v) : v)));
      ok(r6.known && r6.value === 7n && r6.uncertain && r5c.uncertain && !r6b.uncertain && r6b.value === 9n,
        'an x rd_addr at commit 2: later registers are uncertain until written again (x6 at 3 uncertain, at 4 not; x5 at 4 uncertain)');
      const m1 = zi.csr('mstatus', 1), m3 = zi.csr('mstatus', 3);
      ok(m1 && m1.known && m1.value === 0x11223378n, 'mstatus after a write under 0xff over a read under 0xffffff00: ' + (m1 && hex(m1.value)));
      ok(m3 && m3.known && m3.value === 0x1122ef78n, 'and after a write under 0xff00: ' + (m3 && hex(m3.value)));
      const mi = M().gdb('info registers mstatus', { index: zi, k: 3, evaluate });
      ok(mi && mi.lines[0].startsWith('mstatus        0x1122ef78'), 'info registers mstatus: ' + JSON.stringify(mi && mi.lines));
      // Pre-edge sampling: a registered stream (changes at the edge) is seen one posedge later.
      const pre = load(s, edges, { preEdge: true });
      ok(pre.table.count === 3 && Array.from(pre.table.time).join() === '15,25,35' && M().num(pre.table.cols.pc_rdata, 0) === 0x80000000,
        'preEdge: the same commits, each one posedge later: ' + Array.from(pre.table.time).join());
    }
    // Instruction-sequence search (sequence-cases.js, cmux-sequence.js).
    if (want('sequence') && root.runSequenceCases) { out.push(...root.runSequenceCases(fixtures, { readVcd, posedges, load, spikeReplay, elfSegments })); }
    return out;
  }

  root.runMachineCases = runMachineCases;
  root.machineSpikeReplay = spikeReplay;
  root.machineLoad = load;
  root.machineReadVcdPosedges = posedges;
  root.machineReadVcd = readVcd;
})(typeof window !== 'undefined' ? window : globalThis);
