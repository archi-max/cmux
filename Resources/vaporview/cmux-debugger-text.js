// Text breakpoints for cmux's waveform debugger (written for cmux; design: status/asm-breakpoints-
// design.md §7): stop where signal S, shown in viewer format F, takes a value whose text matches P
// (`jal ra`, `csrw mtvec`). cmux-debugger.js owns the list, the search and the landing; this file
// gives it a text breakpoint's hit times, its label and its menu items.
//
// A hit is every change whose new value's text matches (the dump's first value counts when it does).
// Each distinct value is formatted and judged once (cmux-textmatch.js, the viewer's own formatters
// and search rule), in a Web Worker with a watchdog, so a pattern that backtracks without end can't
// freeze the viewer: past WATCHDOG_MS for one batch the worker is stopped and the breakpoint says
// why. Verdicts are memoized per signal and spec (LRU 16 signals x 32 specs).
//
// window.cmuxWaveform.debuggerText:
//   spec(item, width?) -> { spec } | { error }   a text breakpoint's fields, checked
//   times(bp, entry) -> Promise<Float64Array | null>   entry: { changes: [[time, bits]], width }
//   verdicts(memoKey, spec, bitsList, warn) -> Promise<Map bits -> bool | null>   (commit breakpoints use it)
//   label(bp) -> string                         'top.inst ~ /jal ra/ (RISC-V)'
//   formatOf(netlistId) -> the row's display format when it can be a text format, else 'hexadecimal'
(function () {
  const waveform = window.cmuxWaveform;
  const S = () => waveform.strings || {};
  const T = window.cmuxTextMatch;
  const WATCHDOG_MS = 2000;
  const BATCH = 50000;
  const MAX_DISTINCT = 4000000;
  const MEMO_SIGNALS = 16;
  const MEMO_SPECS = 32;
  function format(template, ...args) {
    let i = 0;
    return String(template || '').replace(/%(\d+\$)?@/g, (_, n) => String(args[n ? parseInt(n, 10) - 1 : i++] ?? ''));
  }

  // The fields a text breakpoint keeps (and cmux saves): format, pattern, caseSensitive,
  // anyRegisterNames (RISC-V formats; default on), aliasTable (+ the alias file's text, given by
  // the page that loaded it, never saved here).
  function spec(item, aliasText) {
    const q = item || {};
    const s = {
      format: String(q.format || 'hexadecimal'),
      pattern: String(q.pattern === undefined || q.pattern === null ? '' : q.pattern),
      caseSensitive: !!q.caseSensitive,
      anyRegisterNames: q.anyRegisterNames !== false,
    };
    if (s.format.startsWith('alias:')) {
      const text = aliasText !== undefined ? aliasText : (waveform.valueAliasText ? waveform.valueAliasText(s.format.slice(6)) : undefined);
      if (typeof text === 'string') { s.alias = { text, table: s.format.slice(6) }; }
    }
    const error = T.check(s);
    return error ? { error, spec: s } : { spec: s };
  }

  function formatName(id) {
    const s = S();
    if (id.startsWith('alias:')) { return format(s.debuggerTextFormatAlias, id.slice(6)); }
    return s['debuggerTextFormat_' + id] || id;
  }

  const label = (bp) => format(S().debuggerBreakpointText, bp.path.join('.'), bp.pattern, formatName(bp.format));

  function errorText(error) {
    const s = S();
    return { format: s.debuggerTextBadFormat, pattern: s.debuggerTextNoPattern, patternTooLong: format(s.debuggerTextPatternTooLong, T.MAX_PATTERN),
      alias: s.debuggerTextNoAlias, slow: s.debuggerTextTooSlow, tooManyValues: s.debuggerTextTooManyValues }[error] || error;
  }

  // The row's format when a text breakpoint can use it (RISC-V, alias, ASCII, the radixes).
  function formatOf(netlistId) {
    const shown = waveform.host.shownFormats ? waveform.host.shownFormats().get(netlistId) : undefined;
    return shown && T.isTextFormat(shown) ? shown : 'hexadecimal';
  }

  // ---- judging, in a worker with a watchdog (on this thread when there is no worker) ----
  let worker = null;
  let workerBroken = false;
  let nextJob = 1;
  const pending = new Map();  // id -> { resolve, timer }

  function startWorker() {
    if (worker || workerBroken) { return worker; }
    try {
      worker = new Worker('cmux-text-worker.js');
    } catch (error) {
      workerBroken = true;
      return null;
    }
    worker.onmessage = (e) => {
      const job = pending.get(e.data.id);
      if (!job) { return; }
      pending.delete(e.data.id);
      clearTimeout(job.timer);
      job.resolve(e.data.error ? { error: e.data.error } : { mask: e.data.mask });
    };
    worker.onerror = () => { stopWorker('error'); workerBroken = true; };
    return worker;
  }

  // A stuck worker is stopped; every job it had fails (each breakpoint says why).
  function stopWorker(why) {
    if (worker) { worker.terminate(); }
    worker = null;
    for (const [id, job] of pending) { clearTimeout(job.timer); job.resolve({ error: why }); pending.delete(id); }
  }

  function judgeBatch(s, values) {
    const w = startWorker();
    if (!w) {
      try { return Promise.resolve({ mask: T.judge(s, values) }); } catch (error) { return Promise.resolve({ error: String(error) }); }
    }
    const id = nextJob++;
    return new Promise((resolve) => {
      const timer = setTimeout(() => stopWorker('slow'), waveform.debuggerTextWatchdogMs || WATCHDOG_MS);
      pending.set(id, { resolve, timer });
      w.postMessage({ id, spec: s, values });
    });
  }

  // signal key -> Map(spec key -> { values: Map bits -> verdict }) (LRU both ways).
  const memo = new Map();
  function memoFor(signalKey, specKey) {
    let bySpec = memo.get(signalKey);
    if (bySpec) { memo.delete(signalKey); } else { bySpec = new Map(); }
    memo.set(signalKey, bySpec);
    while (memo.size > MEMO_SIGNALS) { memo.delete(memo.keys().next().value); }
    let m = bySpec.get(specKey);
    if (m) { bySpec.delete(specKey); } else { m = new Map(); }
    bySpec.set(specKey, m);
    while (bySpec.size > MEMO_SPECS) { bySpec.delete(bySpec.keys().next().value); }
    return m;
  }

  const bitsOf = (value, width) => {
    const s = String(value).toLowerCase();
    if (s.length >= width) { return s.slice(s.length - width); }
    const pad = s[0] === 'x' || s[0] === 'z' ? s[0] : '0';
    return pad.repeat(width - s.length) + s;
  };

  // The verdicts (bits -> matched) for `values` under `s`, memoized under `memoKey`; null after
  // warn(why) (too many values, too slow, a worker error).
  async function verdicts(memoKey, s, values, warn) {
    const memo = memoFor(memoKey, JSON.stringify([s.format, s.pattern, s.caseSensitive, s.anyRegisterNames, s.alias ? s.alias.text : null]));
    const unknown = [];
    const seen = new Set();
    for (const b of values) {
      if (!memo.has(b) && !seen.has(b)) { seen.add(b); unknown.push(b); }
    }
    if (unknown.length + memo.size > MAX_DISTINCT) { warn(errorText('tooManyValues')); return null; }
    for (let k = 0; k < unknown.length; k += BATCH) {
      const batch = unknown.slice(k, k + BATCH);
      const r = await judgeBatch(s, batch);
      if (r.error) { warn(errorText(r.error === 'slow' ? 'slow' : r.error)); return null; }
      batch.forEach((b, j) => memo.set(b, r.mask[j] === 1));
    }
    return memo;
  }

  // The times a text breakpoint hits at in `entry` (ascending), or null after saying why.
  async function times(bp, entry, warn) {
    const checked = spec(bp);
    if (checked.error) { warn(format(S().debuggerTextError, label(bp), errorText(checked.error))); return null; }
    const width = entry.width;
    const bits = new Array(entry.changes.length);
    for (let i = 0; i < entry.changes.length; i++) { bits[i] = bitsOf(entry.changes[i][1], width); }
    const judged = await verdicts(JSON.stringify(bp.path) + '\u0000' + width, checked.spec, bits,
      (text) => warn(format(S().debuggerTextError, label(bp), text)));
    if (!judged) { return null; }
    const out = [];
    for (let i = 0; i < bits.length; i++) {
      if (i > 0 && bits[i] === bits[i - 1]) { continue; }
      if (judged.get(bits[i])) { out.push(Number(entry.changes[i][0])); }
    }
    return Float64Array.from(out);
  }

  waveform.debuggerText = Object.freeze({ spec, times, verdicts, label, formatOf, formatName, errorText, isRiscv: T.isRiscv,
    // For run.sh text-breakpoints: whether judging runs in the worker.
    usesWorker: () => !!startWorker() });
})();
