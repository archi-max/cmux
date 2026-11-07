// run.sh sim: the FSDB helper for the live-simulation checks. sim.* requests go to the real
// fsdb-helper-v2/sim.js (with fake-worker.cjs as its worker, from the environment); everything else goes
// to windowed/mock-helper-v2.cjs, whose `open` is pointed at SIM_SYNTH (a synthetic dump) whatever the file.
// Replies from both are written to fd 3 a whole frame at a time.
// Usage: node mock-helper-sim.cjs <sim.js> <mock-helper-v2.cjs> [mock args...]
'use strict';
const fs = require('node:fs');
const { spawn } = require('node:child_process');
const [simPath, mockPath, ...mockArgs] = process.argv.slice(2);
const sim = require(simPath);
const OUT = 3;
const writeAll = (buf) => { let o = 0; while (o < buf.length) { try { o += fs.writeSync(OUT, buf, o); } catch (e) { if (e.code !== 'EAGAIN') throw e; } } };
const send = (obj, bin) => { if (bin) obj.binLength = bin.length; writeAll(Buffer.concat([Buffer.from(JSON.stringify(obj) + '\n'), bin || Buffer.alloc(0)])); };
const child = spawn(process.execPath, [mockPath, ...mockArgs], { stdio: ['pipe', 'inherit', 'inherit', 'pipe'] });
let buf = Buffer.alloc(0), need = -1, head = null;
child.stdio[3].on('data', (d) => {
  buf = buf.length ? Buffer.concat([buf, d]) : d;
  for (;;) {
    if (head) { if (buf.length < need) return; writeAll(Buffer.concat([head, buf.subarray(0, need)])); buf = buf.subarray(need); head = null; continue; }
    const nl = buf.indexOf(10); if (nl < 0) return;
    const line = buf.subarray(0, nl + 1); buf = buf.subarray(nl + 1);
    let n = 0; try { n = JSON.parse(line.toString()).binLength || 0; } catch { /* pass through */ }
    if (n) { head = Buffer.from(line); need = n; continue; }
    writeAll(line);
  }
});
child.on('exit', () => { sim.closeAll(); setTimeout(() => process.exit(0), 100); });
require('node:readline').createInterface({ input: process.stdin }).on('line', (line) => {
  let req; try { req = JSON.parse(line); } catch { child.stdin.write(line + '\n'); return; }
  if (typeof req.cmd === 'string' && req.cmd.startsWith('sim.')) { sim.handle(req, send); return; }
  if (req.cmd === 'open' && process.env.SIM_SYNTH) req.file = process.env.SIM_SYNTH;
  child.stdin.write(JSON.stringify(req) + '\n');
}).on('close', () => { sim.closeAll(); child.stdin.end(); });
