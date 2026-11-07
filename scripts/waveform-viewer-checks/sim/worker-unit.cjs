// run.sh sim-worker: fsdb-helper-v2/simctl/sim-worker.js itself (not sim.js, not the fake worker), driven over its
// JSON-lines protocol, with fake-simv.cjs as the simulator and the library's side on fd 3/4. No simulator.
// Usage: node worker-unit.cjs <fsdb-helper-v2 folder> <scratch>
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const [helperDir, scratchArg] = process.argv.slice(2);
const scratch = fs.mkdtempSync(path.join(scratchArg || require('node:os').tmpdir(), 'worker-unit-'));
const WORKER = path.join(helperDir, 'simctl/sim-worker.js');
const SIMV = path.join(__dirname, 'fake-simv.cjs');
let failures = 0, n = 0;
const expect = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failures++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function start(extra = [], env = {}) {
  const run = `w${++n}`, log = path.join(scratch, `${run}.lib.log`), cwd = path.join(scratch, `${run}.cwd`);
  fs.mkdirSync(cwd);
  const p = spawn(process.execPath, [WORKER, '--simv', SIMV, '--lib', '/nonexistent/libsimctl.so', '--scratch', scratch, '--run', run,
    '--cwd', cwd, '--vmem-mb', '0', ...extra, '--'], { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, FAKE_SIMV_LOG: log, ...env } });
  const w = { p, log, replies: new Map(), events: [], nextId: 1, stderr: '', exited: null };
  w.exitP = new Promise((res) => p.on('exit', (code, sig) => { w.exited = { code, sig }; res(w.exited); }));
  p.stderr.on('data', (d) => { w.stderr += d; });
  let buf = Buffer.alloc(0), bin = 0;
  p.stdout.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
      if (bin) { if (buf.length < bin) return; buf = buf.subarray(bin); bin = 0; continue; }
      const k = buf.indexOf(10); if (k < 0) return;
      const m = JSON.parse(buf.subarray(0, k).toString()); buf = buf.subarray(k + 1);
      if (m.binLength) bin = m.binLength;
      if (m.id === 0) { w.events.push(m); continue; }
      const l = w.replies.get(m.id) || []; l.push({ ...m, at: Date.now() }); w.replies.set(m.id, l);
    }
  });
  w.ready = new Promise((res) => { const iv = setInterval(() => { const e = w.events.find((x) => x.event === 'ready' || x.event === 'setupError'); if (e || w.exited) { clearInterval(iv); res(e); } }, 10); });
  w.send = (o) => { const id = w.nextId++; w.p.stdin.write(JSON.stringify({ id, ...o }) + '\n'); return { id, sent: Date.now() }; };
  w.reply = async (id, ms = 8000) => { const end = Date.now() + ms; while (Date.now() < end) { const l = w.replies.get(id); if (l) return l[0]; await sleep(5); } return null; };
  w.libLines = () => (fs.existsSync(log) ? fs.readFileSync(log, 'utf8').split('\n').filter(Boolean) : []);
  w.quit = async () => { w.send({ cmd: 'quit' }); await Promise.race([w.exitP, sleep(5000)]); if (!w.exited) w.p.kill('SIGKILL'); };
  return w;
}

(async () => {
  // GitHub #3: a run, checkpoint or until refused while a run is in flight never reaches the library, and each
  // request gets exactly one terminal reply.
  {
    const w = start(['--period', '10'], { FAKE_RUN_MS: '800' }); await w.ready;
    const a = w.send({ cmd: 'run', cycles: 100 }); await sleep(50);
    const b = w.send({ cmd: 'run', cycles: 7 }); const c = w.send({ cmd: 'checkpoint' }); const u = w.send({ cmd: 'until', expr: "tb.cnt == 'd3", maxCycles: 5 });
    const ra = await w.reply(a.id); await sleep(300);
    const rs = [b, c, u].map((x) => w.replies.get(x.id) || []);
    const lines = w.libLines();
    expect(ra && ra.result && ra.result.stopped === 'done' && ra.result.t === 1000, `#3: the first run completes at t=1000: ${JSON.stringify(ra)}`);
    expect(rs.every((l) => l.length === 1 && !!l[0].error), `#3: run, checkpoint and until in flight: one error reply each: ${JSON.stringify(rs.map((l) => l.map((x) => x.error || x.result)))}`);
    expect(lines.filter((l) => /^R /.test(l)).length === 1 && !lines.some((l) => /^[PU] /.test(l)), `#3: only the first run reached the library: ${lines.filter((l) => /^[RUP] /.test(l)).join(' | ')}`);
    await w.quit();
  }
  // GitHub #2: cycles need a positive period; nothing reaches the library otherwise; time advances exactly.
  {
    const w = start([], {}); await w.ready;
    const r = await w.reply(w.send({ cmd: 'run', cycles: 100 }).id);
    const lines = w.libLines();
    expect(!!r.error && /period/.test(r.error) && !lines.some((l) => /^R /.test(l)), `#2: no period: run {cycles} refused before the library: ${r.error}`);
    const tr = await w.reply(w.send({ cmd: 'run', time: 30 }).id);
    expect(w.libLines().some((l) => / 30$/.test(l) && /^R /.test(l)) && tr.result && tr.result.t === 30, `#2: run {time: 30} runs 30 ticks: ${JSON.stringify(tr.result || tr.error)}`);
    await w.quit();
    const w2 = start(['--period', '10'], { FAKE_RUN_MS: '50' }); await w2.ready;
    const ok = await w2.reply(w2.send({ cmd: 'run', cycles: 3 }).id);
    const bad = [];
    for (const c of [0, 1.5, -1, 'x']) bad.push(await w2.reply(w2.send({ cmd: 'run', cycles: c }).id));
    expect(ok.result && ok.result.t === 30 && w2.libLines().filter((l) => /^R /.test(l)).length === 1 && bad.every((x) => !!x.error), `#2: with period 10, 3 cycles run 30 ticks; 0/1.5/-1/'x' refused: ${ok.result && ok.result.t}, ${bad.map((x) => x.error).join(' | ')}`);
    await w2.quit();
  }
  // Review ed0057f finding 2: a stop sent behind a write during a run reaches the run at once.
  {
    const w = start(['--period', '10'], { FAKE_RUN_MS: '3000' }); await w.ready;
    const a = w.send({ cmd: 'run', cycles: 100 }); await sleep(50);
    const d = w.send({ cmd: 'deposit', signal: 'tb.cnt', value: "'h5" }); await sleep(100);
    const s = w.send({ cmd: 'stop' });
    const rs = await w.reply(s.id, 5000), ra = await w.reply(a.id, 5000), rd = await w.reply(d.id, 5000);
    expect(!!rs && rs.at - s.sent < 500 && ra && ra.result && ra.result.stopped === 'stop', `a stop behind a write during a run is delivered at once: ${rs ? rs.at - s.sent : '?'} ms, run ${JSON.stringify(ra)}`);
    expect(!!rd && (!!rd.error || rd.at - d.sent < 500), `the write during the run is refused (or done) at once, not held to the run's end: ${rd ? rd.at - d.sent : '?'} ms ${JSON.stringify(rd && (rd.error || rd.result))}`);
    await w.quit();
  }
  // Item 7: a run and a stop in one chunk: the stop ends that run.
  {
    const w = start(['--period', '10'], { FAKE_RUN_MS: '3000' }); await w.ready;
    const id1 = w.nextId++, id2 = w.nextId++; const t0 = Date.now();
    w.p.stdin.write(JSON.stringify({ id: id1, cmd: 'run', cycles: 100 }) + '\n' + JSON.stringify({ id: id2, cmd: 'stop' }) + '\n');
    const r1 = await w.reply(id1, 5000), r2 = await w.reply(id2, 5000);
    expect(r1 && r1.result && r1.result.stopped === 'stop' && r2 && r2.result && !r2.result.idle && r1.at - t0 < 1000, `run + stop in one chunk: the run stops (${JSON.stringify([r1, r2])})`);
    await w.quit();
  }
  // GitHub #10, the worker's side: a read during a run is answered while the run goes on.
  {
    const w = start(['--period', '10'], { FAKE_RUN_MS: '1500' }); await w.ready;
    const a = w.send({ cmd: 'run', cycles: 100 }); await sleep(100);
    const g = w.send({ cmd: 'read', signals: ['tb.cnt'] });
    const rg = await w.reply(g.id), ra = await w.reply(a.id);
    expect(rg && rg.result && rg.at - g.sent < 300 && ra && rg.at < ra.at, `#10: a read during a run is answered before its end: ${rg ? rg.at - g.sent : '?'} ms`);
    await w.quit();
  }
  // Review low 8: widths of unwatched signals are dropped once no record of theirs can still come.
  {
    const w = start(['--period', '10'], { FAKE_RUN_MS: '600' }); await w.ready;
    const wa = await w.reply(w.send({ cmd: 'watch', signals: ['tb.cnt'] }).id);
    const wid = wa.result.watch[0].signalId;
    await w.reply(w.send({ cmd: 'unwatch', signalIds: [wid] }).id);
    const st1 = await w.reply(w.send({ cmd: 'stats' }).id);
    const wb = await w.reply(w.send({ cmd: 'watch', signals: ['tb.cnt'] }).id);
    const a = w.send({ cmd: 'run', cycles: 10 }); await sleep(50);
    await w.reply(w.send({ cmd: 'unwatch', signalIds: [wb.result.watch[0].signalId] }).id);
    const st2 = await w.reply(w.send({ cmd: 'stats' }).id);
    await w.reply(a.id);
    const st3 = await w.reply(w.send({ cmd: 'stats' }).id);
    const k = (x) => x && x.result ? x.result.unwatchedKept : undefined;
    expect(k(st1) === 0 && k(st2) === 1 && k(st3) === 0, `unwatched widths: dropped when idle (${k(st1)}), kept during the run (${k(st2)}), dropped at its end (${k(st3)})`);
    await w.quit();
  }
  // Review low 9: the parent goes away (stdout EPIPE): the worker quits cleanly, its simulation with it.
  {
    const w = start(['--period', '10'], {}); await w.ready;
    w.p.stdout.destroy();
    for (let i = 0; i < 5; i++) { try { w.send({ cmd: 'time' }); } catch { /* gone */ } await sleep(50); }
    const ex = await Promise.race([w.exitP, sleep(5000).then(() => null)]);
    expect(!!ex && ex.code === 0 && !/EPIPE/.test(w.stderr), `stdout EPIPE: a clean exit (${JSON.stringify(ex)}), no crash: ${w.stderr.slice(0, 200)}`);
    if (!ex) w.p.kill('SIGKILL');
  }
  fs.rmSync(scratch, { recursive: true, force: true });
  console.log(failures ? `WORKER UNIT CHECKS FAILED (${failures})` : 'WORKER UNIT CHECKS PASSED');
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.log('FAIL exception', e && e.stack); process.exit(1); });
