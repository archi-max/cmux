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
      post({ command: 'update-waveform-chunk', signalId, transitionDataChunk: str(dp, dl), totalChunks, chunkNum, min, max }),
    sendenumdata: (np, nl, totalChunks, chunkNum, dp, dl) =>
      post({ command: 'update-enum-chunk', enumName: str(np, nl), enumDataChunk: str(dp, dl), totalChunks, chunkNum }),
    sendcompressedtransitiondata: (signalId, signalWidth, totalChunks, chunkNum, min, max, dp, dl, originalSize) =>
      post({ command: 'update-waveform-chunk-compressed', signalId, signalWidth,
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
  getenumdata({ netlistIds }) { ex.getenumdata(...lowerU32List(netlistIds)); return 'ok'; },
  getparametervalues({ signalIds }) { return JSON.parse(liftString('getparametervalues', ex.getparametervalues(...lowerU32List(signalIds)))); },
  searchnetlist({ query, scopeId }) { return JSON.parse(liftString('searchnetlist', ex.searchnetlist(...lowerString(query), scopeId))); },
  unload() { ex.unload(); return 'ok'; },
};

self.onmessage = async (e) => {
  const { id, method, args } = e.data;
  try {
    self.postMessage({ type: 'result', id, result: await api[method](args || {}) });
  } catch (err) {
    self.postMessage({ type: 'result', id, error: String((err && err.message) || err) });
  }
};
