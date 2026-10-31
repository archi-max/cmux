// Adapted from VaporView (https://github.com/Lramseyer/vaporview, GPL-3.0), src/extension_core/fsdb_worker.ts@59107c6.
//
// cmux's FSDB helper: runs next to the dump (on the SSH host) and answers the
// waveform viewer over a single ssh stdio channel. Same addon calls as
// fsdb_worker.ts, with stdio framing instead of Node IPC and the scope/var
// walk done here instead of in the extension host.
//
// Requests are newline-delimited JSON on stdin: {id, cmd, ...}. Replies go to
// fd 3, because Verdi's FsdbReader prints to stdout (fd 1); fsdb-helper.sh maps
// fd 3 to the ssh channel and fd 1 to stderr. A reply is one JSON line,
// followed by `binLength` raw bytes when it has that field.
//   open {file}                     -> {metadata, top}
//   children {scopeOffsetIdx, scopePath} -> {scopes, vars}
//   signals {signalIds, widths}     -> [{signalId, width, count, bytes, min, max}] +
//                                      per signal deflate-raw records [u64 LE delta time][width value chars]
//   close                           -> {}
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const zlib = require('node:zlib');

const addonPath = process.env.FSDB_ADDON || path.join(__dirname, 'fsdb_reader.node');
const OUT = 3;

// Writes all of `data` to the channel. A full pipe (EAGAIN) is waited out;
// any other error means cmux has gone (EPIPE), so the helper exits.
const pause = new Int32Array(new SharedArrayBuffer(4));
function writeAll(data) {
  let off = 0;
  while (off < data.length) {
    try {
      off += fs.writeSync(OUT, data, off, data.length - off);
    } catch (e) {
      if (e.code !== 'EAGAIN') { process.exit(0); }
      Atomics.wait(pause, 0, 0, 5);
    }
  }
}

// Each reply is one JSON line; if it has `binLength`, that many raw bytes follow.
function send(obj, bin) {
  if (bin) { obj.binLength = bin.length; }
  writeAll(Buffer.from(JSON.stringify(obj) + '\n'));
  if (bin) { writeAll(bin); }
}

// Pack value changes as the viewer's record format, [u64 LE delta time][value chars],
// then deflate. Values must all be `width` chars (bit vectors); otherwise null.
function packRecords(valueChanges, width) {
  const rec = 8 + width;
  const buf = Buffer.allocUnsafe(valueChanges.length * rec);
  let prev = 0, off = 0;
  for (const [t, v] of valueChanges) {
    if (v.length !== width) { return null; }
    buf.writeBigUInt64LE(BigInt(t - prev), off);
    buf.write(v, off + 8, 'latin1');
    prev = t; off += rec;
  }
  return zlib.deflateRawSync(buf, { level: 1 });
}

let addon = null;
try {
  addon = require(addonPath);
} catch (e) {
  send({ id: 0, error: 'failed to load FSDB reader: ' + e.message });
  process.exit(1);
}

let openFile = null;

// The reader's other calls dereference its open file without a check.
function requireOpenFile() {
  if (!openFile) { throw new Error('No FSDB file is open.'); }
}

// FSDB names carry the packed range ("i[31:0]"); the viewer wants it separate.
function stripRange(name, width, msb, lsb) {
  const suffix = `[${msb}:${lsb}]`;
  return width > 1 && name.endsWith(suffix) ? name.slice(0, -suffix.length) : name;
}

const handlers = {
  open({ file }) {
    if (openFile) { addon.unload(); openFile = null; }
    addon.openFsdb(String(file));
    openFile = file;
    const metadata = { timeTableLoaded: false, scopeCount: 0, netlistIdCount: 0, signalIdCount: 0,
      timeTableCount: 0, timeEnd: 0, minTimeStep: 1, timeScale: 1, timeUnit: 'ns' };
    addon.readMetadata(
      (scopecount, varcount, timescale, timeunit) => Object.assign(metadata,
        { scopeCount: scopecount, netlistIdCount: varcount, timeScale: timescale, timeUnit: timeunit }),
      (chunksize, timeend) => Object.assign(metadata, { timeEnd: Number(timeend), timeTableLoaded: true }));
    const top = addon.readScopes().filter((s) => !s.name.startsWith('$'));
    return { metadata, top };
  },

  // Child scopes (paged by the reader) plus the scope's own variables.
  children({ scopeOffsetIdx, scopePath }) {
    requireOpenFile();
    const scopes = [];
    let start = 0, remaining = Infinity, guard = 256;
    while (remaining > 0 && guard-- > 0) {
      const r = addon.getScopeChildren(scopeOffsetIdx, start);
      scopes.push(...r.scopes);
      remaining = r.remainingItems;
      start += r.totalReturned;
      if (!r.totalReturned) { break; }
    }
    const vars = [];
    addon.readVars(scopePath, scopeOffsetIdx,
      (name, type, encoding, varPath, netlistId, signalId, width, msb, lsb) =>
        vars.push({ name: stripRange(name, width, msb, lsb), type, encoding, netlistId, signalId, width, msb, lsb }),
      () => {}, () => {}, () => {}, () => {});
    return { scopes: scopes.filter((s) => !s.name.startsWith('$')), vars };
  },

  // Binary reply: per signal a header entry plus a deflated record slice.
  signals({ signalIds, widths }) {
    requireOpenFile();
    addon.loadSignals(signalIds);
    const out = [], parts = [];
    signalIds.forEach((signalId, k) => {
      // Fast path: the addon packs records in C++ (no per-change JS objects).
      // It throws for a signal the open file does not have, and gives undefined
      // only for real/float signals, which take the getValueChanges path.
      const raw = addon.getValueChangesPacked(signalId);
      if (raw) {
        const width = raw.bitSize;
        const packed = zlib.deflateRawSync(raw, { level: 1 });
        out.push({ signalId, width, count: raw.length / (8 + width), bytes: packed.length, min: 0, max: 0 });
        parts.push(packed);
      } else {
        const d = addon.getValueChanges(signalId);
        const packed = widths ? packRecords(d.valueChanges, widths[k]) : null;
        if (packed) {
          out.push({ signalId, width: widths[k], count: d.valueChanges.length, bytes: packed.length, min: d.min, max: d.max });
          parts.push(packed);
        } else {
          out.push({ signalId, valueChanges: d.valueChanges, min: d.min, max: d.max });
        }
      }
      addon.unloadSignal(signalId);
    });
    return { result: out, bin: parts.length ? Buffer.concat(parts) : null };
  },

  close() {
    if (openFile) { addon.unload(); openFile = null; }
    return {};
  },
};

send({ id: 0, ready: true, protocol: 1, pid: process.pid });

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) { return; }
  let req;
  try { req = JSON.parse(line); } catch (e) { send({ id: -1, error: 'bad json' }); return; }
  const t0 = process.hrtime.bigint();
  try {
    const fn = Object.hasOwn(handlers, req.cmd) ? handlers[req.cmd] : null;
    if (!fn) { throw new Error('unknown command ' + req.cmd); }
    const r = fn(req);
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    if (r && r.bin !== undefined) { send({ id: req.id, result: r.result, ms }, r.bin); } else { send({ id: req.id, result: r, ms }); }
  } catch (e) {
    send({ id: req.id, error: String(e && e.message || e) });
  }
}).on('close', () => {
  if (openFile) { addon.unload(); }
  process.exit(0);
});
