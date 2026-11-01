// Text breakpoints' rule (written for cmux): a signal's value, shown in a viewer format, matches a
// pattern. The formatters are the viewer's own (cmux-formats.js, bundled from the VaporView webview
// sources); the match rules are the viewer's value search (the cmux fork's extra_formats.ts
// matchFormatted, and VaporView's ASCII bit rule), as helper-v2's searchText applies them, so a text
// breakpoint hits where a value search finds the value. Loaded by the page, by cmux-text-worker.js
// and by run.sh text (JavaScriptCore).
//
//   spec: { format, pattern, caseSensitive?, anyRegisterNames?, alias?: { text, table, fileName?, bareRadix? } }
//   format: riscv | riscv_numeric | riscv_noalias | riscv_numeric_noalias | alias:<table> | hexadecimal
//           | binary | octal | decimal | signed | ascii
//   check(spec) -> null | error ('format' | 'pattern' | 'patternTooLong' | 'alias')
//   textOf(spec, bits) -> the text the viewer shows (bits: one character per bit, msb first)
//   judge(spec, values) -> Uint8Array, 1 where values[i] (full-width bit strings) matches
(function (root) {
  'use strict';
  const F = root.cmuxFormats;
  const MAX_PATTERN = 4096;
  const RISCV = new Set(['riscv', 'riscv_numeric', 'riscv_noalias', 'riscv_numeric_noalias']);
  const NUMERIC = new Set(['hexadecimal', 'binary', 'octal', 'decimal', 'signed']);
  // The other register naming of a RISC-V format (anyRegisterNames: `jal ra` and `jal x1` both match).
  const OTHER_NAMES = { riscv: 'riscv_numeric', riscv_numeric: 'riscv', riscv_noalias: 'riscv_numeric_noalias', riscv_numeric_noalias: 'riscv_noalias' };

  const is2 = (v) => !F.valueIs9State(v);
  const isRiscv = (format) => RISCV.has(format);

  // The viewer's numeric formatters group digits with regexes that are quadratic in the width; for
  // values made only of word characters these insert '_' before every n-th character from the right
  // except at the start, which group() does in linear time (helper-v2 text.js, ours; checked against
  // the viewer's functions by run.sh text). A value holding '-' goes to the viewer's own function.
  const NONWORD = /[^0-9A-Za-z_]/;
  function group(s, n) {
    if (s.length <= n) { return s; }
    let k = s.length % n || n, out = s.slice(0, k);
    for (; k < s.length; k += n) { out += '_' + s.slice(k, k + n); }
    return out;
  }
  const HEX4 = [['z', /[z]/], ['x', /[x]/], ['u', /[u]/], ['w', /[w]/], ['l', /[l]/], ['h', /[h]/]];
  const FAST = {
    hexadecimal: (v, two) => (two
      ? group(v, 16).split('_').map((c) => parseInt(c, 2).toString(16).padStart(Math.ceil(c.length / 4), '0')).join('_')
      : group(group(v, 4).split('_').map((c) => { for (const [o, re] of HEX4) { if (re.test(c)) { return o; } } return parseInt(c, 2).toString(16); }).join(''), 4)),
    binary: (v) => group(v, 4),
    decimal: (v, two) => (two ? F.formatDecString(v, v.length, true) : group(v, 4)),
    signed: (v, two) => (two ? F.formatSdecString(v, v.length, true) : group(v, 4)),
  };
  const VIEWER = { hexadecimal: F.formatHexString, octal: F.formatOctString, binary: F.formatBinString, decimal: F.formatDecString, signed: F.formatSdecString };

  function viewerText(format, v) {
    return VIEWER[format](v, v.length, is2(v));
  }

  function numericText(format, v) {
    if (format === 'octal' || NONWORD.test(v)) { return viewerText(format, v); }
    return FAST[format](v, is2(v));
  }

  const aliasCache = new Map();
  function aliasTables(alias) {
    const key = `${alias.fileName || ''}\0${alias.bareRadix || ''}\0${alias.text}`;
    let t = aliasCache.get(key);
    if (!t) {
      const parsed = F.parseAliasFile(alias.text, String(alias.fileName || 'alias'), alias.bareRadix ? { bareRadix: alias.bareRadix } : {});
      t = new Map(parsed.tables.map((x) => [x.name, x]));
      aliasCache.set(key, t);
      if (aliasCache.size > 8) { aliasCache.delete(aliasCache.keys().next().value); }
    }
    return t;
  }

  function check(spec) {
    const s = spec || {};
    const format = String(s.format || '');
    if (!(isRiscv(format) || NUMERIC.has(format) || format === 'ascii' || /^alias:./.test(format))) { return 'format'; }
    if (typeof s.pattern !== 'string' || !s.pattern.length) { return 'pattern'; }
    if (s.pattern.length > MAX_PATTERN) { return 'patternTooLong'; }
    if (format.startsWith('alias:')) {
      const a = s.alias;
      if (!a || typeof a.text !== 'string') { return 'alias'; }
      try { if (!aliasTables(a).has(format.slice(6))) { return 'alias'; } } catch (e) { return 'alias'; }
    }
    return null;
  }

  // The text the viewer shows for `bits` in `format`.
  function textOf(spec, bits, format) {
    const f = format || spec.format;
    if (isRiscv(f)) { return F.formatRiscvBinaryString(bits, is2(bits), F.riscvOptions[f]); }
    if (f.startsWith('alias:')) { return F.formatWithTable(aliasTables(spec.alias), f.slice(6), bits); }
    if (f === 'ascii') { return F.formatAscii.formatString(bits, bits.length, is2(bits)); }
    return numericText(f, bits);
  }

  // (bits, text) -> bool, the viewer's search rule for the format.
  function matcherOf(spec) {
    const pat = spec.pattern;
    if (spec.format === 'ascii') {
      // VaporView's ASCII search: the pattern's characters as 8-bit codes, a regex over the bits.
      let re;
      try { re = new RegExp(F.formatAscii.parseSearchValue(pat), 'ig'); } catch (e) { re = null; }
      return (bits) => { if (!re) { return false; } re.lastIndex = 0; return bits.match(re) !== null; };
    }
    let re = null;
    try { re = new RegExp(pat, spec.caseSensitive ? '' : 'i'); } catch (e) { re = null; }
    if (re) { return (bits, text) => re.test(text); }
    const needle = spec.caseSensitive ? pat : pat.toLowerCase();
    return (bits, text) => (spec.caseSensitive ? text : text.toLowerCase()).includes(needle);
  }

  function judge(spec, values) {
    const ok = matcherOf(spec);
    const formats = [spec.format];
    if (isRiscv(spec.format) && spec.anyRegisterNames !== false) { formats.push(OTHER_NAMES[spec.format]); }
    const out = new Uint8Array(values.length);
    for (let i = 0; i < values.length; i++) {
      const bits = values[i];
      if (spec.format === 'ascii') { out[i] = ok(bits, null) ? 1 : 0; continue; }
      for (const f of formats) {
        let text;
        try { text = textOf(spec, bits, f); } catch (e) { text = null; }
        if (text !== null && text !== undefined && ok(bits, String(text))) { out[i] = 1; break; }
      }
    }
    return out;
  }

  // Whether a viewer format id can be a text breakpoint's format.
  const isTextFormat = (format) => check({ format, pattern: 'x', alias: { text: '' } }) !== 'format';

  root.cmuxTextMatch = Object.freeze({ check, textOf, judge, isRiscv, isTextFormat, MAX_PATTERN, viewerText, numericText });
})(typeof self !== 'undefined' ? self : this);
