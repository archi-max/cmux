#!/usr/bin/env node
// Differential fuzz for cmux-expr.js against a SystemVerilog simulator (the referee; VCS on the remote host).
//
//   node fuzz.js gen <dir> <seed> <count>   writes <dir>/fuzz.sv and <dir>/cases.json
//   node fuzz.js repro <dir> <i,j,...>      prints a .sv with only those cases
//   node fuzz.js alone <dir> <out-dir>      after check: <out-dir>/case-<i>.sv for each mismatch
//   node fuzz.js check <dir> <sim-output>   compares cmux-expr with the simulator's lines
//                                           ("<index> <bits>"), prints the mismatches, and writes
//                                           <dir>/mismatches.json (fixtures for run.sh expr)
//     FUZZ_SIM='<command>': check then re-runs each mismatch alone (in <dir>/alone/case-<i>/, the
//     command run there with {sv} replaced by case.sv, its stdout read like <sim-output>) and
//     reports only those that persist; the batch-only ones go to <dir>/batch-only.json. E.g.
//     FUZZ_SIM='ssh host-01 "cd /tmp/x && cat > c.sv && vcs -sverilog -full64 -q c.sv -o simv >/dev/null && ./simv" < {sv}'
//
// The generator covers the evaluator's operator subset (unsigned) over random 4-state signals of
// widths 1-130 with descending, offset and ascending ranges, sized and unsized literals (x/z
// leading too), selects, concatenation and replication. Each case is `$display("%0d %b", i, e)`,
// so both sides print the expression at its self-determined width.
//
// Count a mismatch only after it also mismatches alone (FUZZ_SIM does that in check; `alone`
// writes one .sv per mismatch to compile by hand): VCS W-2024.09 printed a different value for about 1 case in 3000 in a
// 4000-case file than for the same case compiled by itself (Icarus and the case alone agreed).
// It is not the generator: every case is a side-effect-free $display over the same 10 signals,
// which nothing assigns, and the effect stays with cases split into initial blocks of 100, with
// the signals assigned at time 0 instead of initialized, and at -O0; it needs a particular set of
// unrelated other cases in the module (no pair or count of them alone). VCS also gives 0 for some `a == b + c` with unknown bits in b, where the LRM,
// slang and Icarus give x (b + c is all x); cmux-expr keeps the LRM's x.
'use strict';
const fs = require('fs');
const path = require('path');

// FUZZ_EXPR: another cmux-expr.js to check (an older one, to see what a change fixed).
const EXPR = process.env.FUZZ_EXPR || path.join(__dirname, '../../../Resources/vaporview/cmux-expr.js');
// cmux-expr.js puts cmuxExpr on window or globalThis.
// eslint-disable-next-line no-new-func
new Function(fs.readFileSync(EXPR, 'utf8'))();
const E = globalThis.cmuxExpr;

function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function generate(seed, count) {
  const rnd = prng(seed);
  const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
  const pick = (list) => list[int(0, list.length - 1)];
  const chance = (p) => rnd() < p;
  const bits = (w, unknown) => Array.from({ length: w }, () => (unknown && chance(0.15) ? pick(['x', 'z']) : pick(['0', '1']))).join('');

  // Signals: a few small, a few wide; some all-known.
  const signals = [];
  for (let i = 0; i < 10; i++) {
    const width = i < 4 ? int(1, 8) : (i < 8 ? int(1, 70) : int(64, 130));
    const kind = pick(['down', 'down', 'down', 'offset', 'up']);
    const lsb = kind === 'offset' ? int(1, 6) : 0;
    const msb = kind === 'up' ? 0 : lsb + width - 1;
    const range = kind === 'up' ? { msb: 0, lsb: width - 1 } : { msb, lsb };
    signals.push({ name: 's' + i, width, msb: range.msb, lsb: range.lsb, value: bits(width, chance(0.6)) });
  }

  function literal() {
    const r = rnd();
    if (r < 0.25) { return String(int(0, 300)); }
    if (r < 0.35) { return "'" + pick(['', '', 's']) + pick(['h', 'b', 'd', 'o']) + pick(['x', 'z', '1x', '0', 'f', '7']); }
    if (r < 0.4) { return "'" + pick(['0', '1', 'x', 'z']); }
    if (r < 0.5) { return pick(['-', '- ', '']) + String(int(0, 40)); }
    const width = int(1, chance(0.8) ? 16 : 100);
    // Signed literals ('s) exercise sign extension, signed comparison and >>>.
    const sign = chance(0.3) ? 's' : '';
    const base = pick(['b', 'h', 'd']);
    if (base === 'b') { return width + "'" + sign + "b" + bits(width, true); }
    if (base === 'd') { return width + "'" + sign + "d" + (chance(0.1) ? pick(['x', 'z']) : String(int(0, Math.min(2 ** Math.min(width, 30) - 1, 99999)))); }
    const digits = Math.ceil(width / 4);
    let text = '';
    for (let k = 0; k < digits; k++) { text += chance(0.1) ? pick(['x', 'z']) : '0123456789abcdef'[int(0, k === 0 ? (2 ** (width - 4 * (digits - 1))) - 1 : 15)]; }
    return width + "'" + sign + "h" + text;
  }

  function name() { return pick(signals); }

  function select() {
    const s = name();
    const lo = Math.min(s.msb, s.lsb), hi = Math.max(s.msb, s.lsb);
    const idx = () => int(lo - 2, hi + 2);
    const r = rnd();
    if (r < 0.4) { return s.name + '[' + idx() + ']'; }
    if (r < 0.7) {
      const a = int(lo, hi), b = int(lo, hi);
      // A part-select keeps the declared direction.
      const [m, l] = s.msb >= s.lsb ? [Math.max(a, b), Math.min(a, b)] : [Math.min(a, b), Math.max(a, b)];
      return s.name + '[' + m + ':' + l + ']';
    }
    const w = int(1, Math.max(1, Math.min(8, hi - lo + 1)));
    return s.name + '[' + idx() + (chance(0.5) ? ' +: ' : ' -: ') + w + ']';
  }

  // Unsized literals are not allowed in a concatenation, bare or in parentheses (cmux-expr rejects
  // them, as slang does; VCS takes them as 32 bits).
  function sized(depth) {
    const r = rnd();
    if (r < 0.4) { return name().name; }
    if (r < 0.6) { return select(); }
    if (r < 0.8) { let l; do { l = literal(); } while (!/^\d+'/.test(l)); return l; }
    let e; do { e = expr(depth + 1); } while (/^\(*(\d+|'[sS]?[bBoOdDhH]\w+)\)*$/.test(e));
    return '(' + e + ')';
  }

  const BIN = ['+', '-', '*', '&', '|', '^', '~^', '^~', '==', '!=', '===', '!==', '<', '<=', '>', '>=', '<<', '>>', '<<<', '>>>', '&&', '||'];
  const UN = ['~', '-', '+', '!', '&', '|', '^', '~&', '~|', '~^'];

  function expr(depth) {
    if (depth > 3 || chance(0.25)) {
      const r = rnd();
      if (r < 0.45) { return name().name; }
      if (r < 0.7) { return select(); }
      return literal();
    }
    const r = rnd();
    let text;
    if (r < 0.5) {
      const op = pick(BIN);
      // Keep shift amounts and multiplications small enough to read.
      const right = op.includes('<') && op.length > 1 && op !== '<=' || op.includes('>') && op.length > 1 && op !== '>='
        ? (chance(0.7) ? String(int(0, 140)) : expr(depth + 1)) : expr(depth + 1);
      text = expr(depth + 1) + ' ' + op + ' ' + right;
    } else if (r < 0.65) {
      text = pick(UN) + ' ' + (chance(0.5) ? sized(depth) : '(' + expr(depth + 1) + ')');
    } else if (r < 0.75) {
      text = expr(depth + 1) + ' ? ' + expr(depth + 1) + ' : ' + expr(depth + 1);
    } else if (r < 0.9) {
      const n = int(1, 3);
      text = '{' + Array.from({ length: n }, () => sized(depth)).join(', ') + '}';
    } else {
      text = '{' + int(1, 3) + '{' + sized(depth) + '}}';
    }
    return chance(0.5) ? '(' + text + ')' : text;
  }

  const cases = [];
  while (cases.length < count) {
    const text = expr(0);
    const parsed = E.parse(text);
    // The generator stays inside the supported subset; anything refused is a generator miss.
    if (parsed.error) { continue; }
    cases.push(text);
  }
  return { seed, signals, cases };
}

function svOf(batch, only) {
  const decl = batch.signals.map((s) => `  logic [${s.msb}:${s.lsb}] ${s.name} = ${s.width}'b${s.value};`).join('\n');
  const shows = batch.cases.map((c, i) => (only && !only.includes(i) ? null : `    $display("%0d %b", ${i}, ${c});`)).filter(Boolean).join('\n');
  return `// cmux-expr differential fuzz, seed ${batch.seed}: generated test input.\nmodule fuzz;\n${decl}\n  initial begin\n    #1;\n${shows}\n    $finish;\n  end\nendmodule\n`;
}

function evaluateCase(batch, text) {
  const byName = new Map(batch.signals.map((s) => [s.name, s]));
  const env = (p) => {
    const s = p.length === 1 ? byName.get(p[0]) : null;
    return s ? { width: s.width, msb: s.msb, lsb: s.lsb, value: E.fromBits(s.value, s.width) } : null;
  };
  const parsed = E.parse(text);
  if (parsed.error) { return 'error:' + parsed.error; }
  const r = E.evaluate(parsed.ast, env);
  if (r.error) { return 'error:' + r.error; }
  return E.toBits(r.value);
}

const [, , command, dir, a, b] = process.argv;
if (command === 'gen') {
  const batch = generate(Number(a), Number(b));
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'cases.json'), JSON.stringify(batch));
  fs.writeFileSync(path.join(dir, 'fuzz.sv'), svOf(batch));
  console.log(`seed ${batch.seed}: ${batch.cases.length} cases`);
} else if (command === 'repro') {
  // Only the listed cases (comma-separated indices), to see one alone.
  const batch = JSON.parse(fs.readFileSync(path.join(dir, 'cases.json'), 'utf8'));
  process.stdout.write(svOf(batch, a.split(',').map(Number)));
} else if (command === 'alone') {
  const batch = JSON.parse(fs.readFileSync(path.join(dir, 'cases.json'), 'utf8'));
  const mismatches = JSON.parse(fs.readFileSync(path.join(dir, 'mismatches.json'), 'utf8'));
  fs.mkdirSync(a, { recursive: true });
  for (const m of mismatches) { fs.writeFileSync(path.join(a, `case-${m.i}.sv`), svOf(batch, [m.i])); }
  console.log(`${mismatches.length} files in ${a}; compile each alone, then check ${dir} <their output> with FUZZ_PRESENT_ONLY=1`);
} else if (command === 'check') {
  const batch = JSON.parse(fs.readFileSync(path.join(dir, 'cases.json'), 'utf8'));
  const sim = new Map();
  for (const line of fs.readFileSync(a, 'utf8').split('\n')) {
    const m = /^(\d+) ([01xzXZ]+)$/.exec(line.trim());
    if (m) { sim.set(Number(m[1]), m[2].toLowerCase()); }
  }
  const mismatches = [];
  batch.cases.forEach((text, i) => {
    const want = sim.get(i);
    // FUZZ_PRESENT_ONLY: a repro run prints only some cases.
    if (want === undefined && process.env.FUZZ_PRESENT_ONLY) { return; }
    const got = evaluateCase(batch, text);
    if (want === undefined || got !== want) { mismatches.push({ i, text, want: want === undefined ? null : want, got }); }
  });
  const used = (text) => batch.signals.filter((s) => new RegExp('\\b' + s.name + '\\b').test(text));
  let kept = mismatches;
  if (process.env.FUZZ_SIM && mismatches.length) {
    // Each mismatch compiled by itself: the simulator's batch-only results are not ours.
    const { execSync } = require('child_process');
    const batchOnly = [];
    kept = [];
    for (const m of mismatches) {
      const caseDir = path.join(dir, 'alone', `case-${m.i}`);
      fs.mkdirSync(caseDir, { recursive: true });
      const sv = path.join(caseDir, 'case.sv');
      fs.writeFileSync(sv, svOf(batch, [m.i]));
      let output = '';
      try {
        output = execSync(process.env.FUZZ_SIM.split('{sv}').join(JSON.stringify(sv)), { cwd: caseDir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'], timeout: 600000 });
      } catch (error) { output = String(error.stdout || ''); }
      const line = output.split('\n').map((l) => /^(\d+) ([01xzXZ]+)$/.exec(l.trim())).find((r) => r && Number(r[1]) === m.i);
      const alone = line ? line[2].toLowerCase() : null;
      if (alone !== null && alone === m.got) { batchOnly.push(Object.assign({ alone }, m)); } else { kept.push(Object.assign(m, { alone })); }
    }
    fs.writeFileSync(path.join(dir, 'batch-only.json'), JSON.stringify(batchOnly, null, 1));
    console.log(`${batchOnly.length} of ${mismatches.length} mismatches agree with cmux-expr when compiled alone (the simulator's batch-only results: batch-only.json)`);
  }
  const out = kept.map((m) => Object.assign(m, { signals: used(m.text) }));
  fs.writeFileSync(path.join(dir, 'mismatches.json'), JSON.stringify(out, null, 1));
  console.log(`seed ${batch.seed}: ${batch.cases.length} cases, ${sim.size} simulator lines, ${out.length} mismatches${process.env.FUZZ_SIM ? ' (persisting alone)' : ''}`);
  for (const m of out.slice(0, Number(b) || 20)) { console.log(`#${m.i} ${m.text}\n   sim ${m.want}\n   got ${m.got}`); }
} else {
  console.log('usage: fuzz.js gen <dir> <seed> <count> | repro <dir> <i,...> | check <dir> <sim-output> [show] | alone <dir> <out-dir>');
  process.exit(2);
}
