#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Part of cmux's FSDB helper v2 (live simulation; sim.js starts it).
// simctl worker: launches one simulation under our VPI library and serves it as JSON lines on stdio.
//
//   node worker.js --simv <path> --lib <libsimctl.so> --scratch <dir> [--cwd <run folder>] [--run <name>] [--clock <sig>] [--period <t>]
//                  [--rss-mb 2048] [--min-avail-mb 5120] [--poll-cycles 100] [--vmem-mb 4096] [--ucli-timeout-ms 120000]
//                  [--no-ucli2proc | --no-ucli] [--forksave-timeout-ms 120000]
//                  -- <simulator run arguments>
//
// The simv must have been elaborated with `-load <libsimctl_stub.so>:simctl_register` (a run-time simv -load
// does not call VPI registration routines). The stub loads <lib> from SIMCTL_LIB, set here.
// The simulation runs as `<simv> -ucli -ucli2Proc <args>` in <scratch>/<run>, a private copy of the original
// run's folder (--cwd [--copy-mb 512]; see "run directory" below). Its command line is driven only for
// checkpoint/restore. With --no-ucli it runs as `<simv> <args>`, with no command line: checkpoint/restore/save/
// restoreFile are refused, and forksave (which needs it that way) is allowed.
//
// Requests (stdin, one JSON object per line) -> {id, result, ms} or {id, error}; events are {id: 0, event}.
//   run {cycles | time}                         -> {t, stopped: done|until|stop|finish|serve, released?}
//                                                 serve: the TB reached its serve point (simctl_hold.sv)
//                                                 time: ticks >= 0 (0: no-op); cycles: >= 1, of the start clock,
//                                                 refused without a known period (see runTicks)
//   until {expr, maxCycles | maxTime}           expr: sig == lit / sig != lit joined by && / || (&& binds
//                                                 tighter); true at a time step where one of its signals
//                                                 changed, values after the step settles
//   stop {}                                     ends a run in flight (that run replies stopped: stop)
// During a run, time/read/watch/unwatch/watches/list are served at the run's poll points (every --poll-cycles
// cycles of simulated time), at that time step's ReadOnlySynch, and the run goes on: a read's t is the time it
// observed, a new watch's first record (at its reply's t) is where its coverage starts. Writes, checkpoints and
// another run are refused while a run is in flight (stop it first); a stop always reaches the run at once.
//   time {}                                     -> {t}
//   forksave {file}  (--no-ucli workers only)   -> {t, pid, forkMs, file}; later event {saved: pid, file, t, status, ok, bytes, timeout?, error?}; ok: the child checked the image and it is there, not empty.
//                                                 A save without pausing: the library forks, the child $saves
//                                                 (build with vpi/simctl_saver.sv, -top simctl_saver) at t+1 and
//                                                 exits; restore with simv -r <file>. At most two at once.
//   read {signals: [path]}                      -> {t, values: ['01xz..' | null]}
//   force|deposit {signal, value}, release {signal}  value: 'b1x0, 'hff, 'd12, 12, 1_000 (any width) -> {t, value}
//   writes {writes: [{op: force|deposit|release, signal, value}]}  -> {t, writes: [{t, value} | {error}]}
//                                                 all of one request land at the same time step (t+1 of the
//                                                 parked time); separate requests each get their own
//   watch {signals}                             -> {t, watch: [{signalId, width} | null]}
//   unwatch {signalIds}                         -> {unwatched}
//   watches {}                                  -> {watches: [{signalId, name, width}]}
//   list {scope, limit}                         -> {vars: [{name, width}], truncated}
//   checkpoint {}                               -> {cp, t, requestedAt}  (simulator checkpoint, -ucli2Proc)
//                                                 t: the time of the state it holds, where a restore comes
//                                                 back. With the TB held in its serve point (simctl_hold.sv)
//                                                 and serving from it: t == requestedAt. Otherwise (no hold, or
//                                                 the ReadOnlySynch park after an apply's settle) the stop takes
//                                                 effect at the next activity: t > requestedAt; show t
//   restore {cp}                                -> {t, watches} and a full-value changes event
//   save {file} / restoreFile {file}            file-based save/restore, for comparison
//   stats {}                                    -> {pids, pssMb, memAvailMb, licence?, skippedLinks, vmemKb}
// Reusable testbench (simctl_tb.sv in the build, tb.js): stimulus as data, no rebuild. Requests outside what
// the build has answer {id, error, needsRebuild: true, hint}.
//   describe {}                                 -> {cfg: [{path, scenarios}], ports: [{path, name, kind, width,
//                                                 fields}], memories: [{path, words, width}], memoriesTruncated,
//                                                 mode, simv, staleness}
//   scenario {name}, arm {}                     one of the build's scenarios; then the arm (once per run): the
//                                                 ports start driving
//   stim {port, file | text}                    -> {port, transactions, packed} (format: tb.js); before or
//                                                 after the arm
//   stimStatus {port}                           -> {port, driven, active}
//   loadmem {path, file | text, format h|b, start?, end?, via vpi|ucli}  -> {via, t, words, ignored, ms}: a
//                                                 $readmemh/$readmemb image into a memory (describe's memories)
//                                                 one time unit later; via ucli: the simulator's `memory -read`
//   apply {symbol, arg?, at: serve|next, lib?, versionSymbol?, version?, lastErrorSymbol?}
//                                               -> {t, rc, lastError, settled, held, tainted?}: calls
//                                                 `int symbol(const char *arg)`, ALREADY loaded in the simulation
//                                                 (dlsym; lib: an absolute path of a loaded library to look in;
//                                                 nothing is ever loaded). Never from a read-only region:
//                                                 at serve, inside the TB's held serve point (simctl_hold.sv) at
//                                                 this time (from a ReadOnlySynch park with the TB held there: at
//                                                 t+1, back inside its serve point); at next, one time unit later
//                                                 from a callback. rc 0/1: replied after that time step settled
//                                                 (settled:true, the TB still held: reads valid); rc -1/-2: at once
//                                                 (settled:false). After -2 the branch is discarded: run, until,
//                                                 apply, writes and loadmem are refused, results carry tainted:true,
//                                                 until a restore of a state from before it. versionSymbol
//                                                 (`unsigned f(void)`) must return version, else {error: 'abi',
//                                                 have, want, needsRebuild}. Defaults for symbol
//                                                 vcs_restore_apply_plan: vcs_restore_api_version == 3 and
//                                                 vcs_restore_last_error (null turns one off). A run releases a
//                                                 held TB (reply: released, the time it went on).
//   staleness {}                                -> {known, stale, changed, missing, needsRebuild, hint?} from
//                                                 <simv>.simctl.json (simctl-manifest.js)
//   quit {}
// Names, values and expressions must not contain control characters, and names and values no whitespace;
// `file` must be a path inside --scratch of [A-Za-z0-9._/-]; `cp` an integer. Anything else is refused.
// The simulator runs as the leader of its own process group (its command-line process and checkpoint
// children join it); every kill here is of that group, and the library ends the group if this process goes.
// Events: ready {t, precision, period, startupMs}; changes {t0, t1, signals: [{signalId, count, bytes}],
//   binLength} followed by binLength bytes: per signal `bytes` of records [u64 LE delta][width chars]
//   (the first delta is from t0, then from the previous record; the window-record layout of helper-v2,
//   not deflated); finish {t}; exit {code, signal}; memory {...}; error {message}.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const argv = process.argv.slice(2);
const dd = argv.indexOf('--');
const simArgs = dd >= 0 ? argv.slice(dd + 1) : [];
const opts = dd >= 0 ? argv.slice(0, dd) : argv;
const opt = (k, d) => { const i = opts.indexOf(k); return i >= 0 ? opts[i + 1] : d; };
const flag = (k) => opts.includes(k);
const SIMV = path.resolve(opt('--simv', ''));
const LIB = path.resolve(opt('--lib', ''));
const SCRATCH = opt('--scratch', '');
const RUN = opt('--run', `run-${process.pid}`);
const CLOCK = opt('--clock', '');
let period = Number(opt('--period', 0));
if (!(Number.isSafeInteger(period) && period > 0)) period = 0;   // unknown: cycle requests are refused
const RSS_MB = Number(opt('--rss-mb', 2048));
const MIN_AVAIL_MB = Number(opt('--min-avail-mb', 5120));
const POLL_CYCLES = Number(opt('--poll-cycles', 100));
const UCLI_MS = Number(opt('--ucli-timeout-ms', 120000));   // a checkpoint/restore's command-line work
const FORKSAVE_MS = Math.max(1, Number(opt('--forksave-timeout-ms', 120000)) || 120000);   // a fork-save child's deadline
const VMEM_MB = Number(opt('--vmem-mb', 4096));   // hard limit (ulimit -v) per simulator process; 0: none
if (!SIMV || !LIB || !SCRATCH) { process.stderr.write('usage: worker.js --simv <simv> --lib <lib.so> --scratch <dir> -- <args>\n'); process.exit(2); }

const t0 = Date.now();
const out = (obj, bin) => { process.stdout.write(JSON.stringify(obj) + '\n'); if (bin && bin.length) process.stdout.write(bin); };
const event = (name, o = {}) => out({ id: 0, event: name, ...o });
// The parent went away (EPIPE on stdout): nobody to serve. Quit; the exit handler ends the simulation.
process.stdout.on('error', () => process.exit(0));

// ---------------------------------------------------------------- run directory (the replay manifest)
// The run is replayed in <scratch>/<run>, a private copy of the original run's folder (--cwd; default the
// simulator's folder): the files it may read are COPIED there (cloned where the filesystem can), nested folders
// included, never linked, so a testbench that writes a file by an existing name can't reach the original.
// Left out: the run's own outputs (dumps, logs, novas*, ucli.key), build folders (*.daidir, csrc) and the
// simulator. A cmux-replay.json in that folder makes it explicit:
//   {"cwd": "<folder, relative to the manifest>", "inputs": ["<file or folder, relative to cwd>", ...],
//    "env": {"NAME": "value"}}   (only those inputs are copied; env is added to the simulator's environment)
// More than --copy-mb (512) to copy is refused before starting, naming the largest files and the manifest.
// While it runs, the simulator's "cannot open" messages become missingInput events naming the file.
const setupFail = (message) => { event('setupError', { message }); process.exit(3); };
let RUN_CWD = path.resolve(opt('--cwd', path.dirname(SIMV)));
const COPY_MB = Number(opt('--copy-mb', 512));
let manifest = null;
try { manifest = JSON.parse(fs.readFileSync(path.join(RUN_CWD, 'cmux-replay.json'), 'utf8')); } catch (e) {
  if (e.code !== 'ENOENT') setupFail(`cmux-replay.json in ${RUN_CWD}: ${e.message}`);
}
const replayEnv = {};
if (manifest) {
  if (typeof manifest !== 'object' || Array.isArray(manifest)) setupFail('cmux-replay.json: expected an object');
  if (manifest.cwd !== undefined) RUN_CWD = path.resolve(RUN_CWD, String(manifest.cwd));
  if (manifest.inputs !== undefined && !(Array.isArray(manifest.inputs) && manifest.inputs.every((x) => typeof x === 'string'))) setupFail('cmux-replay.json: inputs must be a list of paths');
  for (const [k, v] of Object.entries(manifest.env || {})) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) || k.startsWith('SIMCTL_') || typeof v !== 'string') setupFail(`cmux-replay.json: bad env entry ${JSON.stringify(k)}`);
    replayEnv[k] = v;
  }
}
const dir = path.join(SCRATCH, RUN);
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
const OUTPUT = /\.(fsdb|vpd|vcd|fst|saif|log)$|^novas|^ucli\.key$|^verdi|^\.cmux|^vc_hdrs\.h$/;
const BUILD_DIR = /\.daidir$|^csrc$|^AN\.DB$|^\.git$|^verdiLog$|^\.sims$/;
const plan = [];   // [src, rel, bytes]
const dirReal = fs.realpathSync(dir), scratchReal = fs.realpathSync(SCRATCH);
const cwdReal = (() => { try { return fs.realpathSync(RUN_CWD); } catch { return RUN_CWD; } })();
const cwdInScratch = cwdReal.startsWith(scratchReal + path.sep);
// A symlinked folder (often a link to a big shared tree) is not walked into unless the manifest names it;
// it is listed in skippedLinks (stats, and the missing-input hint). A symlinked file is copied by content.
const skippedLinks = [];
function walk(abs, rel, depth, named = false) {
  let st; try { st = fs.statSync(abs); } catch { return; }
  if (st.isDirectory() && !named && depth > 0) {
    let link = false; try { link = fs.lstatSync(abs).isSymbolicLink(); } catch { return; }
    if (link) { if (skippedLinks.length < 100) skippedLinks.push(rel); return; }
  }
  if (st.isDirectory()) {
    if (depth > 8 || plan.length > 20000) return;
    let real; try { real = fs.realpathSync(abs); } catch { return; }
    if (real === dirReal || (real === scratchReal && !cwdInScratch)) return;   // our copies (a scratch inside the run folder)
    for (const f of fs.readdirSync(abs)) {
      if (BUILD_DIR.test(f)) continue;
      walk(path.join(abs, f), rel ? path.join(rel, f) : f, depth + 1);
    }
  } else if (st.isFile()) {
    if (!manifest && (OUTPUT.test(path.basename(abs)) || path.resolve(abs) === SIMV || path.basename(abs) === 'cmux-replay.json')) return;
    plan.push([abs, rel, st.size]);
  }
}
if (manifest && manifest.inputs) {
  for (const inp of manifest.inputs) {
    const abs = path.resolve(RUN_CWD, inp), rel = path.relative(RUN_CWD, abs);
    if (rel.startsWith('..') || path.isAbsolute(rel)) setupFail(`cmux-replay.json: input ${JSON.stringify(inp)} is outside ${RUN_CWD}`);
    if (!fs.existsSync(abs)) setupFail(`cmux-replay.json names ${inp}, which is missing in ${RUN_CWD}`);
    walk(abs, rel, 0, true);
  }
} else walk(RUN_CWD, '', 0);
const total = plan.reduce((a, x) => a + x[2], 0);
if (total > COPY_MB * 1024 * 1024) {
  const big = [...plan].sort((a, b) => b[2] - a[2]).slice(0, 5).map(([, rel, n]) => `${rel} (${(n / 1048576).toFixed(1)} MB)`);
  setupFail(`the run folder ${RUN_CWD} holds ${(total / 1048576).toFixed(0)} MB to copy (limit ${COPY_MB} MB), largest: ${big.join(', ')}. ` +
    `List the inputs the simulation reads in ${path.join(RUN_CWD, 'cmux-replay.json')} ({"inputs": ["..."]}), or raise --copy-mb.` +
    (skippedLinks.length ? ` Linked folders were not counted (named inputs only): ${skippedLinks.slice(0, 5).join(', ')}.` : ''));
}
for (const [src, rel] of plan) {
  const dst = path.join(dir, rel);
  try { fs.mkdirSync(path.dirname(dst), { recursive: true }); fs.copyFileSync(src, dst, fs.constants.COPYFILE_FICLONE); } catch (e) { setupFail(`copying ${rel} into the scratch run: ${e.message}`); }
}
// "cannot open <file>" from the simulator: the replay lacks an input (or the run needs another folder)
const missingSeen = new Set();
let scanTail = '', scanPending = 0, scanHead = '';
function scanMissing(d) {
  const text = scanTail + d.toString('latin1'); const lines = text.split('\n'); scanTail = lines.pop().slice(-2000);
  for (const line of lines) {
    // VCS: "Warning-[...] Cannot open file" then "  The file 'x' could not be opened. ..." on a line after it
    const hit = /(can ?not|could not|couldn't|unable to|failed to)( be)? open|no such file/i.test(line);
    if (!hit && !scanPending) continue;
    const m = /["'`]([^"'`\s]+)["'`]/.exec(line);
    if (!m) { if (hit) { scanPending = 3; scanHead = line.trim(); } else scanPending--; continue; }
    scanPending = 0;
    if (!hit && !/open/i.test(line)) continue;
    const file = m[1];
    if (missingSeen.has(file) || missingSeen.size > 100) continue;
    missingSeen.add(file);
    event('missingInput', { file, message: `${scanHead ? scanHead + ' ' : ''}${line.trim()}`.slice(0, 400), cwd: RUN_CWD,
      hint: `the replay runs in a copy of ${RUN_CWD}; if ${file} lives elsewhere, name it in ${path.join(RUN_CWD, 'cmux-replay.json')}` +
        (skippedLinks.length ? ` (linked folders are not copied unless named there: ${skippedLinks.slice(0, 5).join(', ')})` : '') });
    scanHead = '';
  }
}

// ---------------------------------------------------------------- launch
// --no-ucli: no command line. Fork-save needs it (measured, W-2024.09): with -ucli2Proc the child's $save asks
// the command-line process first (it writes `ucliCore::ucliPreSsave <file>.FILES` to its output) and waits for
// an answer that cannot come, so no image; with single-process -ucli the image is written but `simv -r` of it
// does not run to the end.
const noUcli = flag('--no-ucli');
const ucli2 = !noUcli && !flag('--no-ucli2proc');
const args = ['-n', '10', SIMV, ...(noUcli ? [] : ['-ucli', ...(ucli2 ? ['-ucli2Proc'] : [])]), ...simArgs];
// sh sets the hard memory limit, then execs nice, which execs the simulator (with -ucli2Proc it runs the design
// in a child process). detached: a new session, whose process group holds all of the simulation's processes.
// The limit cannot go above the hard limit the worker was started under: then that one is used (and said).
let VMEM_KB = VMEM_MB > 0 ? VMEM_MB * 1024 : 0;
if (VMEM_KB > 0) {
  let hard = NaN; try { hard = Number(require('node:child_process').execFileSync('/bin/sh', ['-c', 'ulimit -H -v'], { encoding: 'latin1' }).trim()); } catch { /* unknown */ }
  if (Number.isSafeInteger(hard) && hard > 0 && hard < VMEM_KB) {
    event('notice', { message: `--vmem-mb ${VMEM_MB} is above the hard ulimit -v this worker runs under (${hard} KB); the simulator gets ${hard} KB` });
    VMEM_KB = hard;
  }
}
const sim = spawn('/bin/sh', ['-c', 'if [ "$1" -gt 0 ]; then ulimit -v "$1" || exit 70; fi; shift; exec nice "$@"', 'simctl', String(VMEM_KB), ...args], {
  cwd: dir,
  stdio: ['pipe', 'pipe', 'pipe', 'pipe', 'pipe'],
  env: { ...process.env, ...replayEnv, SIMCTL_IN_FD: '3', SIMCTL_OUT_FD: '4', SIMCTL_LIB: LIB, SIMCTL_OWN_GROUP: '1', SIMCTL_FORKSAVE_TIMEOUT_MS: String(FORKSAVE_MS) },
  detached: true,
});
// The simulator leaves /tmp/vcs_{attachable,dve_general}.<user>.<pid> when killed: remove those of the group.
const USER = (() => { try { return require('node:os').userInfo().username; } catch { return ''; } })();
const killGroup = (sig = 'SIGKILL') => {
  let pids = []; try { pids = groupPids(sim.pid); } catch { /* none */ }
  try { process.kill(-sim.pid, sig); } catch { /* gone */ }
  if (sig === 'SIGKILL' && USER) for (const p of pids) for (const k of ['attachable', 'dve_general']) { try { fs.unlinkSync(`/tmp/vcs_${k}.${USER}.${p}`); } catch { /* none */ } }
};
// The group goes with this process, however it ends (a crash, a signal; SIGKILL is the library's job).
process.on('exit', () => killGroup());
for (const sg of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sg, () => { killGroup(); process.exit(0); });
// run.sh counts running sims by these files (one per worker, removed when it ends)
const SIMS_DIR = path.join(SCRATCH, '.sims');
try { fs.mkdirSync(SIMS_DIR, { recursive: true, mode: 0o700 }); fs.writeFileSync(path.join(SIMS_DIR, String(sim.pid)), String(process.pid)); } catch { /* best effort */ }
process.on('exit', () => { try { fs.unlinkSync(path.join(SIMS_DIR, String(sim.pid))); } catch { /* gone */ } });
const simLog = fs.createWriteStream(path.join(dir, 'sim.out'));
const libIn = sim.stdio[3], libOut = sim.stdio[4];
// a file-based `restore` brings back the simulation's memory but not these pipes: report it, don't crash
for (const st of [libIn, libOut, sim.stdin]) st.on('error', (e) => event('error', { message: `library channel: ${e.code || e.message}` }));
libOut.on('close', () => { for (const [, p] of pending) { if (!p.resolve) out({ id: p.id, error: 'library channel closed' }); if (p.after) p.after(); } });
sim.stderr.on('data', (d) => { simLog.write(d); scanMissing(d); });
// a simulation that went before it could report its saves (killed, crashed): end each one, once, when both the
// process has gone and everything it wrote on the channel has been read
let simGone = false, chanGone = false;
function endSaves() {
  if (!simGone || !chanGone) return;
  for (const [pid, s] of savesOut) event('saved', { pid, file: s.file, t: s.t, status: -1, ok: false, bytes: 0, simExited: true, error: 'simExited: the simulation ended during the save' });
  savesOut.clear();
}
libOut.on('close', () => { chanGone = true; endSaves(); });
sim.on('exit', (code, signal) => {
  simGone = true; setTimeout(endSaves, 0);
  if (code === 70 && !isReady) event('setupError', { message: `the simulator's memory limit (ulimit -v ${VMEM_KB} KB) could not be set; lower --vmem-mb` });
  event('exit', { code, signal, ms: Date.now() - t0 });
  for (const [, p] of pending) out({ id: p.id, error: 'simulation exited' });
  pending.clear();
  // the last chance for saves still out: whatever the channel had has been read by now, or never will be
  setTimeout(() => { chanGone = true; endSaves(); process.exit(0); }, 50);
});

// ---------------------------------------------------------------- simulator command line (UCLI)
let ucliBuf = '', ucliWaiters = [], promptsSeen = 0;
sim.stdout.on('data', (d) => {
  simLog.write(d); scanMissing(d);
  ucliBuf += d.toString('latin1');
  let k;
  while ((k = ucliBuf.indexOf('ucli% ')) >= 0) {
    const text = ucliBuf.slice(0, k); ucliBuf = ucliBuf.slice(k + 6);
    promptsSeen++;
    const w = ucliWaiters.shift();
    if (w) w(text);
  }
});
// While parked (checkpoint/restore), a prompt that never comes (a command-line error with no prompt) would wedge
// every later request: after --ucli-timeout-ms the request errors and the simulation is ended (its state is unknown).
const nextPrompt = (ms = 0) => { let cancel; const p = new Promise((res, rej) => {
  let tm = null;
  const w = (text) => { if (tm) clearTimeout(tm); res(text); };
  ucliWaiters.push(w);
  cancel = () => { if (tm) clearTimeout(tm); const i = ucliWaiters.indexOf(w); if (i >= 0) ucliWaiters.splice(i, 1); };
  if (ms > 0) tm = setTimeout(() => {
    const i = ucliWaiters.indexOf(w); if (i >= 0) ucliWaiters.splice(i, 1);
    const message = `the simulator's command line gave no prompt within ${ms} ms; the simulation is ended`;
    event('error', { message });
    rej(Object.assign(new Error(message), { wedged: true }));
    setTimeout(() => { killGroup(); process.exit(1); }, 100);   // after the request's error reply is out
  }, ms);
}); p.cancel = cancel; return p; };
const ucli = (cmd) => { const p = nextPrompt(UCLI_MS); sim.stdin.write(cmd + '\n'); return p; };

// ---------------------------------------------------------------- library channel
let libId = 1;
const pending = new Map();          // libId -> {id, cmd, sent, resolve?}
let rbuf = Buffer.alloc(0), needBin = 0, chgHdr = null;
const watches = new Map();          // wid -> {name, width}
const unwatchedWidth = new Map();   // wid -> width, of watches dropped here (the library may still send some)
let lastT = 0, inflightRun = null, pruneAtRunEnd = [];
libOut.on('data', (d) => {
  rbuf = rbuf.length ? Buffer.concat([rbuf, d]) : d;
  for (;;) {
    if (chgHdr) {
      if (rbuf.length < chgHdr.bin) return;
      const bin = rbuf.subarray(0, chgHdr.bin); rbuf = rbuf.subarray(chgHdr.bin);
      onChanges(chgHdr.n, bin); chgHdr = null; continue;
    }
    const nl = rbuf.indexOf(10);
    if (nl < 0) return;
    const line = rbuf.subarray(0, nl).toString(); rbuf = rbuf.subarray(nl + 1);
    let m; try { m = JSON.parse(line); } catch { event('error', { message: 'bad line from library: ' + line.slice(0, 200) }); continue; }
    if (m.ev === 'chg') { chgHdr = m; continue; }
    onLib(m);
  }
});
function onChanges(n, bin) {
  // regroup [u64 t][u32 wid][chars] records per signal as [u64 delta][chars]
  const per = new Map(); let off = 0, tmin = Infinity, tmax = 0;
  for (let i = 0; i < n; i++) {
    const t = Number(bin.readBigUInt64LE(off)); const wid = bin.readUInt32LE(off + 8);
    const w = watches.get(wid);
    if (!w) {
      // unwatched meanwhile (the library drops it only once the run ends): skip this record, keep the rest
      const width = unwatchedWidth.get(wid);
      if (width === undefined) { event('error', { message: `record for unknown watch ${wid}; rest of the batch dropped` }); return; }
      off += 12 + width; continue;
    }
    const width = w.width;
    let s = per.get(wid); if (!s) per.set(wid, (s = []));
    s.push([t, bin.subarray(off + 12, off + 12 + width)]);
    if (t < tmin) tmin = t; if (t > tmax) tmax = t;
    off += 12 + width;
  }
  const parts = [], sigs = [];
  for (const [wid, recs] of per) {
    const w = watches.get(wid);
    const b = Buffer.allocUnsafe(recs.length * (8 + w.width));
    let o = 0, prev = tmin;
    for (const [t, v] of recs) { b.writeBigUInt64LE(BigInt(t - prev), o); v.copy(b, o + 8); o += 8 + w.width; prev = t; }
    parts.push(b); sigs.push({ signalId: wid, count: recs.length, bytes: b.length });
  }
  const all = Buffer.concat(parts);
  lastT = Math.max(lastT, tmax);
  out({ id: 0, event: 'changes', t0: tmin, t1: tmax, signals: sigs, binLength: all.length }, all);
}
let isReady = false;
const savesOut = new Map();   // forksave pid -> {file, t}: each gets exactly one saved event (the library's, or at exit)
let tainted = false;   // an apply returned -2 in the current branch (the library's T/G/apply replies say so)
let readyResolve; const ready = new Promise((r) => (readyResolve = r));
function onLib(m) {
  if (m.ev === 'ready') { readyResolve(m); return; }
  if (m.ev === 'finish') { event('finish', { t: m.t }); return; }
  if (m.ev === 'saved') {
    // ok only when the child said so (status 0: it checked the image) and the image is there and not empty
    let bytes = 0; try { bytes = fs.statSync(m.file).size; } catch { /* not there */ }
    // one outcome: a timeout or a simulation end is never ok, whatever is on disk
    const ok = m.status === 0 && bytes > 0 && !m.timeout && !m.simExited;
    if (!savesOut.delete(m.pid)) return;   // not ours, or already reported
    const why = m.simExited ? 'simExited: the simulation ended during the save' : m.timeout ? `still running after --forksave-timeout-ms ${FORKSAVE_MS}: ended` : m.status === 2 ? 'no image written' : m.status === 3 ? 'the simulator reported a save error (see <file>.log)'
      : m.status === 4 ? 'the checked image could not be moved to its name'
      : m.status !== 0 ? `the save child ended with status ${m.status}` : bytes > 0 ? '' : 'the image is missing or empty';
    event('saved', { pid: m.pid, file: m.file, t: m.t, status: m.status, ok, bytes, ...(m.timeout ? { timeout: true } : {}), ...(m.simExited ? { simExited: true } : {}), ...(why ? { error: why } : {}) });
    return;
  }
  const p = pending.get(m.id);
  if (!p) return;
  pending.delete(m.id);
  if (p.after) setImmediate(p.after);   // after this reply (and its tainted flag) is handled below
  if (m.t !== undefined) lastT = m.t;
  if (p === inflightRun) {
    inflightRun = null;
    // the run's end flushed every record: none of an unwatched signal can still come
    for (const w of pruneAtRunEnd) unwatchedWidth.delete(w);
    pruneAtRunEnd = [];
  }
  // an unwatch served between runs: its records were all sent before the reply; during a run (served at a poll
  // point) records gathered before it may still follow, until the run ends
  if (p.unwatch) { if (inflightRun) pruneAtRunEnd.push(...p.unwatch); else for (const w of p.unwatch) unwatchedWidth.delete(w); }
  if (m.tainted !== undefined) tainted = !!m.tainted;
  if (p.forksave && m.pid) savesOut.set(m.pid, { file: m.file, t: m.t });
  if (p.resolve) { p.resolve(m); return; }
  if (m.error) { const { id: _drop, ...e } = m; out({ id: p.id, ...e }); return; }
  delete m.id;
  if (tainted) m.tainted = true;
  if (m.watch && p.names) {
    m.watch = m.watch.map((w, i) => { if (!w) return null; watches.set(w.wid, { name: p.names[i], width: w.width }); return { signalId: w.wid, width: w.width }; });
  }
  if (m.watches) m.watches = m.watches.map((w) => ({ signalId: w.wid, name: w.name, width: w.width }));
  out({ id: p.id, result: m, ms: +(performance.now() - p.sent).toFixed(3) });
}
function lib(op, id, rest, extra = {}) {
  const lid = libId++;
  const p = { id, sent: performance.now(), ...extra };
  pending.set(lid, p);
  libIn.write(`${op} ${lid}${rest ? ' ' + rest : ''}\n`);
  return p;
}
const libCall = (op, rest) => new Promise((resolve) => lib(op, 0, rest, { resolve }));

// ---------------------------------------------------------------- memory guards
// The simulation's processes: its process group (reparented checkpoint children included).
// Linux reads /proc; elsewhere (macOS, where cmux's checks run the worker against a fake simulator) ps stands in
// and the host-memory guard is off (memAvailMb Infinity).
const HAVE_PROC = fs.existsSync('/proc/self/stat');
function groupPids(pgid) {
  const outp = [];
  if (!HAVE_PROC) {
    try {
      for (const l of require('node:child_process').execFileSync('ps', ['-A', '-o', 'pid=,pgid='], { encoding: 'latin1' }).split('\n')) {
        const [p, g] = l.trim().split(/\s+/).map(Number); if (g === pgid) outp.push(p);
      }
    } catch { /* none */ }
    return outp;
  }
  for (const p of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(p)) continue;
    try { const st = fs.readFileSync(`/proc/${p}/stat`, 'latin1'); if (Number(st.slice(st.lastIndexOf(')') + 2).split(' ')[2]) === pgid) outp.push(Number(p)); } catch {}
  }
  return outp;
}
function pssKb(pid) {
  if (!HAVE_PROC) return 0;
  try { const s = fs.readFileSync(`/proc/${pid}/smaps_rollup`, 'latin1'); const m = /^Pss:\s+(\d+)/m.exec(s); return m ? Number(m[1]) : 0; } catch { return 0; }
}
function memAvailMb() {
  if (!HAVE_PROC) return Infinity;
  const m = /MemAvailable:\s+(\d+)/.exec(fs.readFileSync('/proc/meminfo', 'latin1')); return m ? Number(m[1]) / 1024 : 0;
}
let lowMem = false, peakPss = 0, treePids = [], treeAt = 0;
function memStats(fresh) {
  // walking /proc for the process tree is the expensive part: redo it every 10 s (checkpoints add processes)
  if (fresh || Date.now() - treeAt > 10000) { treePids = groupPids(sim.pid); treeAt = Date.now(); }
  const pids = treePids;
  const pss = pids.reduce((a, p) => a + pssKb(p), 0) / 1024;
  if (pss > peakPss) peakPss = pss;
  return { pids, pssMb: +pss.toFixed(1), peakPssMb: +peakPss.toFixed(1), memAvailMb: Number.isFinite(memAvailMb()) ? +memAvailMb().toFixed(0) : null };
}
const guard = setInterval(() => {
  if (sim.exitCode !== null) return;
  const s = memStats();
  if (s.pssMb > RSS_MB) {
    event('memory', { ...s, killed: true, message: `simulation over ${RSS_MB} MB; killed` });
    killGroup();
    return;
  }
  const low = s.memAvailMb !== null && s.memAvailMb < MIN_AVAIL_MB;
  if (low && !lowMem) { event('memory', { ...s, paused: true }); if (inflightRun) libIn.write(`S ${libId++}\n`); }
  if (!low && lowMem) event('memory', { ...s, paused: false });
  lowMem = low;
}, 1000);
guard.unref();

// ---------------------------------------------------------------- requests
const queue = []; let parked = false;
async function park(work) {
  // checkpoint/restore need the simulator's command line: park the library there, do the work, come back.
  parked = true;
  const prompt = nextPrompt(UCLI_MS);
  prompt.catch(() => {});             // handled below; never an unhandled rejection while P is in flight
  const pr = await libCall('P', '');
  // refused (e.g. a hold the build can't write): the simulation never stops, so no prompt is coming
  if (pr.error) { prompt.cancel(); parked = false; throw new Error(pr.error); }
  await prompt;                       // a wedged command line throws (the simulation is being ended)
  let result;
  try { result = await work(); } catch (e) { if (e.wedged) throw e; result = { error: String(e.message || e) }; }
  libIn.write(`K ${libId++}\n`);      // the library's resume callback serves again once it sees this
  sim.stdin.write('run\n');
  parked = false;
  // where serving resumed: the time of the state a checkpoint taken here holds (the requested time from a held
  // serve point; otherwise where the stop took effect, later)
  const back = await libCall('T', '');
  tainted = !!back.tainted;           // a restore may have brought back a state from before a discard
  return { requestedAt: pr.t, t: back.t, ...result };
}
// ---------------------------------------------------------------- request validation
const BAD_TOKEN = /[\s\x00-\x1f\x7f]/;
function names(list, what = 'signal') {
  if (!Array.isArray(list)) throw new Error(`${what}s: expected a list`);
  return list.map((n) => token(n, what));
}
function token(v, what) {
  const s = String(v ?? '');
  if (!s || BAD_TOKEN.test(s)) throw new Error(`bad ${what} ${JSON.stringify(s).slice(0, 80)}: no whitespace or control characters`);
  return s;
}
function exprTokens(expr) {
  const e = String(expr || '');
  if (/[\x00-\x1f\x7f]/.test(e)) throw new Error('bad expression: control characters');
  return e.replace(/(&&|\|\||==|!=)/g, ' $1 ').trim().split(/\s+/).filter(Boolean).map((t) => token(t, 'expression token'));
}
function scratchFile(f) {
  const s = String(f || '');
  if (!/^[A-Za-z0-9._/-]+$/.test(s)) throw new Error('bad file: use [A-Za-z0-9._/-] only');
  const abs = path.resolve(dir, s);
  const root = path.resolve(SCRATCH) + path.sep;
  if (!abs.startsWith(root)) throw new Error(`bad file: must be inside ${SCRATCH}`);
  return abs;
}
const WRITE_OPS = { force: 'F', deposit: 'D', release: 'L' };
// One request's writes: one group (Y), so they land at the same time step. Each gets its own reply.
function writeGroup(list) {
  const lines = [], waits = [];
  for (const w of list) {
    const op = WRITE_OPS[w.op];
    if (!op) { waits.push(Promise.resolve({ error: `unknown write op ${w.op}` })); continue; }
    let sig, val;
    try { sig = token(w.signal, 'signal'); if (op !== 'L') val = token(w.value, 'value'); } catch (e) { waits.push(Promise.resolve({ error: e.message })); continue; }
    const lid = libId++;
    waits.push(new Promise((resolve) => pending.set(lid, { id: 0, sent: performance.now(), resolve })));
    lines.push(`${op} ${lid} ${sig}${op === 'L' ? '' : ' ' + val}`);
  }
  if (lines.length) libIn.write(lines.join('\n') + `\nY ${libId++}\n`);
  return Promise.all(waits).then((rs) => rs.map((m) => (m.error ? { error: m.error, ...(m.needsRebuild ? { needsRebuild: true } : {}) } : { t: m.t, value: m.value })));
}
// A run's length in ticks, or an error. `time` is in ticks (0: a zero-time no-op). `cycles` are periods of the
// clock named at start (--clock, measured as the time between two rising edges, or --period): a whole number
// >= 1, and refused when no positive period is known. With several clocks, cycles count only that one.
function runTicks(r, c, t) {
  if (r[t] !== undefined) {
    const v = r[t];
    if (!Number.isSafeInteger(v) || v < 0) return { error: `${t} must be a whole number of ticks >= 0` };
    return { dt: v };
  }
  if (r[c] === undefined) return { error: `need ${c} or ${t}` };
  if (!(Number.isFinite(period) && period > 0)) return { error: `${c}: no clock period is known; start the simulation with a clock (--clock), or give ${t}` };
  const v = r[c];
  if (!Number.isSafeInteger(v) || v < 1) return { error: `${c} must be a whole number >= 1` };
  const dt = v * period;
  if (!Number.isSafeInteger(dt)) return { error: `${c} too large` };
  return { dt };
}
// ---------------------------------------------------------------- reusable testbench
const tbx = require('./tb.js');
let built = null;   // the last describe: {cfg, ports}
async function describeBuild(fresh = false) {
  if (built && !fresh) return built;
  const d = await libCall('H', '');
  built = { cfg: d.cfg || [], ports: d.ports || [], memories: d.memories || [], memoriesTruncated: !!d.memoriesTruncated };
  return built;
}
const rebuildErr = (message, hint) => Object.assign(new Error(message), { needsRebuild: true, hint });
const strLit = (str) => `'h${Buffer.from(str, 'latin1').toString('hex') || '0'}`;
async function readBits(name) { const g = await libCall('G', name); return g.values && g.values[0]; }
async function toggle(name) {
  const v = await readBits(name);
  if (typeof v !== 'string') throw new Error(`cannot read ${name}`);
  return v.endsWith('1') ? "'b0" : "'b1";
}
async function mustWrite(list) {
  const ws = await writeGroup(list);
  const bad = ws.find((w) => w.error);
  if (bad) throw new Error(`write failed: ${bad.error}`);
  return ws;
}
async function tbRequest(r) {
  const d = await describeBuild();
  const cfg = d.cfg[0];
  if (r.cmd === 'scenario' || r.cmd === 'arm') {
    if (!cfg) throw rebuildErr('this build has no simctl_cfg', 'instantiate simctl_cfg (simctl_tb.sv) in the testbench and rebuild');
    if ((await readBits(`${cfg.path}.armed`)) === '1') throw new Error('already armed: the scenario and the arm are chosen once per run (restore a checkpoint taken before the arm to choose again)');
    if (r.cmd === 'scenario') {
      const list = String(cfg.scenarios || '').split(';').map((x) => x.split(':')[0].trim()).filter(Boolean);
      const name = String(r.name || '');
      if (!list.includes(name)) throw rebuildErr(`no scenario ${JSON.stringify(name)} in this build (scenarios: ${list.join(', ') || 'none'})`, 'a scenario is testbench code: add it and rebuild, or drive the stimulus as data (stim)');
      if (!/^[A-Za-z0-9_.-]{1,64}$/.test(name)) throw new Error('bad scenario name');
      await mustWrite([{ op: 'deposit', signal: `${cfg.path}.scenario_r`, value: strLit(name) }]);
      return { scenario: name };
    }
    const w = await mustWrite([{ op: 'deposit', signal: `${cfg.path}.arm_req`, value: await toggle(`${cfg.path}.arm_req`) }]);
    return { armed: true, t: w[0].t };
  }
  const port = d.ports.find((p) => p.name === r.port);
  if (!port) throw rebuildErr(`no port ${JSON.stringify(r.port)} in this build (ports: ${d.ports.map((p) => p.name).join(', ') || 'none'})`, 'a drivable interface is a simctl_port in the testbench: add one and rebuild');
  if (r.cmd === 'stimStatus') {
    const [driven, active] = await Promise.all([readBits(`${port.path}.driven`), readBits(`${port.path}.active`)]);
    return { port: port.name, driven: driven ? Number(BigInt('0b' + driven.replace(/[xz]/g, '0'))) : null, active: active === '1' };
  }
  let text = r.text;
  if (text === undefined) {
    if (typeof r.file !== 'string' || !r.file) throw new Error('stim: give file (a stimulus text file) or text');
    try { text = fs.readFileSync(path.resolve(RUN_CWD, r.file), 'utf8'); } catch (e) { throw new Error(`stim: cannot read ${r.file}: ${e.code || e.message}`); }
  }
  const { packed, count } = tbx.packStim(port, text);
  const sdir = path.join(dir, 'simctl-stim'); fs.mkdirSync(sdir, { recursive: true });
  const pf = path.join(sdir, `${port.name.replace(/[^A-Za-z0-9_.-]/g, '_')}-${++stimN}.stim`);
  fs.writeFileSync(pf, packed);
  if (pf.length > 1000) throw new Error('stim: scratch path too long for the port');
  await mustWrite([{ op: 'deposit', signal: `${port.path}.file_r`, value: strLit(pf) }]);
  await mustWrite([{ op: 'deposit', signal: `${port.path}.load_req`, value: await toggle(`${port.path}.load_req`) }]);
  return { port: port.name, transactions: count, packed: pf };
}
let stimN = 0;
// loadmem {path, file | text, format: 'h'|'b', start?, end?, via: 'vpi' (default) | 'ucli'}
async function loadMem(r) {
  const mpath = token(r.path, 'memory');
  let text = r.text;
  if (text === undefined) {
    if (typeof r.file !== 'string' || !r.file) throw new Error('loadmem: give file (a $readmemh/$readmemb image) or text');
    try { text = fs.readFileSync(path.resolve(RUN_CWD, r.file), 'utf8'); } catch (e) { throw new Error(`loadmem: cannot read ${r.file}: ${e.code || e.message}`); }
  }
  const format = r.format === undefined ? 'h' : String(r.format);
  const start = r.start === undefined ? 0 : Number(r.start), end = r.end === undefined ? Infinity : Number(r.end);
  if (r.end !== undefined && (!Number.isSafeInteger(end) || end < start)) throw new Error('loadmem: end must be a whole number >= start');
  const sdir = path.join(dir, 'simctl-mem'); fs.mkdirSync(sdir, { recursive: true });
  const n = ++memN;
  if ((r.via || 'vpi') === 'ucli') {
    // the simulator's documented command: memory -read <nid> -file <f> -radix <hex|bin> [-start] [-end]
    if (noUcli) throw new Error("loadmem via ucli needs the simulator's command line: this worker was started with --no-ucli");
    if (!/^[A-Za-z0-9_.$\[\]]+$/.test(mpath)) throw new Error('loadmem: memory path: [A-Za-z0-9_.$[]] only for via ucli');
    const f = path.join(sdir, `img-${n}.mem`); fs.writeFileSync(f, text);
    const cmd = `memory -read ${mpath} -file {${f}} -radix ${format === 'b' ? 'bin' : 'hex'}${r.start !== undefined ? ` -start ${start}` : ''}${r.end !== undefined ? ` -end ${end}` : ''}`;
    const t0 = performance.now();
    const res = await park(async () => {
      // parked: the library can't answer now, but every reply sent before P's (an apply's -2 too) has been read
      if (tainted) throw new Error('loadmem: this branch is discarded (an apply returned -2): restore a checkpoint from before it');
      return { ucli: (await ucli(cmd)).trim().slice(-400) };
    });
    if (res.error) throw new Error(res.error);
    if (/error/i.test(res.ucli)) throw new Error(`loadmem via ucli: ${res.ucli}`);
    return { via: 'ucli', ms: +(performance.now() - t0).toFixed(1), ...res };
  }
  const { packed, words, ignored } = tbx.packMem(text, { format, start, end });
  if (!words) throw new Error('loadmem: the image has no words');
  const pf = path.join(sdir, `img-${n}.packed`); fs.writeFileSync(pf, packed);
  const t0 = performance.now();
  const m = await libCall('M', `${mpath} ${pf}`);
  if (m.error) throw new Error(m.error);
  return { via: 'vpi', t: m.t, words: m.words, ignored, ms: +(performance.now() - t0).toFixed(1) };
}
let memN = 0;
async function handle(r) {
  const id = r.id;
  // true (and the one reply sent) when a run is in flight: the caller must return at once
  const busyRun = () => { if (!inflightRun) return false; out({ id, error: 'a run is in flight; stop it first' }); return true; };
  switch (r.cmd) {
    case 'run': case 'until': {
      if (busyRun()) return;
      if (lowMem) return out({ id, error: 'paused: host memory low' });
      const rt = r.cmd === 'run' ? runTicks(r, 'cycles', 'time') : runTicks(r, 'maxCycles', 'maxTime');
      if (rt.error) return out({ id, error: rt.error });
      const dt = rt.dt;
      if (r.cmd === 'run') { inflightRun = lib('R', id, String(dt)); return; }
      inflightRun = lib('U', id, `${dt} ${exprTokens(r.expr).join(' ')}`); return;
    }
    case 'stop': libIn.write(`S ${libId}\n`); pending.set(libId++, { id, sent: performance.now() }); return;
    case 'time': lib('T', id, ''); return;
    // a file save without pausing the simulation (also during a run, at its next poll point): needs a build with
    // the simctl_saver top; at most two at once; the end comes as a `saved` event
    case 'forksave':
      if (!noUcli) return out({ id, error: 'forksave needs a worker started with --no-ucli (with the command line the save does not complete: -ucli2Proc writes no image, -ucli an image simv -r does not finish)' });
      if (lowMem) return out({ id, error: 'paused: host memory low (a forksave forks the simulation)' });
      lib('V', id, scratchFile(r.file), { forksave: true }); return;
    case 'read': lib('G', id, names(r.signals || []).join(' ')); return;
    case 'force': case 'deposit': case 'release': {
      if (busyRun()) return;   // the library applies writes only between runs: refused, not held (a stop must get through)
      const [w] = await writeGroup([{ op: r.cmd, signal: r.signal, value: r.value }]);
      out(w.error ? { id, ...w } : { id, result: w }); return;
    }
    case 'writes': {
      if (busyRun()) return;
      if (!Array.isArray(r.writes) || !r.writes.length) return out({ id, error: 'writes: expected a non-empty list' });
      const ws = await writeGroup(r.writes);
      const t = ws.find((w) => !w.error);
      out({ id, result: { t: t ? t.t : lastT, writes: ws } }); return;
    }
    case 'watch': { const ns = names(r.signals || []); lib('W', id, ns.join(' '), { names: ns }); return; }
    case 'unwatch': {
      const ids = (r.signalIds || []).map(Number).filter(Number.isInteger);
      for (const w of ids) { const x = watches.get(w); if (x) { unwatchedWidth.set(w, x.width); watches.delete(w); } }
      lib('X', id, ids.join(' '), { unwatch: ids }); return;
    }
    case 'watches': lib('I', id, ''); return;
    case 'list': lib('N', id, `${token(r.scope, 'scope')} ${Math.max(1, Math.floor(Number(r.limit) || 10000))}`); return;
    case 'option': lib('O', id, `poll ${Math.max(1, Math.floor(Number(r.poll) || 1))}`); return;
    case 'checkpoint': case 'restore': case 'save': case 'restoreFile': {
      if (noUcli) return out({ id, error: `${r.cmd} needs the simulator's command line: this worker was started with --no-ucli` });
      if (busyRun()) return;
      if (lowMem) return out({ id, error: 'paused: host memory low (a checkpoint or restore forks the simulation)' });
      let ucliCmd;
      if (r.cmd === 'checkpoint') ucliCmd = 'checkpoint -add simctl';
      else if (r.cmd === 'restore') { if (!Number.isSafeInteger(r.cp) || r.cp < 0) return out({ id, error: 'restore: cp must be a checkpoint number' }); ucliCmd = `checkpoint -join ${r.cp}`; }
      else ucliCmd = `${r.cmd === 'save' ? 'save' : 'restore'} {${scratchFile(r.file)}}`;   // brace-quoted Tcl word, charset already safe
      const s0 = performance.now();
      let res;
      try { res = await park(async () => {
        const u0 = performance.now();
        const txt = await ucli(ucliCmd);
        const ucliMs = performance.now() - u0;
        const o = { ucliMs: +ucliMs.toFixed(1), ucli: txt.trim().slice(-400) };
        if (r.cmd === 'checkpoint') { const m = /(\d+)\s*$/.exec(txt.trim()); o.cp = m ? Number(m[1]) : null; }
        return o;
      }); } catch (e) { return out({ id, error: String(e.message || e) }); }
      if (r.cmd === 'restore' || r.cmd === 'restoreFile') {
        // the library's own state (watches, last values) rewinds with the simulation
        const info = await libCall('I', '');
        watches.clear();
        for (const w of info.watches || []) watches.set(w.wid, { name: w.name, width: w.width });
        res.watches = (info.watches || []).map((w) => ({ signalId: w.wid, name: w.name, width: w.width }));
        await libCall('E', '');
        res.t = info.t;
      }
      treeAt = 0;   // a checkpoint or restore changed the group: count it afresh
      out({ id, result: res, ms: +(performance.now() - s0).toFixed(1) });
      return;
    }
    // ---- reusable testbench (simctl_tb.sv, tb.js): stimulus as data, no rebuild
    case 'describe': {
      const d = await describeBuild(true);
      out({ id, result: { ...d, mode: noUcli ? 'noUcli' : 'ucli', simv: SIMV, staleness: tbx.staleness(SIMV) } }); return;
    }
    case 'scenario': case 'arm': case 'stim': case 'stimStatus': {
      if (busyRun()) return;
      try { out({ id, result: await tbRequest(r) }); }
      catch (e) { out({ id, error: e.message, ...(e.needsRebuild ? { needsRebuild: true, hint: e.hint || '' } : {}) }); }
      return;
    }
    case 'staleness': out({ id, result: tbx.staleness(SIMV) }); return;
    case 'apply': {
      if (busyRun()) return;
      const SYM = /^[A-Za-z_][A-Za-z0-9_]*$/;
      if (r.at !== 'serve' && r.at !== 'next') return out({ id, error: 'apply: at must be "serve" or "next"' });
      if (typeof r.symbol !== 'string' || !SYM.test(r.symbol)) return out({ id, error: 'apply: symbol must be a C identifier' });
      const dflt = r.symbol === 'vcs_restore_apply_plan';
      const vs = r.versionSymbol !== undefined ? r.versionSymbol : dflt ? 'vcs_restore_api_version' : null;
      const es = r.lastErrorSymbol !== undefined ? r.lastErrorSymbol : dflt ? 'vcs_restore_last_error' : null;
      const ver = r.version !== undefined ? r.version : dflt ? 3 : null;
      for (const [k, v] of [['versionSymbol', vs], ['lastErrorSymbol', es]]) if (v !== null && (typeof v !== 'string' || !SYM.test(v))) return out({ id, error: `apply: ${k} must be a C identifier or null` });
      if (vs !== null && !(Number.isSafeInteger(ver) && ver >= 0 && ver <= 0xffffffff)) return out({ id, error: 'apply: version must be an unsigned integer' });
      if (r.lib !== undefined && (typeof r.lib !== 'string' || !path.isAbsolute(r.lib) || BAD_TOKEN.test(r.lib))) return out({ id, error: 'apply: lib must be an absolute path without whitespace' });
      const arg = r.arg === undefined ? '' : r.arg;
      if (typeof arg !== 'string' || arg.includes('\0')) return out({ id, error: 'apply: arg must be a string' });
      // the next request waits for this one's reply: what follows must see a -2 (discard) before it acts
      const ap = lib('A', id, `${r.at} ${r.symbol} x${Buffer.from(arg, 'utf8').toString('hex')} ${r.lib || '-'} ${vs || '-'} ${vs ? ver : 0} ${es || '-'}`);
      await new Promise((res) => { ap.after = res; });
      return;
    }
    case 'loadmem': {
      if (busyRun()) return;
      // both routes: via ucli would otherwise bypass the library's fence
      if (tainted) return out({ id, error: 'loadmem: this branch is discarded (an apply returned -2): restore a checkpoint from before it' });
      try { out({ id, result: await loadMem(r) }); }
      catch (e) { out({ id, error: e.message, ...(e.needsRebuild ? { needsRebuild: true, hint: e.hint || '' } : {}) }); }
      return;
    }
    case 'stats': out({ id, result: { ...memStats(true), period, lastT, unwatchedKept: unwatchedWidth.size, skippedLinks, vmemKb: VMEM_KB } }); return;
    case 'quit': lib('Q', id, ''); setTimeout(() => { try { if (!noUcli) sim.stdin.write('quit\n'); sim.stdin.end(); } catch {} }, 200);
      setTimeout(() => killGroup(), 10000).unref();
      return;
    default: out({ id, error: `unknown cmd ${r.cmd}` });
  }
}
let chain = Promise.resolve(), queued = 0;
const rl = require('node:readline').createInterface({ input: process.stdin });
rl.on('line', (line) => {
  if (!line.trim()) return;
  let r; try { r = JSON.parse(line); } catch { out({ id: null, error: 'bad JSON' }); return; }
  // Requests keep their order. A stop goes straight through when a run is in flight (whatever is queued behind
  // it: during a run nothing in the chain waits for the library, since writes and checkpoints are refused then)
  // or when nothing is queued; behind queued requests with no run in flight yet (a run not sent) it waits its
  // turn, so it stops that run.
  if (r.cmd === 'stop' && !parked && (inflightRun || queued === 0)) { handle(r); return; }
  queued++;
  chain = chain.then(() => handle(r)).catch((e) => out({ id: r.id, error: String((e && e.message) || e) })).finally(() => { queued--; });
});
rl.on('close', () => { if (sim.exitCode === null) handle({ id: 0, cmd: 'quit' }); });

// ---------------------------------------------------------------- startup
(async () => {
  if (!noUcli) {
    await nextPrompt();               // the simulator's command line at time 0
    sim.stdin.write('run\n');         // the library parks the run at time 0 and serves
  }                                   // (with --no-ucli the simulation starts at once and the library parks it)
  const r = await ready;
  if (!period && CLOCK) {
    // measure the clock: two rising edges
    const a = await libCall('U', `100000000 ${CLOCK} == 1`);
    const b = await libCall('U', `100000000 ${CLOCK} == 1`);
    if (a.stopped === 'until' && b.stopped === 'until') period = b.t - a.t;
  }
  if (period && POLL_CYCLES) await libCall('O', `poll ${period * POLL_CYCLES}`);
  const t = await libCall('T', '');
  isReady = true;
  event('ready', { t: t.t, precision: r.precision, period, startupMs: Date.now() - t0, dir, ucli2Proc: ucli2, ucli: !noUcli });
})();
