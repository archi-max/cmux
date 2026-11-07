// run.sh sim-unit: fsdb-helper-v2/sim.js (live simulation commands) with fake-worker.cjs standing in for the
// simulator worker. No simulator, no network. Usage: node sim-unit.cjs <fsdb-helper-v2 folder> <scratch>
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const [helperDir, scratchArg] = process.argv.slice(2);
const scratch = fs.mkdtempSync(path.join(scratchArg || require('node:os').tmpdir(), 'sim-unit-'));
let failures = 0;
const expect = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failures++; };
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// fixture copies: `run` names a stub that exists, `nostub` a build without one
const fixture = path.join(__dirname, 'fixture');
fs.cpSync(fixture, path.join(scratch, 'fx'), { recursive: true });
const runDir = path.join(scratch, 'fx/run'), noStubDir = path.join(scratch, 'fx/nostub');
const stub = path.join(scratch, 'stub/libsimctl_stub.so'); fs.mkdirSync(path.dirname(stub)); fs.writeFileSync(stub, '');
const lib = path.join(scratch, 'lib/libsimctl.so'); fs.mkdirSync(path.dirname(lib)); fs.writeFileSync(lib, '');
fs.writeFileSync(path.join(runDir, 'simv.daidir/.vcs.timestamp'),
  `vcs -full64 -kdb -debug_access+all -load /opt/eda/verdi/share/PLI/VCS/LINUX64/libnovas.so:FSDBDumpCmd -load ${stub}:simctl_register\n`);
const workerLog = path.join(scratch, 'worker-argv.json');
process.env.CMUX_SIM_WORKER = path.join(__dirname, 'fake-worker.cjs');
process.env.CMUX_SIM_LIB = lib;
process.env.CMUX_SIM_STUB = '/home/me/.cache/cmux/simctl/libsimctl_stub.so';
process.env.FAKE_WORKER_LOG = workerLog;
process.env.CMUX_SIM_SCRATCH = scratch;   // the workers' private folders, under this run's scratch

const sim = require(path.join(helperDir, 'sim.js'));

// ---- pure parts
const log = fs.readFileSync(path.join(fixture, 'run/novas_dump.log'), 'utf8');
const parsed = sim.parseDumpLog(log);
expect(parsed && parsed.simv === './simv', 'novas_dump.log: the simulator is option[0]');
expect(parsed && eq(parsed.args, ['+iters=3', '+fsdb=/work/elsewhere/dump.fsdb', '-l', 'run.log', '+ntb_random_seed=7']), 'novas_dump.log: run arguments end before the compiler entry');
expect(eq(sim.runArgs(parsed ? parsed.args : []), ['+iters=3', '+ntb_random_seed=7']), 'run arguments drop +fsdb and -l <file>');
expect(eq(sim.runArgs(['-l', 'a.log', '+fsdbfile+x.fsdb', '-ucli', '-ucli2Proc', '+v=1', '-l']), ['+v=1']), 'run arguments also drop +fsdbfile, -ucli, -ucli2Proc and a trailing -l');
expect(sim.dumpFileOf(parsed ? parsed.args : []) === '/work/elsewhere/dump.fsdb', 'the logged dump file is reported');
expect(sim.stubFrom(`-load ${stub}:simctl_register -o simv`) === stub, 'the stub path comes from the build record');
expect(sim.stubFrom('-load /opt/eda/verdi/libnovas.so:FSDBDumpCmd') === null, 'a build without the stub has none');
expect(sim.parseDumpLog('no options here') === null, 'a log without options parses to null');

// ---- the commands, through handle(req, send)
const waiting = new Map(); const replies = [];
let nextId = 1;
const send = (obj, bin) => { replies.push(obj); const w = waiting.get(obj.id); if (w) { waiting.delete(obj.id); w({ ...obj, bin: bin || null }); } };
const req = (cmd, args = {}, timeoutMs = 10000) => new Promise((resolve) => {
  const id = nextId++;
  const timer = setTimeout(() => { waiting.delete(id); resolve({ id, error: 'TEST TIMEOUT' }); }, timeoutMs);
  waiting.set(id, (m) => { clearTimeout(timer); resolve(m); });
  sim.handle({ id, cmd, ...args }, send);
});
// poll until a stop arrives; records per simSignal, decoded ([u64 LE delta from the previous, first from 0][chars])
async function pollUntilStop(acc, maxPolls = 200) {
  for (let i = 0; i < maxPolls; i++) {
    const p = await req('sim.poll', { waitMs: 300 });
    if (p.error) return { error: p.error };
    let off = 0;
    for (const s of p.result.signals) {
      const width = widths.get(s.simSignal); let t = 0;
      const list = acc.get(s.simSignal) || []; acc.set(s.simSignal, list);
      for (let k = 0; k < s.count; k++) { t += Number(p.bin.readBigUInt64LE(off)); list.push([t, p.bin.toString('latin1', off + 8, off + 8 + width)]); off += 8 + width; }
    }
    if (p.result.stop) return p.result;
  }
  return { error: 'no stop' };
}
const widths = new Map();

(async () => {
  const noLog = await req('sim.open', { dir: path.join(scratch, 'nowhere') });
  expect(!!noLog.error && /novas_dump\.log/.test(noLog.error), 'open: a folder without novas_dump.log is refused, naming it');
  const noStub = await req('sim.open', { dir: noStubDir });
  expect(!!noStub.error && noStub.error.includes('-load /home/me/.cache/cmux/simctl/libsimctl_stub.so:simctl_register'), 'open: a simv built without the stub is refused, with the one-line flag');
  expect(!!noStub.needsFlag || /needsFlag/.test(JSON.stringify(noStub)) || noStub.error.includes('simctl_register'), 'open: the refusal carries the flag');
  const before = await req('sim.poll', { waitMs: 10 });
  expect(!!before.error && /no simulation/.test(before.error), 'poll before open: no simulation');

  const o = await req('sim.open', { dir: runDir });
  expect(!o.error && o.result && o.result.period === 10 && o.result.precision === -12 && o.result.t === 0, 'open: ready with time, precision and period');
  expect(o.result && o.result.simv === path.join(runDir, 'simv'), 'open: the simulator resolved against the folder');
  expect(o.result && eq(o.result.args, ['+iters=3', '+ntb_random_seed=7']) && o.result.dumpFile === '/work/elsewhere/dump.fsdb', 'open: run arguments and the logged dump reported');
  const argv = fs.existsSync(workerLog) ? JSON.parse(fs.readFileSync(workerLog, 'utf8')).argv : [];
  const dd = argv.indexOf('--');
  expect(argv[argv.indexOf('--simv') + 1] === path.join(runDir, 'simv') && argv[argv.indexOf('--lib') + 1] === lib, 'worker: given the simulator and the library');
  expect(dd > 0 && eq(argv.slice(dd + 1), ['+iters=3', '+ntb_random_seed=7']), 'worker: run arguments without +fsdb and -l');
  const scr = argv[argv.indexOf('--scratch') + 1] || '';
  expect(scr && !scr.startsWith(runDir) && fs.existsSync(scr) && (fs.statSync(scr).mode & 0o077) === 0, 'worker: a private scratch folder outside the build folder');
  const again = await req('sim.open', { dir: runDir });
  expect(!!again.error && /already/.test(again.error), 'open: a second open while one runs is refused');

  const w = await req('sim.watch', { signals: ['tb.clk', 'tb.cnt', 'tb.nope'] });
  expect(!w.error && eq(w.result.watch, [{ simSignal: 0, width: 1 }, { simSignal: 1, width: 8 }, null]), 'watch: ids and widths, null for an unknown signal');
  (w.result && w.result.watch || []).forEach((x) => x && widths.set(x.simSignal, x.width));

  const r = await req('sim.run', { cycles: 3 }, 1000);
  expect(!r.error && r.result && r.result.started === true, 'run: answered at once (the run goes on)');
  const acc = new Map();
  const st = await pollUntilStop(acc);
  expect(st.stop && st.stop.stopped === 'done' && st.stop.t === 30 && st.running === false, 'poll: the run ends done at t=30');
  expect(eq(acc.get(1), [[0, '00000000'], [5, '00000001'], [15, '00000010'], [25, '00000011']]), 'poll: counter changes, exact times and values');
  expect(eq((acc.get(0) || []).map((x) => x[0]), [0, 5, 10, 15, 20, 25, 30]), 'poll: every clock edge');
  const t0 = Date.now(); const idle = await req('sim.poll', { waitMs: 250 });
  expect(!idle.error && idle.result.signals.length === 0 && !idle.result.stop && Date.now() - t0 >= 200, 'poll: idle waits for waitMs, then answers empty');
  const rd = await req('sim.read', { signals: ['tb.cnt', 'tb.x', 'tb.z', 'tb.nope'] });
  expect(!rd.error && eq(rd.result.values, ['00000011', 'xxxx', 'zz', null]), 'read: 4-state values, null for unknown');

  const u = await req('sim.until', { expr: "tb.cnt == 'd10", maxCycles: 100 });
  expect(!u.error && u.result.started, 'until: started');
  const su = await pollUntilStop(new Map());
  const rd2 = await req('sim.read', { signals: ['tb.cnt'] });
  expect(su.stop && su.stop.stopped === 'until' && rd2.result && rd2.result.values[0] === '00001010', 'until: stops where the counter reaches 10');

  const long = await req('sim.run', { cycles: 1e9 });
  expect(!long.error && long.result.started, 'long run: started');
  const busy = await req('sim.run', { cycles: 1 });
  expect(!!busy.error && /in flight|running/.test(busy.error), 'run while running: refused');
  const sp = await req('sim.stop', {}, 5000);
  expect(!sp.error && typeof sp.result.t === 'number', 'stop: answered with the time');
  const ss = await pollUntilStop(new Map());
  expect(ss.stop && ss.stop.stopped === 'stop', 'poll: the long run ends stopped');

  const uw = await req('sim.unwatch', { simSignals: [0] });
  expect(!uw.error, 'unwatch: ok');
  await req('sim.run', { cycles: 1 });
  const acc2 = new Map(); await pollUntilStop(acc2);
  expect(!acc2.has(0) && acc2.has(1), 'unwatched signals stop streaming');

  // review #2, this side: watch/unwatch churn during a run (a viewer scrolling) while the worker's unwatch lags
  // (its batches still carry the signal for a while): the signal that stays watched streams every change.
  const CH = 100600;   // the fake runs the first 600 cycles in small chunks, so the churn overlaps them
  const churnRun = await req('sim.run', { cycles: CH });
  const accC = new Map(); let pairs = 0, churnErr = null;
  const churn = (async () => {
    while (pairs < 12) {
      const x = await req('sim.watch', { signals: ['tb.dut.state'] });
      const id = x.result && x.result.watch[0] && x.result.watch[0].simSignal;
      if (id === undefined) { churnErr = x.error || 'no id'; return; }
      widths.set(id, 4);
      await new Promise((res) => setTimeout(res, 8));
      const u = await req('sim.unwatch', { simSignals: [id] }); if (u.error) { churnErr = u.error; return; }
      pairs++;
    }
  })();
  const sc = await pollUntilStop(accC); await churn;
  const cr = accC.get(1) || [];
  let gaps = 0; for (let i = 1; i < cr.length; i++) if (parseInt(cr[i][1], 2) !== ((parseInt(cr[i - 1][1], 2) + 1) & 255)) gaps++;
  expect(!churnRun.error && !churnErr && pairs === 12 && sc.stop && sc.stop.stopped === 'done' && cr.length >= CH && gaps === 0,
    `churn during a run: ${pairs} watch/unwatch pairs, the counter kept ${cr.length} of ${CH} changes, ${gaps} gaps${churnErr ? ', ' + churnErr : ''}`);

  // review #7, this side: a run and a stop sent together: the stop ends that run.
  const [rr, rs] = await Promise.all([req('sim.run', { cycles: 1e6 }), req('sim.stop', {})]);
  const rsStop = await pollUntilStop(new Map());
  expect(!rr.error && !rs.error && !rs.result.idle && rsStop.stop && rsStop.stop.stopped === 'stop',
    `run + stop together: the run stops (${JSON.stringify([rr.result || rr.error, rs.result || rs.error, rsStop.stop])})`);

  // review #8, this side: names and expressions that could carry another protocol line are refused here,
  // before they reach the worker.
  for (const [cmd, args] of [
    ['sim.read', { signals: ['tb.cnt\nQ 1'] }], ['sim.read', { signals: ['tb.cnt tb.x'] }],
    ['sim.watch', { signals: ['tb.cnt\r'] }], ['sim.until', { expr: "tb.cnt == 'd3\nQ 1", maxCycles: 1 }],
    ['sim.read', { signals: [42] }],
  ]) {
    const r = await req(cmd, args);
    expect(!!r.error && /whitespace|control|signal name/.test(r.error), `${cmd} ${JSON.stringify(args)} refused here: ${r.error || JSON.stringify(r.result)}`);
  }
  const okRead = await req('sim.read', { signals: ['tb.cnt'] });
  expect(!okRead.error && okRead.result.values[0] !== null, 'an ordinary read still works');

  const bad = await req('sim.frobnicate', {});
  expect(!!bad.error, 'an unknown sim command is refused');
  const deny = await req('sim.force', { signal: 'tb.cnt', value: "'d1" });
  expect(!!deny.error, 'force is not offered yet (not in the page commands)');

  const pid = sim.workerPid();
  const c = await req('sim.close', {});
  expect(!c.error, 'close: ok');
  await new Promise((res) => setTimeout(res, 300));
  let alive = true; try { process.kill(pid, 0); } catch { alive = false; }
  expect(!alive, 'close: the worker is gone');
  const after = await req('sim.poll', { waitMs: 10 });
  expect(!!after.error && /no simulation/.test(after.error), 'poll after close: no simulation');

  process.env.FAKE_REPORT_PERIOD = '0';
  const np = await req('sim.open', { dir: runDir });
  delete process.env.FAKE_REPORT_PERIOD;
  expect(!np.error && np.result.period === 0, 'open without a known clock period');
  const npRun = await req('sim.run', { cycles: 5 });
  expect(!!npRun.error && /clock/.test(npRun.error), 'run by cycles without a period is refused, naming the clock: ' + npRun.error);
  const npTime = await req('sim.run', { time: 20 });
  expect(!npTime.error, 'run by time still works without a period');
  await pollUntilStop(new Map());
  await req('sim.close', {});
  await new Promise((res) => setTimeout(res, 300));

  const o2 = await req('sim.open', { dir: runDir, clock: 'tb.clk' });
  expect(!o2.error, 'reopen after close');
  const argv2 = JSON.parse(fs.readFileSync(workerLog, 'utf8')).argv;
  expect(argv2[argv2.indexOf('--clock') + 1] === 'tb.clk', 'open {clock}: the worker measures that clock');
  const pid2 = sim.workerPid();
  sim.closeAll();
  await new Promise((res) => setTimeout(res, 500));
  let alive2 = true; try { process.kill(pid2, 0); } catch { alive2 = false; }
  expect(!alive2, 'closeAll (the viewer went away): the worker is killed');

  // The helper's shutdown: closeAll, then process.exit at once. Nothing of the simulation's is left behind.
  const child = require('node:child_process').spawnSync(process.execPath, ['-e', `
    const sim = require(${JSON.stringify(path.join(helperDir, 'sim.js'))});
    sim.handle({ id: 1, cmd: 'sim.open', dir: ${JSON.stringify(runDir)} }, (m) => { if (m.id === 1) { sim.closeAll(); process.exit(m.error ? 3 : 0); } });
  `], { env: process.env, timeout: 10000 });
  const argv3 = JSON.parse(fs.readFileSync(workerLog, 'utf8'));
  const scr3 = argv3.argv[argv3.argv.indexOf('--scratch') + 1];
  await new Promise((res) => setTimeout(res, 500));
  let alive3 = true; try { process.kill(argv3.pid, 0); } catch { alive3 = false; }
  expect(child.status === 0 && !alive3, 'a helper that exits right after closeAll leaves no worker (' + child.status + ')');
  expect(!!scr3 && !fs.existsSync(scr3), 'and no scratch folder: ' + scr3);

  const leftovers = fs.readdirSync(scratch).filter((f) => f.startsWith('sim-'));
  expect(leftovers.length === 0, 'every closed simulation removed its scratch folder: ' + leftovers);
  fs.rmSync(scratch, { recursive: true, force: true });
  console.log(failures ? `SIM UNIT CHECKS FAILED (${failures})` : 'SIM UNIT CHECKS PASSED');
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.log('FAIL exception', e && e.stack); process.exit(1); });
