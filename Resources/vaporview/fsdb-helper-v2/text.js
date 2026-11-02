// Part of cmux's FSDB helper v2, written for cmux. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), whose helper it extends; see ../LICENSE.
// searchText for the worker: format a signal's values the way the viewer does and find
// the first change whose text matches. The formatters are the viewer's own code
// (formats.js, bundled from the VaporView webview sources by formats/build-formats.mjs),
// so the helper's text is the page's text. Matching follows the page's rules:
//   riscv*, alias: the pattern is a regex over the text, case-insensitive unless
//     caseSensitive; a pattern that isn't a valid regex is a plain substring
//     (extra_formats.ts matchFormatted).
//   ascii: VaporView's ASCII search: the pattern's characters as 8-bit codes, matched as a
//     regex anywhere in the value's bits (value_format.ts formatAscii + regexMatchBinary).
// The numeric formats (hex, bin, dec, sdec) are not text searches on the page (it uses its
// exact value search, value_search.ts), so they are refused here: the viewer uses `search`.
// Each distinct value is formatted at most once per format (ascii: only the hit) and judged
// at most once per (format, pattern); the memo lives as long as the signal's store (the
// addon's table generation). The one departure from the viewer's code is speed: the x/z text
// of ascii uses a linear-time equivalent of its digit grouping (below, checked byte for byte).
// Source credit: the formatters and match rules are VaporView's (GPL-3.0,
// https://github.com/Lramseyer/vaporview) and the cmux fork's additions to it.
'use strict';
const F = require('./formats.js');

const MAX_PATTERN = 4096;
const MAX_ALIAS_TEXT = 4 << 20;
const MEMO_SIGNALS = 16;     // signals with memoized texts (LRU)
const MEMO_PER_SIGNAL = 32;  // (format, pattern) verdict masks per signal (LRU)
// All verdict masks together (1 B per distinct value each) stay under this many bytes,
// least recently used evicted first (verify N6: 16 x 32 masks of 4M values was 2 GB).
const MASK_BYTES = Number(process.env.FSDB_TEXT_MASK_MB || 64) * 1e6;
const DEFAULT_BUDGET = 5000, MAX_BUDGET = 60000;
const ROUND = 4096;          // distinct values judged per addon round

const FORMATS = new Set(['riscv', 'riscv_numeric', 'riscv_noalias', 'riscv_numeric_noalias', 'alias', 'ascii']);
const NUMERIC = new Set(['hex', 'bin', 'dec', 'sdec']);
const is2 = (v) => !F.valueIs9State(v);

const aliasCache = new Map();  // alias file text + name + radix -> tables Map
function aliasTables(alias) {
  if (!alias || typeof alias !== 'object' || typeof alias.text !== 'string' || typeof alias.table !== 'string') {
    throw new Error('alias format needs alias: {text, table, fileName?, bareRadix?}');
  }
  if (alias.text.length > MAX_ALIAS_TEXT) { throw new Error('alias text too long'); }
  const key = `${alias.fileName || ''}\0${alias.bareRadix || ''}\0${alias.text}`;
  let t = aliasCache.get(key);
  if (!t) {
    const parsed = F.parseAliasFile(alias.text, String(alias.fileName || 'alias'), alias.bareRadix ? { bareRadix: alias.bareRadix } : {});
    t = new Map(parsed.tables.map((x) => [x.name, x]));
    aliasCache.set(key, t);
    if (aliasCache.size > 8) { aliasCache.delete(aliasCache.keys().next().value); }
  }
  return { tables: t, key };
}

// The viewer's x/z text (formatBinaryString, used by ascii for values holding x or z) groups
// digits with /\B(?=(\w{4})+(?!\w))/g, which is quadratic in the width. For values made only
// of word characters (01xzuwlh, i.e. no '-') it inserts '_' before every 4th character from
// the right except at the start, which group() does in linear time; a value holding '-' goes
// to the viewer's own function. helper-v2's tests check fast == viewer.
const NONWORD = /[^0-9A-Za-z_]/;
function group(s, n) {
  if (s.length <= n) { return s; }
  let k = s.length % n || n, out = s.slice(0, k);
  for (; k < s.length; k += n) { out += '_' + s.slice(k, k + n); }
  return out;
}
const FAST = { ascii: (v, two) => (two ? F.formatAscii.formatString(v, v.length, true) : group(v, 4)) };
const VIEWER = { ascii: F.formatAscii.formatString };
const numeric = (f) => (v) => (NONWORD.test(v) ? VIEWER[f](v, v.length, is2(v)) : FAST[f](v, is2(v)));

// -> {key, fmt(v, width) -> text}
function formatter(p) {
  const f = p.format;
  if (f.startsWith('riscv')) {
    const opts = F.formats[f];
    return { key: f, fmt: (v) => F.formatRiscvBinaryString(v, is2(v), opts) };
  }
  if (f === 'alias') {
    const { tables, key } = aliasTables(p.alias);
    const name = p.alias.table;
    return { key: `alias\0${name}\0${key}`, fmt: (v) => F.formatWithTable(tables, name, v) };
  }
  return { key: f, fmt: numeric(f) };
}

// -> (value, text) -> bool, as the page's checkSearchValue for this format
function matcher(p) {
  const pat = p.pattern;
  if (p.format === 'ascii') {
    const bits = F.formatAscii.parseSearchValue(pat);
    let re;
    try { re = new RegExp(bits, 'ig'); } catch (e) { re = null; }
    return (v) => { if (!re) { return false; } re.lastIndex = 0; return v.match(re) !== null; };
  }
  let re = null;
  const cs = p.caseSensitive === true;
  try { re = new RegExp(pat, cs ? '' : 'i'); } catch (e) { re = null; }
  if (re) { return (v, s) => re.test(s); }
  const needle = cs ? pat : pat.toLowerCase();
  return (v, s) => (cs ? s : s.toLowerCase()).includes(needle);
}

const memo = new Map();  // signalId -> {gen, texts: Map format key -> [] (+ .chars), masks: Map key -> Uint8Array}
// Every mask in every signal memo, least recently used first: entry -> {m, key}; maskBytes sums them.
const maskLru = new Map();
let maskBytes = 0;
const maskId = (m, key) => `${m.id}\0${m.gen}\0${key}`;
function maskDrop(m, key) {
  const a = m.masks.get(key);
  if (a) { maskBytes -= a.length; m.masks.delete(key); }
  maskLru.delete(maskId(m, key));
}
function maskTouch(m, key, a) {
  const old = m.masks.get(key);
  if (old && old !== a) { maskBytes -= old.length; }
  if (old !== a) { maskBytes += a.length; }
  m.masks.delete(key); m.masks.set(key, a);
  const id = maskId(m, key);
  maskLru.delete(id); maskLru.set(id, { m, key });
  while (m.masks.size > MEMO_PER_SIGNAL) { maskDrop(m, m.masks.keys().next().value); }
  for (const [lid, e] of maskLru) {  // the global byte cap, oldest first, never the one in use
    if (maskBytes <= MASK_BYTES) { break; }
    if (lid !== id) { maskDrop(e.m, e.key); }
  }
}
const dropMemo = (m) => { dropTexts(m); for (const key of [...m.masks.keys()]) { maskDrop(m, key); } };
function signalMemo(id, gen) {
  let m = memo.get(id);
  if (m && m.gen !== gen) { m = null; }
  if (m) { memo.delete(id); } else { m = { id, gen, texts: new Map(), masks: new Map() }; }
  memo.set(id, m);
  while (memo.size > MEMO_SIGNALS) { const k = memo.keys().next().value; dropMemo(memo.get(k)); memo.delete(k); }
  return m;
}
const lru = (map, key, make, cap, onEvict = () => {}) => {
  let v = map.get(key);
  if (v === undefined) { v = make(); } else { map.delete(key); }
  map.set(key, v);
  while (map.size > cap) { const k = map.keys().next().value; onEvict(map.get(k)); map.delete(k); }
  return v;
};

function check(p) {
  if (NUMERIC.has(p.format)) { throw new Error(`searchText format ${p.format}: numeric formats are value searches, use search (the page's exact value search)`); }
  if (!FORMATS.has(p.format)) { throw new Error(`bad searchText format ${p.format}`); }
  if (typeof p.pattern !== 'string' || !p.pattern.length || p.pattern.length > MAX_PATTERN) { throw new Error('searchText pattern must be a non-empty string (at most 4096 characters)'); }
}

// Each round's values are judged inside a vm call with the remaining budget as its timeout, so a
// pattern that backtracks catastrophically (or a formatter that never returns) ends at its
// budget (default 5 s). A cancel is cooperative: `stop()` (the addon's SIGUSR2 flag, sent by a
// cancel, and kept from a cancel that landed during the load) is polled between values, so a
// cancel waits for the value being judged. No SIGINT / breakOnSigint: vm swaps out the process's
// SIGINT listeners around each call, so a cancel's SIGINT could kill the worker or interrupt the
// next, unrelated request (verify R1). An instant cancel needs a worker_thread or a tid-bound
// addon watchdog (status/helper-v2.md, later).
const vm = require('node:vm');
const ctx = vm.createContext({});
const runJob = new vm.Script('job()');
// Formatted texts are kept for a new pattern in the same format, up to TEXT_CHARS in all;
// past that they are not kept.
const TEXT_CHARS = 64e6;
let textChars = 0;
const dropTexts = (m) => { for (const a of m.texts.values()) { textChars -= a.chars || 0; } m.texts.clear(); };

// p: {signalId, t, dir, inclusive?, format, pattern, caseSensitive?, alias?, budgetMs?}
// dir 1: the first change with time > t (>= t if inclusive); dir -1: the last < t (<= t).
// -> {t, value, text, distinct, formatted, rounds, ms} | {t: null, ...}
//    | {t: null, incomplete: {timedOut | cancelled, at, resume: {t: at, inclusive: true}}}
//      (no match before `at`, the first change not yet judged; resuming from there with
//      inclusive: true judges it first, so a resume never skips or repeats a hit)
//    | {t: null, incomplete: {tooLarge: true, reason}} (the value table doesn't fit the signal cap)
function search(addon, p, stop = () => false) {
  check(p);
  const t0 = Date.now();
  const budget = Number(p.budgetMs) > 0 ? Math.min(MAX_BUDGET, Number(p.budgetMs)) : DEFAULT_BUDGET;
  const deadline = t0 + budget;
  const dir = p.dir < 0 ? -1 : 1;
  const inclusive = p.inclusive === true;
  const { key: fkey, fmt } = formatter(p);
  const ok = matcher(p);
  const bitsOnly = p.format === 'ascii';  // the ASCII rule matches the bits; text only for the hit
  const mkey = `${fkey}\0${bitsOnly ? '' : p.caseSensitive === true ? 'c' : 'i'}\0${p.pattern}`;
  const old = memo.get(p.signalId);
  let mask = old ? old.masks.get(mkey) || null : null;
  let r = addon.cacheTextScan(p.signalId, p.t, dir, mask, ROUND, -1, undefined, inclusive);
  if (r.tooLarge) { return { t: null, incomplete: { tooLarge: true, reason: r.error }, ms: Date.now() - t0 }; }
  if (old && r.gen !== old.gen) {  // store rebuilt: the memo is stale
    dropMemo(old); memo.delete(p.signalId);
    if (mask) { mask = null; r = addon.cacheTextScan(p.signalId, p.t, dir, null, ROUND, -1, undefined, inclusive); }
  }
  const m = signalMemo(p.signalId, r.gen);
  const texts = lru(m.texts, fkey, () => Object.assign([], { chars: 0 }), 8, (a) => { textChars -= a.chars; });
  mask = m.masks.get(mkey);
  if (!mask || mask.length < r.n) { const g = new Uint8Array(r.n); if (mask) { g.set(mask); } mask = g; }
  maskTouch(m, mkey, mask);
  let formatted = 0, rounds = 1, stopped = false;
  const text = (d, v) => {
    let s = texts[d];
    if (s === undefined) {
      try { s = fmt(v); } catch (e) { s = null; }
      formatted++;
      if (textChars < TEXT_CHARS) { texts[d] = s; const c = s ? s.length : 0; texts.chars += c; textChars += c; }
    }
    return s;
  };
  const end = (why) => ({ t: null, incomplete: { [why]: true, at: r.kt, resume: { t: r.kt, inclusive: true } }, distinct: r.n, formatted, rounds, ms: Date.now() - t0 });
  while (r.need) {
    const need = r.need;
    ctx.job = () => {
      for (const { d, v } of need) {
        if (stop()) { stopped = true; return; }
        let hit = false;
        if (bitsOnly) { try { hit = ok(v, null); } catch (e) { hit = false; } } else {
          const s = text(d, v);
          if (s !== null) { try { hit = ok(v, s); } catch (e) { hit = false; } }
        }
        mask[d] = hit ? 1 : 2;
      }
    };
    try { runJob.runInContext(ctx, { timeout: Math.max(1, deadline - Date.now()) }); } catch (e) {
      if (e && e.code === 'ERR_SCRIPT_EXECUTION_TIMEOUT') { return end('timedOut'); }
      throw e;
    } finally { ctx.job = null; }
    if (stopped) { return end('cancelled'); }
    if (Date.now() > deadline) { return end('timedOut'); }
    r = addon.cacheTextScan(p.signalId, p.t, dir, mask, ROUND, r.k);
    rounds++;
  }
  const out = { t: r.t, distinct: r.n, formatted, rounds, ms: Date.now() - t0 };
  if (r.t !== null) { out.value = r.v; out.text = text(r.d, r.v); }
  return out;
}

const stats = () => ({ maskBytes, masks: maskLru.size, textChars, signals: memo.size });

module.exports = { search, check, stats, FORMATS, numeric, VIEWER };
