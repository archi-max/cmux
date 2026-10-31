// Adapted from VaporView (https://github.com/Lramseyer/vaporview, GPL-3.0), src/extension_core/worker.ts@59107c6 and src/extension_core/wasm_handler.ts@59107c6.
//
// Runs VaporView's filehandler.wasm (wellen) in a Worker. Hand-written
// canonical-ABI glue for the filehandler.wit world (strings, u32 lists, u8
// lists) replaces @vscode/wasm-component-model and the wit2ts bindings.
//
// wellen reads the file only through fsreadptr(fd, offset, ptr, len), a
// synchronous positional read into wasm memory. Each call becomes a
// synchronous XHR with a Range header (allowed in Workers) that cmux serves
// from the file on disk, so FST loads lazily and nothing loads the whole file.

let ex, mem;
const td = new TextDecoder();
const te = new TextEncoder();
const u8 = () => new Uint8Array(mem.buffer);
const dv = () => new DataView(mem.buffer);
const str = (p, l) => td.decode(u8().subarray(p, p + l));

let file = { url: null, size: 0 };

function readRange(offset, length) {
  const xhr = new XMLHttpRequest();
  xhr.open('GET', file.url, false);
  xhr.responseType = 'arraybuffer';
  xhr.setRequestHeader('Range', `bytes=${offset}-${offset + length - 1}`);
  xhr.send();
  if (xhr.status !== 206 && xhr.status !== 200) {
    throw new Error(`read failed at ${offset} (HTTP ${xhr.status})`);
  }
  return new Uint8Array(xhr.response);
}

const post = (msg) => self.postMessage({ type: 'toWebview', msg });

// cmux: while getsignalchanges runs, the signal data wellen sends is kept here
// for the page (the waveform debugger reads its clock) instead of going to the
// viewer frame, which has not asked for it.
let capture = null;

function captureSignal(signalId) {
  capture = { signalId, json: [], lz4: [], width: 0, size: 0 };
  try { ex.getsignaldata(...lowerU32List([signalId])); return capture; } finally { capture = null; }
}

let meta;
function resetMeta() {
  meta = { top: [], metadata: { timeTableLoaded: false, scopeCount: 0, netlistIdCount: 0, signalIdCount: 0,
    timeTableCount: 0, timeEnd: 0, minTimeStep: 1, timeScale: 1, timeUnit: 'ns' } };
}

const imports = {
  $root: {
    log: (p, l) => console.log(str(p, l)),
    outputlog: (p, l) => self.postMessage({ type: 'log', text: str(p, l) }),
    getsize: (_fd) => BigInt(file.size),
    fsreadptr: (_fd, offset, ptr, length) => {
      const off = Number(offset);
      const n = Math.min(length, file.size - off);
      if (n <= 0) { return 0; }
      const bytes = readRange(off, n);
      u8().set(bytes, ptr);
      return bytes.length;
    },
    setscopetop: (np, nl, id, tp, tl) => meta.top.push({ kind: 'scope', name: str(np, nl), id, type: str(tp, tl) }),
    setvartop: (np, nl, id, signalid, tp, tl, ep, el, width, msb, lsb, enp, enl) =>
      meta.top.push({ kind: 'var', name: str(np, nl), netlistId: id, signalId: signalid, type: str(tp, tl),
        encoding: str(ep, el).split('(')[0], width, msb, lsb, enumType: str(enp, enl) }),
    setmetadata: (scopecount, varcount, timescale, up, ul) => Object.assign(meta.metadata,
      { scopeCount: scopecount, netlistIdCount: varcount, timeScale: timescale, timeUnit: str(up, ul) }),
    setchunksize: (chunksize, timeend, ttlen) => Object.assign(meta.metadata,
      { minTimeStep: Number(chunksize), timeEnd: Number(timeend), timeTableCount: Number(ttlen), timeTableLoaded: true }),
    sendtransitiondatachunk: (signalId, totalChunks, chunkNum, min, max, dp, dl) =>
      (capture && capture.signalId === signalId) ? capture.json.push(str(dp, dl)) : post({ command: 'update-waveform-chunk', signalId, transitionDataChunk: str(dp, dl), totalChunks, chunkNum, min, max }),
    sendenumdata: (np, nl, totalChunks, chunkNum, dp, dl) =>
      post({ command: 'update-enum-chunk', enumName: str(np, nl), enumDataChunk: str(dp, dl), totalChunks, chunkNum }),
    sendcompressedtransitiondata: (signalId, signalWidth, totalChunks, chunkNum, min, max, dp, dl, originalSize) =>
      (capture && capture.signalId === signalId)
        ? (capture.lz4.push(u8().slice(dp, dp + dl)), capture.width = signalWidth, capture.size = originalSize) : post({ command: 'update-waveform-chunk-compressed', signalId, signalWidth,
        compressedDataChunk: Array.from(u8().subarray(dp, dp + dl)), totalChunks, chunkNum, min, max, originalSize }),
  },
};

// Lowering host values into guest memory via cabi_realloc.
function lowerString(s) {
  const b = te.encode(s);
  const p = ex.cabi_realloc(0, 0, 1, b.length);
  u8().set(b, p);
  return [p, b.length];
}
function lowerU32List(list) {
  const p = ex.cabi_realloc(0, 0, 4, list.length * 4);
  const d = dv();
  list.forEach((v, i) => d.setUint32(p + i * 4, v, true));
  return [p, list.length];
}
// A string result is a pointer to (ptr, len); free it with cabi_post_<name>.
function liftString(name, retptr) {
  const d = dv();
  const s = str(d.getUint32(retptr, true), d.getUint32(retptr + 4, true));
  ex['cabi_post_' + name](retptr);
  return s;
}

const api = {
  async init({ wasmUrl }) {
    const { instance } = await WebAssembly.instantiateStreaming(fetch(wasmUrl), imports);
    ex = instance.exports; mem = ex.memory;
    return 'ok';
  },
  // Same buffer choices as VaporView's wasm_handler.ts for files it does not load
  // statically: 8 KB for FST block reads, 60 KB for streaming VCD/GHW.
  loadfile({ url, size, format }) {
    resetMeta();
    file = { url, size };
    const bufferSize = format === 'fst' ? 8192 : 60 * 1024;
    ex.loadfile(BigInt(size), 0, 0, bufferSize);
    return meta;
  },
  readbody() {
    ex.readbody();
    return { metadata: meta.metadata };
  },
  getchildren({ id, startIndex }) { return JSON.parse(liftString('getchildren', ex.getchildren(id, startIndex))); },
  getsignaldata({ signalIds }) { ex.getsignaldata(...lowerU32List(signalIds)); return 'ok'; },
  // cmux: one signal's value changes as [[time, value], ...], kept in the page.
  getsignalchanges({ signalId }) {
    const c = captureSignal(signalId);
    if (c.lz4.length) { return decodeRecords(lz4Frame(concat(c.lz4), c.size), c.width); }
    return c.json.length ? JSON.parse(c.json.join('')) : [];
  },
  // cmux: the times a 1-bit signal rises (to 1 from 0, x or z) as a Float64Array,
  // found in wellen's data without building a value per change (a clock can have millions).
  getsignalposedges({ signalId, maxEdges }) {
    const c = captureSignal(signalId);
    const limit = Number(maxEdges) || Infinity;
    let edges = new Float64Array(1024);
    let n = 0;
    const add = (time) => {
      if (n >= limit) { throw new Error('too many clock edges'); }
      if (n === edges.length) { const grown = new Float64Array(edges.length * 2); grown.set(edges); edges = grown; }
      edges[n++] = time;
    };
    if (c.lz4.length) {
      const raw = lz4Frame(concat(c.lz4), c.size);
      const rec = 8 + c.width;
      const view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
      let time = 0;
      let previous = -1;
      for (let i = 0; i + rec <= raw.length; i += rec) {
        time += view.getUint32(i, true) + view.getUint32(i + 4, true) * 4294967296;
        const value = c.width === 1 ? raw[i + 8] : -2;
        if (value === 0x31 && previous !== -1 && previous !== 0x31) { add(time); }
        previous = value;
      }
    } else if (c.json.length) {
      let previous = null;
      for (const [time, value] of JSON.parse(c.json.join(''))) {
        const v = String(value);
        if (v === '1' && previous !== null && previous !== '1') { add(Number(time)); }
        previous = v;
      }
    }
    return edges.slice(0, n);
  },
  getenumdata({ netlistIds }) { ex.getenumdata(...lowerU32List(netlistIds)); return 'ok'; },
  getparametervalues({ signalIds }) { return JSON.parse(liftString('getparametervalues', ex.getparametervalues(...lowerU32List(signalIds)))); },
  getvaluesattime({ time, paths }) { return JSON.parse(liftString('getvaluesattime', ex.getvaluesattime(BigInt(time), ...lowerString(paths)))); },
  searchnetlist({ query, scopeId }) { return JSON.parse(liftString('searchnetlist', ex.searchnetlist(...lowerString(query), scopeId))); },
  unload() { ex.unload(); return 'ok'; },
};

// ---- cmux: the LZ4 frame wellen packs big signals in (lz4_flex FrameEncoder) ----
// Written from the LZ4 frame and block format descriptions (github.com/lz4/lz4,
// doc/lz4_Frame_format.md and doc/lz4_Block_format.md); checksums are not verified.
function concat(parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

function lz4Frame(src, sizeHint) {
  const view = new DataView(src.buffer, src.byteOffset, src.byteLength);
  if (src.length < 7 || view.getUint32(0, true) !== 0x184D2204) { throw new Error('not an LZ4 frame'); }
  const flags = src[4];
  let at = 6 + ((flags & 0x08) ? 8 : 0) + ((flags & 0x01) ? 4 : 0) + 1;
  const blockChecksum = (flags & 0x10) !== 0;
  let out = new Uint8Array(Math.max(sizeHint || 0, 1024));
  let n = 0;
  const room = (extra) => {
    if (n + extra <= out.length) { return; }
    const grown = new Uint8Array(Math.max(out.length * 2, n + extra));
    grown.set(out.subarray(0, n));
    out = grown;
  };
  for (;;) {
    if (at + 4 > src.length) { throw new Error('truncated LZ4 frame'); }
    const word = view.getUint32(at, true);
    at += 4;
    if (word === 0) { break; }
    const size = word & 0x7fffffff;
    const end = at + size;
    if (end > src.length) { throw new Error('truncated LZ4 block'); }
    if (word & 0x80000000) {
      room(size);
      out.set(src.subarray(at, end), n);
      n += size;
    } else {
      let i = at;
      while (i < end) {
        const token = src[i++];
        let literals = token >> 4;
        if (literals === 15) { let b; do { b = src[i++]; literals += b; } while (b === 255); }
        room(literals);
        out.set(src.subarray(i, i + literals), n);
        n += literals;
        i += literals;
        if (i >= end) { break; }
        const offset = src[i] | (src[i + 1] << 8);
        i += 2;
        let length = token & 15;
        if (length === 15) { let b; do { b = src[i++]; length += b; } while (b === 255); }
        length += 4;
        if (offset === 0 || offset > n) { throw new Error('bad LZ4 match offset'); }
        room(length);
        // A match may overlap what it copies, so byte by byte.
        for (let k = 0, from = n - offset; k < length; k++) { out[n++] = out[from + k]; }
      }
    }
    at = end + (blockChecksum ? 4 : 0);
  }
  return out.subarray(0, n);
}

// [u64 LE delta time][width value chars] records -> [[time, value], ...].
function decodeRecords(raw, width) {
  const rec = 8 + width;
  const view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
  const out = [];
  let time = 0;
  for (let i = 0; i + rec <= raw.length; i += rec) {
    time += view.getUint32(i, true) + view.getUint32(i + 4, true) * 4294967296;
    out.push([time, td.decode(raw.subarray(i + 8, i + rec))]);
  }
  return out;
}

// init is the one async call: the calls posted behind it wait for the wasm.
let initialized = null;
self.onmessage = async (e) => {
  const { id, method, args } = e.data;
  try {
    let result;
    if (method === 'init') {
      initialized = api.init(args || {});
      result = await initialized;
    } else {
      if (initialized) { await initialized; }
      result = await api[method](args || {});
    }
    self.postMessage({ type: 'result', id, result });
  } catch (err) {
    self.postMessage({ type: 'result', id, error: String((err && err.message) || err) });
  }
};
