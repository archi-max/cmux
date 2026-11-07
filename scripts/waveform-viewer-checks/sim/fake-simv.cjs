#!/usr/bin/env node
// A stand-in simulator for worker-unit.cjs: what fsdb-helper-v2/simctl/sim-worker.js spawns as <simv>, with
// the VPI library's side played here. UCLI on stdin/stdout ("ucli% " prompts; `run` starts the library side;
// started without -ucli, as `sim-worker.js --no-ucli` does: no prompts, and the library side starts at once),
// the library's line protocol on fd 3 (requests in) and fd 4 (replies out), as simctl_vpi.c speaks it:
//   T/G/W/X/I/N/O/E/V answered at once, also during a run (the library's poll points); R/U run for FAKE_RUN_MS
//   (default 1500) or until an S; F/D/L ... Y (writes), P, Q, H (describe), A (apply) and anything else wait for
//   the run's end, in order.
// Toy design: time unit 1; tb.cnt (8 bits) = floor(t / 10) mod 256. Every library line received is appended to
// FAKE_SIMV_LOG (one per line), so a test can see what reached "the library".
'use strict';
const fs = require('node:fs');
const LOG = process.env.FAKE_SIMV_LOG;
const RUN_MS = Number(process.env.FAKE_RUN_MS) || 1500;
const APPLY_SYMBOLS = (process.env.SIMCTL_APPLY_SYMBOLS || '').split(',').filter(Boolean);
const lout = fs.createWriteStream(null, { fd: 4 });
const send = (o) => lout.write(JSON.stringify(o) + '\n');
let t = 0, run = null, deferred = [], started = false, writes = [];
const cnt = () => (Math.floor(t / 10) & 255).toString(2).padStart(8, '0');
const watches = []; // wid -> name
let queued = 0;     // pushed transactions (B)
function endRun(why, stopId) {
  const r = run; if (!r) return;
  clearTimeout(r.timer); run = null;
  if (why === 'done') t = r.end; else t = Math.min(r.end, r.start + Math.max(1, Math.floor((r.end - r.start) * (Date.now() - r.wall) / RUN_MS)));
  send({ id: r.id, t, stopped: why });
  if (stopId !== undefined) send({ id: stopId, t });
  const d = deferred; deferred = [];
  for (const l of d) line(l);
}
function quick(op, id, a) {
  switch (op) {
    case 'T': send({ id, t }); return true;
    case 'O': send({ id, poll: Number(a[1]) || 1 }); return true;
    case 'G': send({ id, t, values: a.slice(0).map((n) => (n === 'tb.cnt' ? cnt() : n === 'tb.u_in.push_req' ? '0' : null)) }); return true;
    case 'W': send({ id, t, watch: a.map((n) => (n === 'tb.cnt' ? { wid: watches.push(n) - 1, width: 8 } : null)) }); return true;
    case 'X': send({ id, t, unwatched: a.length }); return true;
    case 'I': send({ id, t, watches: [] }); return true;
    case 'N': send({ id, vars: [], truncated: false }); return true;
    case 'E': send({ id, t }); return true;
    // fork-save: the reply at once (the fork), the save's end as a `saved` event a little later
    case 'V': { const pid = 90000 + id; send({ id, t, pid, forkMs: 1.5, file: a[0] });
      // a name with "nofile" in it: the child says 0 but writes nothing (the worker must not trust the status)
      // "exitsoon": the simulation ends (as on $finish) before the save's end is reported
      if (/exitsoon/.test(a[0])) { setTimeout(() => process.kill(process.pid, "SIGTERM"), 50); return true; }   // (process.exit waits on the fd 3 read here)
      // "latetimeout": the image is there and the status 0, but the deadline also fired (one outcome must win)
      if (/latetimeout/.test(a[0])) { setTimeout(() => { fs.writeFileSync(a[0], 'fake save'); send({ ev: 'saved', pid, file: a[0], t, status: 0, timeout: true }); }, 200); return true; }
      // "warnfile": the child could not reopen one of the design's $fopen files (it says so in <file>.log)
      if (/warnfile/.test(a[0])) { try { fs.writeFileSync(`${a[0]}.log`, 'simctl-forksave: warning: /work/out.txt (fd 9) could not be reopened: a run restored from this save writes nothing to it\n'); } catch { /* bad path */ } }
      setTimeout(() => { try { if (!/nofile/.test(a[0])) fs.writeFileSync(a[0], 'fake save'); } catch { /* bad path */ } send({ ev: 'saved', pid, file: a[0], t, status: 0 }); }, 200); return true; }
    default: return false;
  }
}
function line(l) {
  const tok = l.split(' '); const op = tok[0], id = Number(tok[1]), a = tok.slice(2);
  if (op === 'S') { if (run) endRun('stop', id); else send({ id, t, idle: true }); return; }
  if (op === 'K') return;
  if (quick(op, id, op === 'O' ? a : a)) return;
  if (run) { deferred.push(l); return; }
  switch (op) {
    case 'R': case 'U': {
      const dt = Number(a[0]);
      if (!(dt > 0)) { send({ id, t, stopped: 'done' }); return; }
      run = { id, start: t, end: t + dt, wall: Date.now(), timer: setTimeout(() => endRun('done'), RUN_MS) };
      return;
    }
    case 'F': case 'D': case 'L': writes.push(id); return;
    // FAKE_NOACCESS: a build without write access (the library reads each write back and says so)
    case 'Y': t += 1; for (const w of writes) send(process.env.FAKE_NOACCESS ? { id: w, error: 'no write access to tb.cnt (rebuild with -debug_access+w)', needsRebuild: true } : { id: w, t, value: cnt() }); writes = []; return;
    // FAKE_P_REFUSE: the hold can't be written, so the library refuses to park (no stop, so no prompt)
    case 'P': if (process.env.FAKE_P_REFUSE) { send({ id, error: 'the testbench hold (st) has no write access: rebuild with -debug_access+w' }); return; }
      send({ id, t, parked: true }); process.stdout.write('ucli% '); return;
    // the reusable testbench: one simctl_cfg and one simctl_port in the toy design (simctl_describe.c's reply)
    case 'H': send({ id, t, cfg: [{ path: 'tb.u_cfg', scenarios: 'smoke:plain adds' }], ports: [{ path: 'tb.u_in', name: 'in', kind: 'vr', width: 16, fields: 'hi[15:8] lo[7:0]' }], memories: [], memoriesTruncated: false }); return;
    // apply: the hook ran and the design settled (simctl_apply.c's reply)
    case 'A': {   // apply: like the library, only registered entry points (its own three + SIMCTL_APPLY_SYMBOLS)
      const reg = ['vcs_restore_apply_plan', 'vcs_restore_api_version', 'vcs_restore_last_error', ...APPLY_SYMBOLS];
      const bad = [a[1], a[4], a[6]].find((n, i) => !(i && n === '-') && !reg.includes(n));
      if (bad) { send({ id, error: `apply: ${bad} is not a registered apply entry point: simctl calls only vcs_restore_apply_plan, vcs_restore_api_version, vcs_restore_last_error and the names in the run's cmux-replay.json applySymbols` }); return; }
      send({ id, t, rc: 0, lastError: '', settled: true, held: false }); return;
    }
    // push: transactions queued for a port (simctl_push.c's reply); nothing pulls them in the toy design
    case 'B': { const n = Number(a[1]); queued += n; send({ id, t, port: a[0], queued, pulled: 0 }); return; }
    case 'Q': send({ id, t, quit: true }); setTimeout(() => process.exit(0), 20); return;
    default: send({ id, error: 'unknown op' });
  }
}
let ibuf = '';
fs.createReadStream(null, { fd: 3 }).on('data', (d) => {
  ibuf += d.toString('latin1'); let k;
  while ((k = ibuf.indexOf('\n')) >= 0) { const l = ibuf.slice(0, k); ibuf = ibuf.slice(k + 1); if (LOG) fs.appendFileSync(LOG, l + '\n'); if (l) line(l); }
}).on('end', () => process.exit(0));
const UCLI = process.argv.includes('-ucli');
if (UCLI) process.stdout.write('ucli% ');
else { started = true; send({ ev: 'ready', t, precision: -12 }); }
if (UCLI) require('node:readline').createInterface({ input: process.stdin }).on('line', (l) => {
  const c = l.trim();
  if (c === 'run') { if (!started) { started = true; send({ ev: 'ready', t, precision: -12 }); } return; }
  if (c === 'quit') process.exit(0);
  if (c.startsWith('checkpoint -add')) { if (!process.env.FAKE_UCLI_STUCK) process.stdout.write('1\nucli% '); return; }   // STUCK: no prompt ever
  // a file save the simulator refuses (as VCS does at a $stop, which a held serve point is): names with "refuse"
  if (c.startsWith('save ') && /refuse/.test(c)) { process.stdout.write("Error-[UCLI-SAVE-STOP] Save at $stop\n  Cannot save the state when the simulation is stopped at the $stop() task.\nucli% "); return; }
  process.stdout.write('ucli% ');
});
