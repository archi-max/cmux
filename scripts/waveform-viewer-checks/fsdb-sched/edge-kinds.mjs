// SystemVerilog edge kinds of the helper's `edge` op on a real FSDB (by hand, on a host with
// Verdi; not part of run.sh):
//   node edge-kinds.mjs <install>/cmux-helper-v2.sh [scratch dir]
// Writes a small VCD and converts it with Verdi's vcd2fsdb ($VERDI_HOME/bin, or FSDB_VCD2FSDB).
// One 1-bit signal steps through every 0/1/x/z transition; a 4-bit one checks the width rule.
// Every answer is compared with a reference computed here from the same list of changes:
//   posedge  0->1, 0->x, 0->z, x->1, z->1
//   negedge  1->0, 1->x, 1->z, x->0, z->0
//   edge     either (x<->z is not an edge)
// The dump's first value is never an edge. any / rise / fall keep their meaning (any change;
// new value '1' / '0'). Unknown kinds, and the SV kinds on a signal wider than 1 bit, are
// errors (the page then walks its own data). Exit 1 on any mismatch.
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const [launcher, dirArg] = process.argv.slice(2);
if (!launcher) { console.error('usage: node edge-kinds.mjs <launcher> [scratch dir]'); process.exit(2); }
const dir = dirArg || fs.mkdtempSync(path.join(os.tmpdir(), 'edge-kinds-'));
fs.mkdirSync(dir, { recursive: true });

// e: one value per 10 ns; v: a 4-bit row
const E = [[0, 'x'], [10, '0'], [20, '1'], [30, 'x'], [40, 'z'], [50, '1'], [60, '0'], [70, 'z'], [80, '0'], [90, 'x'], [100, '1'], [110, 'z'], [120, 'x'], [130, '0'], [140, '1']];
const V = [[0, '0000'], [10, '0001'], [20, '0000'], [30, 'xxxx']];
const END = 200;
const vcd = ['$timescale 1ns $end', '$scope module top $end', '$var wire 1 ! e $end', '$var wire 4 " v [3:0] $end', '$upscope $end', '$enddefinitions $end'];
const times = [...new Set([...E.map((x) => x[0]), ...V.map((x) => x[0]), END])].sort((a, b) => a - b);
for (const t of times) {
  vcd.push('#' + t);
  const e = E.find((x) => x[0] === t), v = V.find((x) => x[0] === t);
  if (e) { vcd.push(e[1] + '!'); }
  if (v) { vcd.push('b' + v[1] + ' "'); }
}
fs.writeFileSync(path.join(dir, 'e.vcd'), vcd.join('\n') + '\n');
const tool = process.env.FSDB_VCD2FSDB || path.join(process.env.VERDI_HOME || '', 'bin', 'vcd2fsdb');
const file = path.join(dir, 'e.fsdb');
fs.rmSync(file, { force: true });
execFileSync(tool, [path.join(dir, 'e.vcd'), '-o', file], { cwd: dir, stdio: 'ignore' });

const POS = new Set(['01', '0x', '0z', 'x1', 'z1']), NEG = new Set(['10', '1x', '1z', 'x0', 'z0']);
// (a change is a new value; before the first one every row is 'x', so an initial 'x' is none)
const is = (kind, k) => {
  const nv = E[k][1], pv = k ? E[k - 1][1] : 'x';
  if (nv === pv) { return false; }
  if (kind === 'any') { return true; }
  if (kind === 'rise') { return nv === '1'; }
  if (kind === 'fall') { return nv === '0'; }
  if (k === 0) { return false; }  // (the dump's first value is no edge)
  const tr = pv + nv;
  return kind === 'posedge' ? POS.has(tr) : kind === 'negedge' ? NEG.has(tr) : POS.has(tr) || NEG.has(tr);
};
const want = (kind, t, dir) => {
  if (dir > 0) { for (let k = 0; k < E.length; k++) { if (E[k][0] > t && is(kind, k)) { return E[k][0]; } } return null; }
  for (let k = E.length - 1; k >= 0; k--) { if (E[k][0] < t && is(kind, k)) { return E[k][0]; } }
  return null;
};

const p = spawn('bash', [launcher, '--workers', '1'], { stdio: ['pipe', 'pipe', 'ignore'] });
let buf = '', nid = 1, ready;
const pend = new Map(), readyP = new Promise((r) => { ready = r; });
p.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const l = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!l.trim()) { continue; }
    const m = JSON.parse(l);
    if (m.ready) { ready(m); continue; }
    const h = pend.get(m.id); if (h && !m.partial) { pend.delete(m.id); h(m); }
  }
});
const send = (cmd, a = {}) => new Promise((res) => { const id = nid++; pend.set(id, res); p.stdin.write(JSON.stringify({ id, cmd, ...a }) + '\n'); });
await readyP;
const o = await send('open', { file });
if (o.error) { console.error('open:', o.error); process.exit(2); }
const top = o.result.top.find((s) => s.name === 'top');
const c = await send('children', { scopeOffsetIdx: top.scopeOffsetIdx, scopePath: 'top' });
const id = (nm) => c.result.vars.find((v) => v.name === nm || v.name.startsWith(nm + '[')).signalId;
const e = id('e'), v = id('v');

let fails = 0, n = 0;
const check = (ok, what) => { n++; if (!ok) { fails++; console.log('FAIL ' + what); } else if (process.env.VERBOSE) { console.log('ok   ' + what); } };
for (const kind of ['posedge', 'negedge', 'edge', 'any', 'rise', 'fall']) {
  for (const dir of [1, -1]) {
    for (const t of [0, 5, 10, 15, 20, 35, 40, 45, 50, 75, 115, 120, 125, 135, 140, 145, END]) {
      const r = await send('edge', { signalId: e, t, dir, kind });
      const w = want(kind, t, dir);
      check(!r.error && r.result.t === w, `${kind} dir ${dir} from ${t}: ${r.error || JSON.stringify(r.result.t)}, want ${w}`);
    }
  }
}
for (const kind of ['posedge', 'negedge', 'edge']) {
  const r = await send('edge', { signalId: v, t: 0, dir: 1, kind });
  check(!!r.error, `${kind} of a 4-bit row is an error: ${r.error || JSON.stringify(r.result)}`);
}
for (const kind of ['bothedges', 'Posedge']) {
  const r = await send('edge', { signalId: e, t: 0, dir: 1, kind });
  check(!!r.error, `unknown kind ${JSON.stringify(kind)} is an error: ${r.error || JSON.stringify(r.result)}`);
}
const r0 = await send('edge', { signalId: e, t: 15, dir: 1 });
check(!r0.error && r0.result.t === 20, `no kind is any: ${r0.error || r0.result.t}`);
p.stdin.end();
console.log(fails ? `EDGE KINDS FAILED: ${fails} of ${n}` : `EDGE KINDS PASSED: ${n}`);
setTimeout(() => process.exit(fails ? 1 : 0), 300);
