// The machine state in the real page (run.sh machine): what page.swift loads in an off-screen
// WKWebView through the app's scheme handler, checked here in the page itself. The dump is read by
// wellen (not the checks' own VCD reader), the commit stream found from its netlist, and the pane,
// F10 by commit, $ names in Evaluate / watches / conditions, gdb commands and the row actions
// driven through window.cmuxWaveform as cmux drives them. The oracle is Spike's commit log (cores)
// or the generator's brute-force replay (synthetic streams).
//
//   await runMachinePageChecks({ kind: 'core' | 'synthetic' | 'none', name, spikeLog, image })
//     -> { lines: ['ok   ...' | 'FAIL ...' | '     ...'], failures }
(function (root) {
  'use strict';

  async function runMachinePageChecks(opts) {
    const lines = [];
    let failures = 0;
    // Streamed as it happens (page.swift prints it), so a run that never ends shows how far it got.
    const progress = (what) => {
      const h = root.webkit && root.webkit.messageHandlers && root.webkit.messageHandlers.cmuxWaveform;
      if (h) { h.postMessage({ type: 'progress', text: String(what) + ' (' + Math.round(performance.now()) + ' ms)' }); }
    };
    const live = opts.kind === 'fsdb';  // long runs stream every line
    const expect = (ok, what) => { lines.push((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) { failures++; } if (live) { progress((ok ? 'ok   ' : 'FAIL ') + what); } };
    const note = (what) => { lines.push('     ' + what); if (live) { progress(what); } };
    const W = root.cmuxWaveform;
    const M = W.machine;
    const D = W.debugger;
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const markerIs = async (time) => {
      for (let i = 0; i < 60; i++) { if (D.markerTime() === time) { return true; } await sleep(25); }
      return false;
    };
    const big = (text) => (/^0x[0-9a-f]+$/i.test(String(text)) ? BigInt(text) : null);
    const toasts = () => Array.from(document.querySelectorAll('.cmux-toast')).map((t) => t.textContent);
    const clearToasts = () => document.querySelectorAll('.cmux-toast').forEach((t) => t.remove());

    if (opts.kind === 'none') {
      // A dump with no commit stream: says so, and $ names say why instead of "not in this waveform".
      const s = await M.build();
      expect(s.error === 'noSource' && s.count === null, 'no commit stream: noSource: ' + JSON.stringify([s.error, s.problem]));
      await D.jump({ to: 'first' });
      const r = await D.evaluate({ expr: '$a0 + 1' });
      expect(r.error === 'noValue' && /No commit stream/.test(r.message), '$a0 without a stream: ' + r.message);
      const g = await D.evaluate({ expr: 'info registers' });
      expect(g.gdb === true && g.error && /No commit stream/.test(g.value), 'info registers without a stream: ' + JSON.stringify(g));
      const plain = await D.evaluate({ expr: 'x' });
      expect(!plain.gdb, 'a bare x is still a signal name, not gdb\'s x: ' + JSON.stringify(plain.error || plain.value));
      return { lines, failures };
    }

    // ---- the stream: found from wellen's netlist ----
    const t0 = performance.now();
    if (live) { progress('building the commit index'); }
    let s = await M.build();
    const buildMs = performance.now() - t0;
    expect(s.error === null && s.count > 0, opts.name + ': a commit stream: ' + JSON.stringify([s.source, s.family, s.nret, s.count, s.error, s.problem]));
    if (!s.count) {
      // What the reader named the vars in the scopes the generator wrote (how a miss reads).
      const H = W.host;
      const walk = async (items, path, depth) => {
        for (const it of items) {
          if (it.kind === 'scope' && depth < 3) { await walk(await H.getChildren(it), path.concat([it.name]), depth + 1); }
          if (it.kind === 'var') { note('  ' + path.concat([it.name]).join('.') + ' w' + it.width + ' [' + it.msb + ':' + it.lsb + ']'); }
        }
      };
      try { await walk(H.doc.netlist, [], 0); } catch (error) { note('netlist walk: ' + error); }
      return { lines, failures };
    }
    note(opts.name + ': ' + s.source + ' (' + s.family + ', NRET ' + s.nret + '), ' + s.count + ' commits, built in ' + buildMs.toFixed(0) + ' ms'
      + ' (page ' + s.buildMs + ' ms), masks ' + s.memMask + ', gated ' + JSON.stringify(s.gated));

    if (opts.kind === 'synthetic') {
      const run = root.makeRvfi(opts.name);
      const x = run.expect;
      expect(s.count === x.count && s.nret === x.nret, opts.name + ': count and NRET as generated: ' + [s.count, x.count, s.nret, x.nret].join(' '));
      if (s.count !== x.count) {
        // How a miscount reads: the page's clock edges and the reader's valid against the generator's.
        const edges = await D.edges();
        note('edges: page ' + edges.length + ' [' + Array.from(edges.slice(0, 4)).join(',') + ' … ' + edges[edges.length - 1] + '], generated ' + run.edges.length
          + ' [' + run.edges.slice(0, 4).join(',') + ' … ' + run.edges[run.edges.length - 1] + ']');
        const valids = run.signals.filter((g) => /(^|_)valid(\[\d+\])?$/.test(g.path[g.path.length - 1]));
        note('generated valid: ' + valids.map((g) => g.path.join('.') + ' w' + g.width + ' ' + g.changes.length + ' changes, first ' + JSON.stringify(g.changes.slice(0, 4))).join('; '));
        for (const path of [x.scope.concat(['valid'])]) {
          const v = await W.host.findLinkItem(path, true);
          const ch = v ? await W.host.signalChanges(v, 1e6) : null;
          note('read ' + path.join('.') + ': ' + (v ? 'w' + v.width + ' ' + (ch ? ch.length + ' changes, first ' + JSON.stringify(Array.from(ch.slice(0, 4))) : 'no changes') : 'not found'));
        }
      }
      expect(s.memMask === x.mask, opts.name + ': ' + x.mask + '-relative masks detected: ' + s.memMask);
      expect(s.cacheHit === false, opts.name + ': a VCD read in the page has no identity, so nothing is cached: ' + s.cacheHit);
      // The reader's own values, every signal the generator wrote, at the dump's first time and every
      // edge (x included): split 1-bit arrays the reader merged (valid [0], valid [1] as valid[1:0]),
      // array elements it made scopes of (order > [0]) and plain vectors.
      {
        const at = (changes, t) => { let v = null; for (const c of changes) { if (Number(c[0]) <= t) { v = String(c[1]); } else { break; } } return v; };
        const groups = new Map();
        for (const g of run.signals) {
          const leaf = g.path[g.path.length - 1];
          const m = /^(.*)\[(\d+)\]$/.exec(leaf);
          const key = JSON.stringify(g.path.slice(0, -1).concat([m && g.width === 1 ? m[1] : leaf]));
          if (!groups.has(key)) { groups.set(key, []); }
          groups.get(key).push({ g, index: m ? Number(m[2]) : null });
        }
        let bad = 0, checked = 0, firstBad = null;
        for (const [key, parts] of groups) {
          const path = JSON.parse(key);
          const leaf = path[path.length - 1];
          const m = /^(.*)\[(\d+)\]$/.exec(leaf);
          let v = await W.host.findLinkItem(path, true);
          if (!v && m) { v = await W.host.findLinkItem(path.slice(0, -1).concat([m[1], '[' + m[2] + ']']), true); }
          if (!v) { bad++; firstBad = firstBad || path.join('.') + ' not found'; continue; }
          const read = await W.host.signalChanges(v, 1e6);
          const ordered = parts.slice().sort((a, b) => (b.index || 0) - (a.index || 0));
          const times = [0, Number(read[0] ? read[0][0] : 0)].concat(run.edges);
          for (const t of times) {
            const want = ordered.map((p) => at(p.g.changes, t) || 'x'.repeat(p.g.width)).join('');
            const got = at(read, t) || 'x'.repeat(want.length);
            checked++;
            if (got !== want) { bad++; firstBad = firstBad || path.join('.') + ' at t ' + t + ': ' + got + ' != ' + want; }
          }
        }
        expect(bad === 0, opts.name + ': the reader has every written value (' + groups.size + ' signals, ' + checked + ' samples): ' + (firstBad || 'all equal'));
      }
      // The reader's own values: a 1-bit array (valid [0], valid [1]) the reader merged into one vector
      // has, at every edge and the dump's first time, the bits the generator wrote (x included).
      const parts = run.signals.filter((g) => /^valid\[\d+\]$/.test(g.path[g.path.length - 1]));
      if (parts.length) {
        const merged = await W.host.findLinkItem(x.scope.concat(['valid']), true);
        if (merged && Number(merged.width) === parts.length) {
          const at = (changes, t) => { let v = null; for (const c of changes) { if (Number(c[0]) <= t) { v = String(c[1]); } else { break; } } return v; };
          const read = await W.host.signalChanges(merged, 1e6);
          const times = [Number(read[0][0])].concat(run.edges);
          let bad = 0, firstBad = null;
          for (const t of times) {
            const want = parts.slice().reverse().map((g) => at(g.changes, t) || 'x').join('');
            const got = at(read, t);
            if (got !== want) { bad++; firstBad = firstBad || 't ' + t + ': ' + got + ' != ' + want; }
          }
          expect(bad === 0, opts.name + ': the reader\'s merged valid[' + (parts.length - 1) + ':0] equals the written bits at ' + times.length + ' times: ' + (firstBad || 'all equal'));
        }
      }
      expect(s.source === x.scope.join('.') + (opts.name === 'monitor' ? '.monitor_*' : ''), opts.name + ': found at ' + s.source);
      let checked = 0, bad = 0, firstBad = null;
      for (const probe of x.states.slice(0, 24)) {
        await M.goToCommit({ k: probe.k });
        const r = M.registers();
        if (r.k !== probe.k) { bad++; firstBad = firstBad || 'k ' + r.k + ' for ' + probe.k; continue; }
        probe.regs.forEach((want, i) => {
          const got = r.regs[i].value;
          if (want === null) { if (got !== '—') { bad++; firstBad = firstBad || 'x' + i + ' at ' + probe.k + ' is ' + got + ', unknown expected'; } return; }
          checked++;
          if (big(got) !== BigInt(want)) { bad++; firstBad = firstBad || 'x' + i + ' at ' + probe.k + ': ' + got + ' != 0x' + want.toString(16); }
        });
      }
      expect(bad === 0 && checked > 200, opts.name + ': registers at 24 probes as the replay says (' + checked + ' known): ' + (firstBad || 'all equal'));
      // History in program order (packed2 has same-cycle pairs whose older one is on channel 1).
      await M.goToCommit({ k: 40 });
      const h = M.history();
      const orders = h.map((e) => Number(e.order));
      expect(orders.every((o, i) => i === 0 || o === orders[i - 1] + 1 || x.commits[0].order === null), opts.name + ': history in program order: ' + orders.slice(0, 6).join(','));
      if (x.swapped) { expect(h.length === 20, opts.name + ': ' + x.swapped + ' same-cycle pairs retire out of channel order'); }
      // F10 by commit inside a cycle: two commits in one cycle are two steps on the same posedge.
      const pair = x.commits.findIndex((c, i) => i > 0 && x.commits[i - 1].time === c.time);
      if (x.nret === 2 && pair > 0) {
        M.setMode({ mode: 'instruction' });
        await M.goToCommit({ k: pair - 1 });
        const before = D.markerTime();
        await D.step({ by: 1 });
        const st = M.state();
        expect(st.k === pair && D.markerTime() === before, opts.name + ': F10 to the second commit of a cycle keeps the marker on it: ' + [st.k, pair, D.markerTime(), before].join(' '));
        await D.step({ by: 1 });
        expect(M.state().k === pair + 1, opts.name + ': and the next F10 goes on to the commit after: ' + M.state().k);
        M.setMode({ mode: 'auto' });
      }
      if (opts.name === 'monitor') {
        // The user's own picks (Use as Commit): valid and pc are enough to see pcs; rd gives registers.
        const scope = x.scope;
        for (const role of ['valid', 'pc_rdata', 'rd_addr', 'rd_wdata', 'rs1_addr', 'rs1_rdata', 'rs2_addr', 'rs2_rdata', 'trap']) {
          await M.pick({ role, path: scope.concat(['monitor_' + role]) });
        }
        s = M.state();
        expect(s.family === 'manual' && s.count === x.count, 'picked by hand: ' + JSON.stringify([s.family, s.count, s.source]));
        const probe = x.states.find((p) => p.k > 100 && p.regs[5] !== null);
        await M.goToCommit({ k: probe.k });
        expect(big(M.registers().regs[5].value) === BigInt(probe.regs[5]), 'and its t0 at ' + probe.k + ' is the replay\'s: ' + M.registers().regs[5].value);
        await M.forget();
        expect(M.state().family === 'fields', 'Forget goes back to the stream found: ' + M.state().family);
      }
      if (opts.name === 'forward') {
        expect(s.disagreements.regs >= 1, 'forward: the bad forwarded read is flagged: ' + JSON.stringify(s.disagreements));
        M.show({ tab: 'registers' });
        await sleep(30);
        const warn = Array.from(document.querySelectorAll('#cmux-machine .warning')).map((w) => w.textContent);
        expect(warn.some((w) => /register reads disagree/.test(w)), 'and the pane says so: ' + warn.join(' | '));
      }
      return { lines, failures };
    }

    if (opts.kind === 'fsdb') {
      // A course run (VCS, FSDB through the helper) against its own Spike-format commit.log.
      const log = root.machineSpikeReplay(opts.spikeLog, 0);
      // commit.log may stop before the halt loop the core then retires (a branch or jump to itself).
      const extra = s.count > log.length ? M.commits({ from: log.length, count: Math.min(4, s.count - log.length) }) : [];
      const selfLoop = (c) => c && ['63', '6f', 'a001'].includes(c.insn);
      expect(s.count === log.length || (s.count - log.length <= 2 && extra.every((c) => selfLoop(c) && c.pc === extra[0].pc)),
        opts.name + ': ' + s.count + ' commits = commit.log\'s ' + log.length + ' lines' + (extra.length ? ' and the halt loop: ' + JSON.stringify(extra) : '')
        + '; held repeats dropped: ' + (s.diagnostics && s.diagnostics.heldRepeats));
      expect(s.diagnostics && s.diagnostics.orderContiguous !== false, opts.name + ': order contiguous: ' + JSON.stringify(s.diagnostics));
      if (s.diagnostics && s.diagnostics.orderContiguous === false) {
        // Where order skips or repeats, through the commit-index API.
        const ix = await W.commits.index();
        const gaps = [];
        for (let k = 1; k < ix.count && gaps.length < 4; k++) {
          if (ix.order[k] !== ix.order[k - 1] + 1) { gaps.push({ k, order: [ix.order[k - 1], ix.order[k]], pc: [ix.pc[k - 1].toString(16), ix.pc[k].toString(16)], time: [ix.time[k - 1], ix.time[k]] }); }
        }
        note(opts.name + ': order gaps at ' + JSON.stringify(gaps));
      }
      let pcBad = 0, insnBad = 0, rdBad = 0, rdChecked = 0, first = null;
      const tRead = performance.now();
      const both = Math.min(s.count, log.length);
      if (s.count !== log.length) {
        // Where the two first part: the commits around the end of the shorter one.
        const at = Math.max(0, both - 3);
        note(opts.name + ': page commits ' + at + '..: ' + JSON.stringify(M.commits({ from: at, count: 6 })) + '; commit.log: '
          + JSON.stringify(log.slice(at, at + 6).map((c) => [c.pc.toString(16), c.insn.toString(16), c.rd])));
      }
      for (let from = 0; from < both; from += 50000) {
        const chunk = M.commits({ from, count: Math.min(50000, both - from) });
        chunk.forEach((c, i) => {
          const want = log[from + i];
          if (c.pc === null || parseInt(c.pc, 16) !== want.pc) { pcBad++; first = first || 'pc at ' + (from + i) + ': ' + c.pc + ' != ' + want.pc.toString(16); }
          if (c.insn === null || parseInt(c.insn, 16) !== want.insn) { insnBad++; first = first || 'insn at ' + (from + i) + ': ' + c.insn + ' != ' + want.insn.toString(16); }
          if (want.rd !== null && want.rd !== 0) {
            rdChecked++;
            if (c.rd !== want.rd || c.rdv === null || BigInt('0x' + c.rdv) !== want.rdv) { rdBad++; first = first || 'rd at ' + (from + i) + ': x' + c.rd + '=' + c.rdv + ' != x' + want.rd + '=' + want.rdv.toString(16); }
          }
        });
      }
      expect(pcBad === 0 && insnBad === 0 && rdBad === 0 && rdChecked > 100000,
        opts.name + ': pc, insn and ' + rdChecked + ' rd writes equal commit.log: ' + (first || 'all equal') + ' (' + (performance.now() - tRead).toFixed(0) + ' ms)');
      // The state at random commits: registers against commit.log replayed.
      const regsAt = (k) => { const out = new Array(32).fill(null); out[0] = 0n; for (let j = 0; j < k; j++) { if (log[j].rd) { out[log[j].rd] = log[j].rdv; } } return out; };
      let bad = 0, known = 0;
      const times = [];
      for (const k of [1000, 77777, 250000, 500001, both - 1]) {
        progress('go to commit ' + k);
        const t1 = performance.now();
        await M.goToCommit({ k });
        const r = M.registers();
        times.push(performance.now() - t1);
        const want = regsAt(k);
        for (let i = 1; i < 32; i++) {
          if (want[i] === null || r.regs[i].value === '—' || r.regs[i].value === 'x') { continue; }
          known++;
          if (BigInt(r.regs[i].value) !== want[i]) { bad++; }
        }
      }
      expect(bad === 0 && known > 100, opts.name + ': registers at 5 commits equal commit.log (' + known + ' values)');
      note(opts.name + ': go to commit + registers: ' + times.map((t) => t.toFixed(1)).join(', ') + ' ms');
      // Warm: the same stream built again (the changes are cached in the page's reader).
      const t2 = performance.now();
      const w = await M.useSource({ index: 0 });
      const warmMs = performance.now() - t2;
      note(opts.name + ': rebuilt warm in ' + warmMs.toFixed(0) + ' ms');
      expect(w && w.cacheHit === true && w.count === s.count && warmMs < buildMs / 4,
        opts.name + ': the warm rebuild reuses the table cached by the dump\'s identity: ' + JSON.stringify([w && w.cacheHit, w && w.count, Math.round(warmMs), Math.round(buildMs)]));
      const t3 = performance.now();
      M.setMode({ mode: 'instruction' });
      for (let i = 0; i < 20; i++) { await D.step({ by: 1 }); }
      note(opts.name + ': 20 F10 by commit in ' + (performance.now() - t3).toFixed(0) + ' ms');
      const t4 = performance.now();
      const g = await M.gdb({ text: 'info registers' });
      note(opts.name + ': info registers in ' + (performance.now() - t4).toFixed(1) + ' ms: ' + g.lines[0]);
      // Sequence search on the course run (§3A's estimate: tens of ms).
      for (const q of ['{lw} as L ##1 rs1 == L.rd || rs2 == L.rd', '/jal\\s+(ra|x1)/ ##[1:$] {ret}', '{branch} && taken ##1 {branch} && taken ##1 {branch} && taken',
        '(cls == STORE, a = mem_addr) ##[1:$] cls == LOAD && mem_addr == a']) {
        progress('sequence ' + q);
        const t = performance.now();
        const r = await M.sequence({ query: q });
        note(opts.name + ': ' + q + ': ' + (r.error ? r.message : r.matches.length + ' matches' + (r.incomplete ? ' (incomplete)' : '') + ', ' + r.evaluated + ' steps') + ' in ' + (performance.now() - t).toFixed(0) + ' ms');
      }
      const lu = await M.sequence({ query: '{lw} as L ##1 rs1 == L.rd || rs2 == L.rd' });
      const Q = root.cmuxSequence;
      const oracle = { count: log.length, xlen: 32, roles: [], insn: (k) => (log[k] ? log[k].insn : null), pc: (k) => (log[k] ? log[k].pc : null), value: () => null };
      const lw = Q.search(oracle, '{lw} as L ##1 rs1 == L.rd || rs2 == L.rd');
      expect(!lu.error && lu.matches.length === lw.matches.length, opts.name + ': load-use matches as over commit.log: ' + (lu.matches || []).length + ' vs ' + lw.matches.length);
      if (opts.image) {
        const img = M.setImage(opts.image);
        const st2 = M.state();
        expect(img.segments >= 1 && st2.disagreements.elf === null, opts.name + ': its ELF image agrees with every load: ' + JSON.stringify([img, st2.disagreements]));
      }
      return { lines, failures };
    }

    // ---- a core against Spike ----
    const spike = root.machineSpikeReplay(opts.spikeLog);
    expect(s.family === 'rvfi' && s.source === 'tb.dut' && s.nret === 1, opts.name + ': tb.dut rvfi_*: ' + s.source);
    expect(s.disagreements && s.disagreements.regs === 0 && s.disagreements.mem === 0, opts.name + ': the replay agrees with every read: ' + JSON.stringify(s.disagreements));
    // pc of every commit = Spike's (the core may run a few more self-loop commits than Spike logged).
    let pcBad = 0, pcFirst = null;
    const n = Math.min(s.count, spike.length);
    for (let k = 0; k < n; k += 1) {
      const g = await M.gdb({ text: 'output/x $pc', k });
      if (big(g.lines[0]) !== BigInt(spike[k].pc)) { pcBad++; pcFirst = pcFirst || k + ': ' + g.lines[0] + ' != 0x' + spike[k].pc.toString(16); }
      if (k > 400) { k += 6; }
    }
    expect(pcBad === 0, opts.name + ': pc as Spike\'s through gdb output/x $pc: ' + (pcFirst || 'all equal'));
    // Registers before commit k, through the pane's own view, against Spike's log replayed.
    const regsAt = (k) => {
      const out = new Array(32).fill(null);
      out[0] = 0n;
      for (let j = 0; j < k && j < spike.length; j++) { if (spike[j].rd !== null && spike[j].rd !== 0) { out[spike[j].rd] = spike[j].rdv; } }
      return out;
    };
    let known = 0, unknown = 0, bad = 0, first = null;
    for (let k = 0; k <= n; k += 37) {
      await M.goToCommit({ k });
      const r = M.registers();
      const want = regsAt(k);
      for (let i = 1; i < 32; i++) {
        const got = r.regs[i].value;
        if (want[i] === null || got === 'x') { continue; }
        if (got === '—') { unknown++; continue; }
        known++;
        if (big(got) !== want[i]) { bad++; first = first || 'x' + i + ' at ' + k + ': ' + got + ' != 0x' + want[i].toString(16); }
      }
    }
    expect(bad === 0 && known > 500, opts.name + ': ' + known + ' register values equal Spike\'s (' + unknown + ' unknown): ' + (first || 'all equal'));

    // ---- the ELF image (WaveformMachineState.loadImage in cmux: readelf's PT_LOAD and symbols) ----
    const before = await M.gdb({ text: 'x/4xw &table', k: 0 });
    expect(/No symbol|—|not in this waveform/.test(before.lines.join(' ')) || before.error, opts.name + ': before the ELF, &table is unknown: ' + before.lines[0]);
    const img = M.setImage(opts.image);
    expect(img.segments >= 1 && img.symbols > 5, opts.name + ': setImage: ' + JSON.stringify(img));
    s = M.state();
    expect(s.disagreements.elf === null && s.disagreements.mem === 0, opts.name + ': no load disagrees with the image: ' + JSON.stringify(s.disagreements));
    const tbl = await M.gdb({ text: 'x/4xw &table', k: 0 });
    expect(/^0x[0-9a-f]+ <table>:\t0x[0-9a-f]{8}\t0x[0-9a-f]{8}\t0x[0-9a-f]{8}\t0x[0-9a-f]{8}$/.test(tbl.lines[0]), opts.name + ': x/4xw &table from the image before any commit: ' + tbl.lines[0]);
    const ins = await M.gdb({ text: 'x/3i $pc', k: 0 });
    expect(ins.lines.length === 3 && /^=> 0x80000080 <_start>:/.test(ins.lines[0]), opts.name + ': x/3i $pc at the first commit: ' + ins.lines.join(' | '));
    const sym = await M.gdb({ text: 'info symbol 0x80000084' });
    expect(/^_start \+ 4$/.test(sym.lines[0]), opts.name + ': info symbol 0x80000084: ' + sym.lines[0]);

    // ---- Evaluate, watches and conditions with $ names ----
    await M.goToCommit({ k: 200 });
    const sp = await D.evaluate({ expr: '$sp' });
    const spWant = regsAt(200)[2];
    expect(!sp.error && sp.width === 32, opts.name + ': Evaluate $sp: ' + JSON.stringify([sp.value, sp.error, sp.message]));
    const spBits = sp.bits ? BigInt('0b' + sp.bits) : null;
    expect(spBits === spWant, opts.name + ': it is Spike\'s sp: ' + sp.bits + ' vs 0x' + (spWant === null ? 'null' : spWant.toString(16)));
    const arith = await D.evaluate({ expr: '$sp - 32\'d16 == $x2 - 32\'d16' });
    expect(!arith.error && arith.bits === '1', opts.name + ': $sp and $x2 are the same register: ' + JSON.stringify([arith.value, arith.message]));
    const mem = await D.evaluate({ expr: '$mem32($sp)' });
    expect(mem.error ? mem.error === 'noValue' : mem.width === 32, opts.name + ': $mem32($sp): ' + JSON.stringify([mem.value, mem.message]));
    const unknownReg = await D.evaluate({ expr: '$bogus' });
    expect(unknownReg.error, opts.name + ': $bogus is not a register: ' + unknownReg.message);
    const gdbEval = await D.evaluate({ expr: 'p/x $sp', show: true });
    expect(gdbEval.gdb && /^\$\d+ = 0x[0-9a-f]+$/.test(gdbEval.value) && BigInt(gdbEval.value.split(' = ')[1]) === spWant, opts.name + ': p/x $sp in Evaluate: ' + gdbEval.value);
    const regsEval = await D.evaluate({ expr: 'info registers', show: true });
    expect(regsEval.gdb && regsEval.lines.length === 32 && /^ra\s+/.test(regsEval.lines[0]), opts.name + ': info registers in Evaluate: 32 lines, first ' + regsEval.lines[0]);
    expect(M.console().some((l) => l === '(gdb) info registers'), opts.name + ': and its lines are in the console');
    const strip = document.querySelector('.cmux-eval .result');
    expect(strip && /^ra\s+/.test(strip.textContent), opts.name + ': the strip shows the first line: ' + (strip && strip.textContent));
    D.addWatch({ expr: '$a5' });
    D.addWatch({ expr: '$mem32($sp + 32\'d12)' });
    await sleep(100);
    await M.goToCommit({ k: 300 });
    const a5Want = regsAt(300)[15];
    // The watches refresh after the move: wait for the value at 300 (the one at 200 may be an error).
    let ws = [];
    for (let i = 0; i < 80; i++) { ws = D.watches(); if (ws.length >= 2 && (a5Want === null || !ws[0].error) && (ws[1].value || ws[1].error)) { break; } await sleep(25); }
    const hexOf = (text) => { const m = /'h([0-9a-fA-F_]+)$/.exec(String(text)); return m ? BigInt('0x' + m[1].replace(/_/g, '')) : null; };
    expect(ws[0] && (a5Want === null ? !!(ws[0].error || ws[0].value) : hexOf(ws[0].value) === a5Want),
      opts.name + ': watch $a5 at commit 300: ' + JSON.stringify(ws[0]) + ' (Spike 0x' + (a5Want === null ? '?' : a5Want.toString(16)) + ')');
    expect(ws[1] && (ws[1].value || ws[1].error), opts.name + ': watch $mem32($sp + 12): ' + JSON.stringify(ws[1]));
    // A conditional breakpoint on the commit valid: lands on the first commit whose pc is `main`.
    const mainAddr = (await M.gdb({ text: 'output/x main', k: 0 })).lines[0];
    const mainK2 = spike.findIndex((c) => BigInt(c.pc) === BigInt(mainAddr));
    await D.jump({ to: 'first' });
    const bp = await D.addBreakpoint({ path: ['tb', 'dut', 'rvfi_valid'], kind: 'change' });
    await D.setBreakpointCondition({ id: bp.id, condition: '$pc == 32\'h' + BigInt(mainAddr).toString(16) });
    // valid may stay high: a change breakpoint fires on its rises only; also stop on any pc change.
    const bp2 = await D.addBreakpoint({ path: ['tb', 'dut', 'rvfi_pc_rdata'], kind: 'change' });
    await D.setBreakpointCondition({ id: bp2.id, condition: '$pc == 32\'h' + BigInt(mainAddr).toString(16) });
    const hit = await D.continue({ dir: 1 });
    await sleep(50);
    const kHit = M.state().k;
    expect(hit && hit.hit && kHit === mainK2, opts.name + ': a breakpoint if $pc == main stops at commit ' + mainK2 + ': ' + JSON.stringify([hit && hit.hit, kHit]));
    D.removeBreakpoint({ id: bp.id });
    D.removeBreakpoint({ id: bp2.id });

    // ---- F10 by commit (Instruction mode), Shift-F10 back, Cycle mode by cycle ----
    M.setMode({ mode: 'instruction' });
    await M.goToCommit({ k: 100 });
    await D.step({ by: 1 });
    const k1 = M.state().k;
    await D.step({ by: 1 });
    const k2 = M.state().k;
    await D.step({ by: -1 });
    const k3 = M.state().k;
    expect(k1 === 101 && k2 === 102 && k3 === 101, opts.name + ': F10, F10, Shift-F10 by commit: ' + [k1, k2, k3].join(' '));
    const tAt = D.markerTime();
    expect(tAt === M.history().find((h) => h.k === 101).time, opts.name + ': the marker is on commit 101\'s cycle: ' + tAt);
    M.setMode({ mode: 'cycle' });
    const edges = await D.edges();
    const before10 = D.markerTime();
    await D.step({ by: 1 });
    await markerIs(edges[edges.indexOf(before10) + 1]);
    expect(D.markerTime() === edges[edges.indexOf(before10) + 1], opts.name + ': in Cycle mode F10 is one cycle: ' + [before10, D.markerTime()].join(' → '));
    // Auto: by instruction only while the Machine section has focus.
    M.setMode({ mode: 'auto' });
    M.show({ tab: 'registers' });
    await sleep(30);
    const box = document.getElementById('cmux-machine');
    expect(!M.state().instructionMode, opts.name + ': auto without focus: by cycle');
    box.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    expect(M.state().instructionMode, opts.name + ': auto with the section clicked: by instruction');
    document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    expect(!M.state().instructionMode, opts.name + ': and a click elsewhere goes back to cycles');

    // ---- the pane ----
    await M.goToCommit({ k: 150 });
    await sleep(30);
    expect(box && !box.hidden && box.parentElement && box.parentElement.id === 'netlist', opts.name + ': the Machine section is in the netlist pane');
    expect(box.querySelectorAll('.reg').length === 32, opts.name + ': 32 register rows: ' + box.querySelectorAll('.reg').length);
    const pcLine = box.querySelector('.pc').textContent;
    expect(/^pc 0x8000[0-9a-f]{4} <\w+(\+\d+)?>  \S/.test(pcLine), opts.name + ': pc line with its symbol and instruction: ' + pcLine);
    const tabs = Array.from(box.querySelectorAll('.tab')).map((t) => t.dataset.tab);
    expect(tabs.join(',') === (opts.name === 'nerv' ? 'registers,memory,csrs,history,sequences' : 'registers,memory,history,sequences'), opts.name + ': tabs ' + tabs.join(','));
    // A stepped-over write is marked strongly; pending writes show →.
    M.setMode({ mode: 'instruction' });
    const pendK = (() => { for (let k = 150; k < s.count; k++) { if (spike[k] && spike[k].rd) { return k; } } return null; })();
    await M.goToCommit({ k: pendK });
    await D.step({ by: 1 });
    await sleep(30);
    const rd = spike[pendK].rd;
    const row = box.querySelector('.reg[data-reg="x' + rd + '"]');
    expect(row && /changed-strong/.test(row.className), opts.name + ': the register commit ' + pendK + ' wrote is marked: ' + (row && row.className));
    await M.goToCommit({ k: pendK });
    await sleep(30);
    const prow = box.querySelector('.reg[data-reg="x' + rd + '"] .pending');
    expect(prow && prow.textContent === '→ 0x' + spike[pendK].rdv.toString(16).padStart(8, '0'), opts.name + ': and before it, its write is pending: ' + (prow && prow.textContent));
    M.setMode({ mode: 'auto' });
    // Memory tab: x/ at $sp, i format.
    M.setTab({ tab: 'memory' });
    M.setMemory({ expr: 'main', unit: 'w', count: 8, fmt: 'i' });
    await sleep(30);
    const ilines = Array.from(box.querySelectorAll('.mem .line')).map((l) => l.textContent);
    expect(ilines.length === 8 && /<main>:\t\S/.test(ilines[0]), opts.name + ': Memory as instructions at main: ' + ilines[0]);
    M.setMemory({ expr: '$sp', unit: 'w', count: 16, fmt: 'x' });
    await sleep(30);
    const cells = box.querySelectorAll('.mem .cell');
    expect(cells.length === 16, opts.name + ': 16 words at $sp: ' + cells.length);
    M.setTab({ tab: 'history' });
    await sleep(30);
    const cur = box.querySelector('.history .commit.current');
    expect(cur && cur.dataset.k === '150', opts.name + ': History marks the current commit: ' + (cur && cur.dataset.k));
    box.querySelector('.history .commit[data-k="152"]').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await sleep(80);
    expect(M.state().k === 152, opts.name + ': clicking a History row goes there: ' + M.state().k);
    if (opts.name === 'nerv') {
      M.setTab({ tab: 'csrs' });
      await sleep(30);
      const csr = Array.from(box.querySelectorAll('.csr')).map((c) => c.dataset.csr);
      expect(csr.includes('mscratch'), opts.name + ': CSRs: ' + csr.join(','));
    }

    // ---- row actions ----
    await M.goToCommit({ k: Math.min(s.count, 600) });
    const kNow = M.state().k;
    clearToasts();
    const lw = await M.rowAction({ action: 'lastWrite', loc: 'sp' });
    let spWriter = null;
    for (let j = kNow - 1; j >= 0; j--) { if (spike[j].rd === 2) { spWriter = j; break; } }
    expect(lw.k === spWriter && M.state().k === spWriter, opts.name + ': Who Last Wrote sp at ' + kNow + ': commit ' + lw.k + ' (Spike ' + spWriter + ')');
    expect(toasts().some((t) => /^sp was last written by commit/.test(t)), opts.name + ': and says so: ' + toasts().join(' | '));
    const nw = await M.rowAction({ action: 'nextWrite', loc: 'sp' });
    let spNext = null;
    for (let j = spWriter + 1; j < spike.length; j++) { if (spike[j].rd === 2) { spNext = j; break; } }
    expect(nw.k === spNext, opts.name + ': Next Write: ' + nw.k + ' (Spike ' + spNext + ')');
    const store = spike.findIndex((c, j) => j > 50 && c.mem.some((m) => m.value !== null));
    const addr = spike[store].mem.find((m) => m.value !== null).addr;
    await M.goToCommit({ k: store + 5 });
    const mw = await M.rowAction({ action: 'lastWrite', loc: { addr } });
    expect(mw.k !== null && mw.k <= store, opts.name + ': Who Last Wrote 0x' + addr.toString(16) + ': ' + mw.k + ' (Spike stored at ' + store + ')');
    const aw = await M.rowAction({ action: 'addWatch', loc: 'a0' });
    expect(aw.expr === '$a0' && D.watches().some((w) => w.expr === '$a0'), opts.name + ': Add Watch on a0: ' + aw.expr);
    // The waveform row's menu has Use as Commit.
    const v = await W.host.findLinkItem(['tb', 'dut', 'rvfi_valid'], true);
    const items = root.cmuxDebugger.rowMenuItems({ webviewSection: 'signal', netlistId: v.netlistId });
    const use = items.find((i) => i.label === 'Use as Commit');
    expect(use && use.items.length >= 10 && use.items[0].label === 'valid', opts.name + ': the row menu has Use as Commit ▸ roles: ' + items.map((i) => i.label || '-').join(', '));

    // ---- sequence search (§3A): the Sequences tab, against the same search over Spike's log ----
    const Q = root.cmuxSequence;
    const oracle = { count: Math.min(s.count, spike.length), xlen: 32, roles: [], insn: (k) => (spike[k] ? spike[k].insn : null), pc: (k) => (spike[k] ? spike[k].pc : null), value: () => null };
    const query = '{lw} as L ##1 rs1 == L.rd || rs2 == L.rd';
    const want = Q.search(oracle, query).matches.filter((m) => m.end < oracle.count);
    const got = await M.setSequence({ query });
    expect(got && !got.error && got.matches.length === want.length && got.matches.every((m, i) => m.start === want[i].start && m.end === want[i].end),
      opts.name + ': ' + query + ': ' + (got && got.matches ? got.matches.length : JSON.stringify(got)) + ' matches as over Spike\'s log (' + want.length + ')');
    await sleep(30);
    const rows = box.querySelectorAll('.seqlist .match');
    expect(rows.length === Math.min(500, want.length) && /⟶/.test(rows[0].textContent), opts.name + ': the Sequences tab lists them: ' + rows.length + ', ' + (rows[0] && rows[0].textContent));
    rows[1].dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await sleep(80);
    expect(M.state().k === want[1].end, opts.name + ': clicking a match goes to its last step: ' + M.state().k + ' (' + want[1].end + ')');
    // Break Here: a sequence breakpoint from the tab's query (as typed, Enter or not) and its Go to.
    const seqBps = () => D.breakpoints().filter((b) => b.kind === 'sequence').map((b) => [b.query, b.land]);
    const breakHere = () => box.querySelector('.seqbar .break');
    expect(breakHere() && breakHere().textContent === 'Break Here', opts.name + ': the Sequences tab offers Break Here: ' + (breakHere() && breakHere().textContent));
    // What it did is said: added, already there, or enabled again, naming it (the debugger's label; its
    // strings are cmux's, not loaded here: one given).
    if (W.strings && !W.strings.debuggerBreakpointSequence) { W.strings.debuggerBreakpointSequence = 'Sequence %@'; }
    const said = [];
    const realToast = root.cmuxUI.toast;
    root.cmuxUI.toast = (text, kind) => { said.push(text); return realToast(text, kind); };
    breakHere().dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await sleep(30);
    expect(JSON.stringify(seqBps()) === JSON.stringify([[query, 'end']]), opts.name + ': Break Here makes a sequence breakpoint of the query: ' + JSON.stringify(seqBps()));
    const made = D.breakpoints().find((b) => b.kind === 'sequence');
    breakHere().dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await sleep(30);
    D.setBreakpointEnabled({ id: made.id, enabled: false });
    breakHere().dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await sleep(30);
    root.cmuxUI.toast = realToast;
    expect(JSON.stringify(said) === JSON.stringify(['Breakpoint added: ' + made.label, 'Already a breakpoint: ' + made.label, 'Breakpoint enabled again: ' + made.label])
      && made.label.includes(query) && seqBps().length === 1 && D.breakpoints().find((b) => b.id === made.id).enabled,
      opts.name + ': Break Here says what it did (added, already there, enabled again): ' + JSON.stringify(said));
    box.querySelector('.seqbar .land').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await sleep(30);
    box.querySelector('.seqbar .query').value = '{sw} ##1 {lw}';
    breakHere().dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await sleep(30);
    expect(JSON.stringify(seqBps()) === JSON.stringify([[query, 'end'], ['{sw} ##1 {lw}', 'start']]),
      opts.name + ': a query typed without Enter, landing where Go to says (first step): ' + JSON.stringify(seqBps()));
    box.querySelector('.seqbar .query').value = '  ';
    breakHere().dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await sleep(30);
    expect(seqBps().length === 2, opts.name + ': none for an empty query: ' + JSON.stringify(seqBps()));
    for (const b of D.breakpoints().filter((x) => x.kind === 'sequence')) { D.removeBreakpoint({ id: b.id }); }
    box.querySelector('.seqbar .land').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    await sleep(30);
    const times = await W.commits.sequenceTimes({ query, land: 'start' });
    expect(times.times.length === want.length && Array.from(times.times).every((t, i, a) => i === 0 || a[i - 1] <= t),
      opts.name + ': commits.sequenceTimes: ' + times.times.length + ' times');
    const badq = await M.sequence({ query: '{lw} ##[3:1] {add}' });
    expect(badq.error === 'badDelay' && /delay must be/.test(badq.message), opts.name + ': a bad delay says why: ' + badq.message);
    // Why a search stopped, given (the messages differ by reason): its step budget, or none when it finished.
    const cut = await M.sequence({ query: '{lw} ##[1:$] {sw}', budget: 1 });
    const whole = await M.sequence({ query: '{lw} ##[1:$] {sw}', budgetMs: 60000 });
    expect(!cut.error && cut.incomplete && cut.reason === 'budget' && cut.next !== null && !whole.error && !whole.incomplete && whole.reason === null,
      opts.name + ': a search says why it stopped: ' + JSON.stringify([cut.reason, cut.next, whole.reason]));
    const t5 = performance.now();
    const call = await M.sequence({ query: '/jal\\s+ra/ ##[1:$] {ret}' });
    note(opts.name + ': call ##[1:$] ret: ' + call.matches.length + ' matches in ' + (performance.now() - t5).toFixed(1) + ' ms');
    return { lines, failures };
  }

  root.runMachinePageChecks = runMachinePageChecks;
})(typeof window !== 'undefined' ? window : globalThis);
