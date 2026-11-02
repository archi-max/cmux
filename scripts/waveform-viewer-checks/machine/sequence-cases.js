// Instruction-sequence search checks (run.sh machine-core, group `sequence`): Resources/vaporview/cmux-sequence.js.
// A hand-made stream with known answers; the search against a brute-force matcher (every path, the earliest end
// per start) on random streams; the Ibex fixture's RVFI stream against the same search over Spike's log of the run.
(function (root) {
  'use strict';

  // Instruction words (RV32I/C), checked against the disassembler below.
  const W = {
    'lw a0,8(sp)': 0x00812503, 'add a1,a0,a2': 0x00c505b3, 'addi a2,a2,1': 0x00160613, 'sw a1,0(sp)': 0x00b12023,
    'lw a3,0(sp)': 0x00012683, 'jal ra,pc+16': 0x010000ef, 'ret': 0x00008067, 'beq a0,a1,pc+8': 0x00b50463,
    'csrw mtvec,a0': 0x30551073, 'mret': 0x30200073, 'nop': 0x00000013, 'lw a0,4(a1)': 0x41c8,
  };

  // A stream from rows { w, mem, next } (pc sequential by size unless `next`).
  function streamFrom(rows) {
    const pcs = [];
    let pc = 0x80000000;
    rows.forEach((r, k) => { pcs.push(pc); const size = (r.w & 3) === 3 ? 4 : 2; pc = r.next !== undefined ? pcs[k] + r.next : pc + size; });
    const pcw = rows.map((r, k) => (r.next !== undefined ? pcs[k] + r.next : pcs[k] + ((r.w & 3) === 3 ? 4 : 2)));
    return { count: rows.length, xlen: 32, roles: ['insn', 'pc_rdata', 'pc_wdata', 'mem_addr'],
      insn: (k) => (k >= 0 && k < rows.length ? rows[k].w : null), pc: (k) => (k >= 0 && k < rows.length ? pcs[k] : null),
      value: (role, k) => {
        if (k < 0 || k >= rows.length) { return null; }
        if (role === 'pc_wdata') { return BigInt(pcw[k]); }
        if (role === 'mem_addr') { return rows[k].mem === undefined ? 0n : BigInt(rows[k].mem); }
        return null;
      }, widthOf: () => 32 };
  }

  // Every path, the earliest end per start (memoized on step, commit and captures).
  function bruteForce(stream, text) {
    const S = root.cmuxSequence, X = root.cmuxExpr;
    const c = S.compile(text, stream);
    const n = stream.count;
    const after = (step, k, ctx) => {
      const caps = step.src.capture ? Object.assign({}, ctx.caps, { [step.src.capture]: k }) : ctx.caps;
      const locals = Object.assign({}, ctx.locals);
      for (const a of step.src.assigns) {
        const r = X.evaluate(a.ast, (p) => (p.length === 1 && locals[p[0]] !== undefined ? locals[p[0]] : c.fieldAt(p[0], k)));
        locals[a.name] = { width: r.value.w, value: r.value };
      }
      return { caps, locals };
    };
    const full = (step) => (step.staticAst && step.dynamicAst ? { t: 'bin', op: '&&', l: step.staticAst, r: step.dynamicAst, at: 0 } : (step.staticAst || step.dynamicAst));
    const holds = (s, k, ctx) => { const ast = full(c.steps[s]); return !ast || c.holds(c.steps[s], ast, k, ctx); };
    const memo = new Map();
    const endFrom = (s, k, ctx) => {  // step s holds at k with ctx before it: the earliest end, or Infinity
      if (!holds(s, k, ctx)) { return Infinity; }
      const next = after(c.steps[s], k, ctx);
      if (s === c.steps.length - 1) { return k; }
      const key = s + ':' + k + ':' + JSON.stringify(next.caps) + JSON.stringify(Object.keys(next.locals).map((x) => next.locals[x].value.a.toString()));
      if (memo.has(key)) { return memo.get(key); }
      const { min, max } = c.steps[s + 1].src.delay;
      let best = Infinity;
      for (let j = k + min; j <= Math.min(n - 1, max === Infinity ? n - 1 : k + max) && j < best; j++) { best = Math.min(best, endFrom(s + 1, j, next)); }
      memo.set(key, best);
      return best;
    };
    const out = [];
    for (let k = 0; k < n; k++) { const e = endFrom(0, k, { caps: {}, locals: {} }); if (e !== Infinity) { out.push([k, e]); } }
    return out;
  }

  // A long synthetic stream (20% lw, 10% sw, 70% add; 3000 distinct words, registers from an LCG) and a capture query that is the
  // matcher's worst case (a loaded register never stored again hops through every later sw): the search must stop
  // at its time budget, pausing all along, however loaded the machine (the bound is relative to its own pauses).
  // The results are pushed as the promise settles (in JavaScriptCore, before the cases return).
  function budgetCases(S, ok) {
    if (typeof S.searchAsync !== 'function') { return; }
    const n = 300000;
    const words = new Uint32Array(n);
    let seed = 12345;
    const rnd = (m) => { seed = (Math.imul(seed, 1103515245) + 12345) >>> 0; return (seed >>> 8) % m; };
    // 3000 distinct words, as a real program has thousands (each is decoded once).
    const pool = new Uint32Array(3000);
    for (let i = 0; i < pool.length; i++) {
      const r = i % 10;
      const rd = 1 + rnd(31), rs1 = rnd(32), rs2 = rnd(32);
      pool[i] = r < 2 ? ((rnd(64) << 22) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03) >>> 0           // lw rd, imm(rs1)
        : r < 3 ? (((rnd(2)) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | (rnd(16) << 8) | 0x23) >>> 0 // sw rs2, imm(rs1)
          : ((rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33) >>> 0;                                         // add rd, rs1, rs2
    }
    for (let k = 0; k < n; k++) { words[k] = pool[rnd(pool.length)]; }
    const big = { count: n, xlen: 32, roles: ['insn', 'pc_rdata'], insn: (k) => (k >= 0 && k < n ? words[k] : null),
      pc: (k) => (k >= 0 && k < n ? 0x80000000 + 4 * k : null), value: () => null, widthOf: () => 32 };
    const q = '{lw} as L ##[1:$] {sw} && rs2 == L.rd';
    const budgetMs = 400;
    const sliceMs = 25;
    // The synchronous search takes budgetMs too (before the other, so the two don't share the clock).
    const t1 = Date.now();
    const sync = S.search(big, q, { budget: 1e12, budgetMs: 100 });
    const syncMs = Date.now() - t1;
    ok(sync.reason === 'time' && sync.incomplete, 'search: budgetMs stops it too (' + syncMs + ' ms, ' + sync.evaluated + ' evaluations)');
    // Started once the cases' synchronous work is done (a job), so the stretches between its pauses are its own.
    // A stretch: from the search resuming to its next pause (or its end).
    // Its results come after the cases return: a group of machineLateChecks, which the runner reads (and counts)
    // once the jobs ran.
    const group = ['FAIL searchAsync: the time-budget checks did not finish'];
    (root.machineLateChecks = root.machineLateChecks || []).push(group);
    const results = [];
    const lateOk = (cond, what) => { results.push((cond ? 'ok   ' : 'FAIL ') + what); return cond; };
    const timed = async (query) => {
      const gaps = [];
      let resumed = Date.now();
      const pause = () => { gaps.push(Date.now() - resumed); return Promise.resolve().then(() => { resumed = Date.now(); }); };
      const t0 = resumed;
      const r = await S.searchAsync(big, query, { budget: 1e12, budgetMs, sliceMs, pause });
      gaps.push(Date.now() - resumed);
      return { r, ms: Date.now() - t0, slowest: Math.max(...gaps) };
    };
    // A stretch is about sliceMs (a clock read late, the scheduler): 4x is slack; work that doesn't pause is far past it.
    const paused = (what, t) => lateOk(t.r.yields >= 3 && t.slowest <= 4 * sliceMs,
      what + ': it paused ' + t.r.yields + ' times, the longest stretch ' + t.slowest + ' ms (at most 4 x ' + sliceMs + ' ms)');
    Promise.resolve().then(async () => {
      const t = await timed(q);
      lateOk(!t.r.error && t.r.incomplete && t.r.reason === 'time' && t.r.next !== null,
        'searchAsync: a worst-case capture query on ' + n + ' commits stops at its time budget: ' + JSON.stringify([t.r.error, t.r.reason, t.r.next, t.r.matches && t.r.matches.length]));
      paused('searchAsync', t);
      lateOk(t.ms <= budgetMs + 3 * t.slowest, 'searchAsync: back in ' + t.ms + ' ms (budget ' + budgetMs + ' ms + 3x its longest stretch, ' + t.slowest + ' ms)');
      // Most of this one is the pass over every commit for its first step (a condition on pc, read per commit):
      // that pass pauses too.
      const p = await timed("(pc == 32'h7ffffffc || pc == 32'h7ffffff8 || pc == 32'h7ffffff4 || pc == 32'h7ffffff0) ##1 {sw}");
      lateOk(!p.r.error && !p.r.matches.length && (p.r.reason === null || p.r.reason === 'time'),
        'searchAsync: a first step read per commit: no matches, ' + JSON.stringify([p.r.error, p.r.reason, p.ms]));
      paused('searchAsync, its first step\'s pass', p);
      group.splice(0, group.length, ...results);
    }).catch((e) => { group.splice(0, group.length, 'FAIL searchAsync threw ' + e); });
  }

  function runSequenceCases(fixtures, h) {
    const out = [];
    const ok = (cond, what) => { out.push((cond ? 'ok   ' : 'FAIL ') + what); return cond; };
    const S = root.cmuxSequence;
    if (!ok(!!S && !!root.cmuxRiscvDisasm, 'sequence: cmux-sequence.js and the disassembler are loaded')) { return out; }
    const se = (m) => m.map((x) => x.ks.join('>')).join(' ');

    // The words are what their names say.
    const wrong = Object.entries(W).filter(([text, w]) => root.cmuxRiscvDisasm.disassembleRiscv(w, { aliases: false }) !== text
      && root.cmuxRiscvDisasm.disassembleRiscv(w) !== text);
    ok(!wrong.length, 'sequence: the hand-made words disassemble as named: ' + wrong.map(([t, w]) => t + ' = ' + root.cmuxRiscvDisasm.disassembleRiscv(w)).join('; '));
    // Decoded fields.
    const d = (w) => S.decode(w);
    const f = (x) => [x.cls, x.rd, x.rs1, x.rs2, x.imm].join(',');
    const C = Object.fromEntries(S.CLASSES.map((c, i) => [c, i + 1]));
    ok(f(d(W['lw a0,8(sp)'])) === [C.LOAD, 10, 2, null, 8].join(','), 'decode lw a0,8(sp): ' + f(d(W['lw a0,8(sp)'])));
    ok(f(d(W['sw a1,0(sp)'])) === [C.STORE, null, 2, 11, 0].join(','), 'decode sw a1,0(sp): ' + f(d(W['sw a1,0(sp)'])));
    ok(f(d(W['beq a0,a1,pc+8'])) === [C.BRANCH, null, 10, 11, 8].join(','), 'decode beq: ' + f(d(W['beq a0,a1,pc+8'])));
    ok(f(d(W['jal ra,pc+16'])) === [C.JUMP, 1, null, null, 16].join(','), 'decode jal: ' + f(d(W['jal ra,pc+16'])));
    ok(f(d(W['lw a0,4(a1)'])) === [C.LOAD, 10, 11, null, 4].join(',') && d(W['lw a0,4(a1)']).compressed, 'decode c.lw a0,4(a1): ' + f(d(W['lw a0,4(a1)'])));
    // The link register is written out (jal ra,X), as text atoms and the machine pane show it, for
    // jal/jalr and RVC c.jal/c.jalr, whose ra is implicit (objdump prints jal X).
    const has = (w, t) => d(w).texts.includes(t);
    ok(has(0x2001, 'jal ra pc+0') && has(0x2001, 'jal x1 pc+0') && has(0x9082, 'jalr ra ra') && has(0x000080e7, 'jalr ra ra') && has(0x008000ef, 'jal ra pc+8'),
      'jal/jalr texts name ra, RVC included: ' + JSON.stringify([d(0x2001).texts, d(0x9082).texts]));
    const M = root.cmuxMachineCore;
    ok(M.withLink('jal 0x80000010') === 'jal ra,0x80000010' && M.withLink('jalr a5') === 'jalr ra,a5' && M.withLink('jalr 8(a5)') === 'jalr ra,8(a5)'
      && M.withLink('jal x1,0x10') === 'jal x1,0x10' && M.withLink('j 0x10') === 'j 0x10' && M.withLink('jal 0x10', 'x1') === 'jal x1,0x10'
      && M.withLink('c.jal pc+0') === 'c.jal pc+0' && M.withLink(null) === null,
      'withLink writes the implicit ra of aliased jal/jalr only: ' + [M.withLink('jal 0x80000010'), M.withLink('jalr 8(a5)')].join(' | '));
    ok(d(W['csrw mtvec,a0']).cls === C.CSR && d(W['csrw mtvec,a0']).csr === 0x305 && d(W.mret).cls === C.SYSTEM, 'decode csrw mtvec and mret');

    // Parse errors.
    const err = (t) => { const p = S.parse(t); return p.error || null; };
    ok(err('') === 'empty' && err('{lw} ##1') === 'emptyStep' && err('{lw} ##[3:1] {add}') === 'badDelay' && err('{lw} ##x {add}') === 'badDelay',
      'parse: empty, empty step, bad delays: ' + [err(''), err('{lw} ##1'), err('{lw} ##[3:1] {add}'), err('{lw} ##x {add}')].join(','));
    ok(err('rs1 == L.rd') === 'unknownCapture' && err('/(/') === 'badRegex' && err('{lw} ##1 (cls == LOAD, = 3)') === 'badAssign',
      'parse: unknown capture, bad regex, bad local variable: ' + [err('rs1 == L.rd'), err('/(/'), err('{lw} ##1 (cls == LOAD, = 3)')].join(','));
    ok(S.parse('{lw} as L ##1 {add | sub} && (rs1 == L.rd || rs2 == L.rd)').steps.length === 2, 'parse: the load-use example');

    // ---- the hand-made stream ----
    const rows = [
      { w: W['lw a0,8(sp)'], mem: 0x1008 }, { w: W['add a1,a0,a2'] }, { w: W['addi a2,a2,1'] }, { w: W['lw a3,0(sp)'], mem: 0x1000 },
      { w: W['addi a2,a2,1'] }, { w: W['sw a1,0(sp)'], mem: 0x1000 }, { w: W['lw a3,0(sp)'], mem: 0x1000 }, { w: W['add a1,a0,a2'] },
      { w: W['jal ra,pc+16'] }, { w: W.nop }, { w: W['beq a0,a1,pc+8'], next: 8 }, { w: W['csrw mtvec,a0'] }, { w: W.nop },
      { w: W.mret }, { w: W.ret }, { w: W['lw a0,4(a1)'], mem: 0x2004 }, { w: W['add a1,a0,a2'] },
    ];
    const st = streamFrom(rows);
    const cases = [
      ['{lw} as L ##1 {add | sub} && (rs1 == L.rd || rs2 == L.rd)', '0>1 15>16', 'load-use, adjacent (and c.lw as lw)'],
      ['/jal\\s+(ra|x1)/ ##[1:$] {ret}', '8>14', 'a call, later a return'],
      ['{csrw mtvec} ##[1:20] {mret}', '11>13', 'csrw mtvec, mret within 20'],
      ['{csrw mtvec} ##[1:1] {mret}', '', 'not within 1'],
      ['(cls == STORE, a = mem_addr) ##[1:$] cls == LOAD && mem_addr == a', '5>6', 'a store, then a load of its address (local variable)'],
      ['{branch} && taken', '10', 'a taken branch (class word, taken from pc_wdata)'],
      ['{addi} ##1 {lw} ##[1:3] {addi}', '2>3>4', 'bounded gaps'],
      ['{lw} ##0 rd == 13', '3>3 6>6', '##0 is the same commit'],
      ['cls == COMPRESSED', '15', 'cls == COMPRESSED'],
      ['{lw} ##[1:$] {addi} ##1 {sw}', '0>4>5 3>4>5', 'an unbounded gap before a bounded one keeps every thread'],
      ['{lw a3}', '3 6', 'a literal with an operand is a token prefix'],
      ['{lw a3,0(sp)}', '3 6', 'commas and spaces are the same'],
      ['/lw\\s+x13/', '3 6', 'a regex matches the x-number text too'],
      ['imm < 0 || imm > 15', '8', 'imm as a signed field: jal +16'],
      ['pc == 32\'h80000004', '1', 'pc from the stream'],
    ];
    for (const [q, want, what] of cases) {
      const r = S.search(st, q);
      ok(!r.error && se(r.matches) === want, 'sequence: ' + what + ': ' + q + ' -> ' + (r.error ? 'error ' + r.error : se(r.matches)));
    }
    const lim = S.search(st, '{lw}', { limit: 2 });
    ok(lim.matches.length === 2 && lim.incomplete && lim.next === 6, 'limit: 2 matches, incomplete, next at 6: ' + JSON.stringify([lim.matches.length, lim.incomplete, lim.next]));
    const from = S.search(st, '{lw}', { from: 4 });
    ok(se(from.matches) === '6 15', 'from: starts at or after 4: ' + se(from.matches));
    const bad = S.search(st, 'nosuch == 1');
    ok(bad.error === 'unknownName', 'an unknown name is an error: ' + JSON.stringify(bad));
    ok(lim.reason === 'limit', 'limit: the reason says so: ' + lim.reason);
    ok(S.search(st, '{lw}').reason === null, 'complete: no reason');
    const few = S.search(st, '{lw} ##[1:$] {sw}', { budget: 3 });
    ok(few.incomplete && few.reason === 'budget' && few.next !== null && few.matches.every((m) => m.start < few.next),
      'budget: stopped, the reason, and only starts before next reported: ' + JSON.stringify([few.reason, few.next, se(few.matches)]));
    ok(typeof S.searchAsync === 'function', 'searchAsync exists');
    budgetCases(S, ok);

    // ---- against brute force on random streams ----
    const pool = Object.values(W);
    let x = 12345;
    const rnd = (m) => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x % m; };
    const queries = [
      '{lw} as L ##1 {add | sub} && (rs1 == L.rd || rs2 == L.rd)', '{lw} ##[1:$] {addi} ##1 {sw}', '{addi} ##[2:5] {lw} as L ##[1:$] rs1 == L.rd || rs2 == L.rd',
      '(cls == STORE, a = mem_addr) ##[1:$] cls == LOAD && mem_addr == a', '{jal} ##[1:$] {ret} ##[0:2] {lw}', '{branch} ##[1:4] {branch} ##[1:4] {branch}',
      '{lw} as A ##[1:6] {lw} as B ##[1:$] rs1 == A.rd && rs2 == B.rd', '{jal} ##[1:$] pc == 32\'h80000010 ##[1:3] {lw}',
      '{lw} ##[1:$] mem_addr == 32\'h1004 && cls == STORE',
    ];
    let compared = 0, differ = 0, firstDiffer = null;
    for (let trial = 0; trial < 6; trial++) {
      const rs = Array.from({ length: 160 }, () => ({ w: pool[rnd(pool.length)], mem: 0x1000 + 4 * rnd(3) }));
      const sr = streamFrom(rs);
      for (const q of queries) {
        const fast = S.search(sr, q, { maxThreads: 1e6 }).matches.map((m) => m.start + '>' + m.end).join(' ');
        const slow = bruteForce(sr, q).map((m) => m[0] + '>' + m[1]).join(' ');
        compared++;
        if (fast !== slow) { differ++; firstDiffer = firstDiffer || q + ' (trial ' + trial + '): ' + fast + ' vs ' + slow; }
      }
    }
    ok(differ === 0, 'sequence search equals brute force: ' + compared + ' query × stream pairs: ' + (firstDiffer || 'all equal'));

    // ---- Ibex: the RVFI stream against Spike's log of the same run ----
    const dir = fixtures + '/ibex';
    const vcd = root.readFile(dir + '/ibex.vcd');
    const log = root.readFile(dir + '/spike.log');
    if (ok(!!vcd && !!log, 'sequence: the Ibex fixture is there')) {
      const signals = h.readVcd(vcd);
      const edges = h.posedges(signals.find((s) => /^(clk|clock|clk_i)$/.test(s.path[s.path.length - 1])));
      const { index } = h.load(signals, edges, {});
      const spike = h.spikeReplay(log);
      const n = Math.min(index.count, spike.length);
      const rvfi = S.streamOf(index);
      const oracle = { count: n, xlen: 32, roles: [], insn: (k) => (k < n ? spike[k].insn : null), pc: (k) => (k < n ? spike[k].pc : null), value: () => null };
      const cut = Object.assign({}, rvfi, { count: n });
      for (const q of ['{lw} as L ##1 rs1 == L.rd || rs2 == L.rd', '/jal\\s+ra/ ##[1:$] {ret}', '{branch} ##1 {branch}', 'cls == STORE ##[1:3] cls == LOAD',
        '{beq | bne | blt | bge | bltu | bgeu | beqz | bnez} ##[1:$] pc == 32\'h80000080']) {
        const t0 = root.nowMs ? root.nowMs() : 0;
        const a = S.search(cut, q);
        const ms = (root.nowMs ? root.nowMs() : 0) - t0;
        const b = S.search(oracle, q);
        ok(!a.error && se(a.matches) === se(b.matches) && (a.matches.length > 0 || /80000080/.test(q)),
          'Ibex: ' + q + ': ' + a.matches.length + ' matches, as over Spike\'s log (' + ms.toFixed(1) + ' ms, ' + a.evaluated + ' steps)');
      }
    }
    return out;
  }

  root.runSequenceCases = runSequenceCases;
})(typeof window !== 'undefined' ? window : globalThis);
