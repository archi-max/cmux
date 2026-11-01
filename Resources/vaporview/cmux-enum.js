// cmux: SystemVerilog enum member names for waveform values. A dump seldom says which signals
// are enums (VCD never does; the FSDB helper doesn't read Verdi's enum records yet), but the
// design's source does: cmux asks slang-server (SlangEnumTypes.swift) and hands the types here.
//
// Rows: each enum type becomes a value alias table (VaporView's alias:<table> format,
// extra_formats.ts in source/cmux-vaporview.patch) with a binding for each enum signal. A row
// the user adds gets the table as its format by default:
//   - a row added after its type is known gets it in the add's own undo step (extra_formats
//     binds new rows right after VaporView creates them);
//   - a row added before gets it once the type arrives, as one undo step;
//   - only while the row is still in VaporView's default format (hexadecimal); a row that came
//     back through Undo, Redo, a session or a restored state keeps the format it had, and a
//     format the user picks afterwards is never changed. The format is saved with the row.
// Values no member has show as hex, with a `?` when the type is at most 8 bits wide.
//
// cmux (native) is asked with { type: 'enumTypes', paths } for shown rows whose type it hasn't
// answered yet, and answers through window.cmuxWaveform.enums.define({ tables, signals }):
//   tables: [{ id, label, width, members: [[name, bits], ...] }]   bits: most significant first
//   signals: { 'dotted.dump.path': id }
// Also for the editor and the debugger: tableFor(path), memberBits(path, name), format(path, bits).
(function () {
  'use strict';
  const host = window.cmuxWaveform.host;
  const MAX_ASK = 200;
  const FILL_WIDTH = 8;
  const RESTORED = new Set([1, 2, 3, 4]); // StateChangeType Restore, File, Undo, Redo
  const FILE_NAME = 'cmux-sv-enums.json';

  // ---- pure: a value of an enum type as text ----

  // bits as `width` bits: shorter is extended with its top bit when that is x or z, else 0.
  function fitted(bits, width) {
    const s = String(bits).toLowerCase();
    if (s.length === width) { return s; }
    if (s.length > width) { return s.slice(s.length - width); }
    const top = s[0] === 'x' || s[0] === 'z' ? s[0] : '0';
    return top.repeat(width - s.length) + s;
  }

  function hexLiteral(bits) {
    let out = '';
    for (let end = bits.length; end > 0; end -= 4) {
      const group = bits.slice(Math.max(0, end - 4), end);
      out = (/^[01]+$/.test(group) ? parseInt(group, 2).toString(16) : '?') + out;
    }
    return bits.length + "'h" + out;
  }

  // { text, member } for `bits` of `table`: the member's name; a known value no member has as
  // hex with a `?`; x or z (or a mix) as x, z or a binary literal.
  function display(table, value) {
    const bits = fitted(value, table.width);
    if (/^[01]+$/.test(bits)) {
      const name = table.byBits.get(bits);
      return name !== undefined ? { text: name, member: true } : { text: hexLiteral(bits) + '?', member: false };
    }
    if (/^z+$/.test(bits)) { return { text: 'z', member: false }; }
    if (!/[01z]/.test(bits)) { return { text: 'x', member: false }; }
    return { text: bits.length + "'b" + bits.replace(/[^01z]/g, 'x'), member: false };
  }

  // ---- what cmux told us ----
  const tables = new Map();   // id -> { id, label, width, members, byBits, byName }
  const signals = new Map();  // dotted dump path -> table id
  const asked = new Set();    // dotted paths cmux was asked about (answered or not)
  const seen = new Set();     // dotted paths of rows shown at the last context
  const decided = new Set();  // rows whose default format is settled (set, or not ours to set)
  const eligible = new Set(); // rows the user added that may still get the default
  let generation = -1;
  let askTimer = null;
  let pendingAsk = new Map(); // dotted -> segments

  const dotted = (segments) => segments.join('.');

  function frameFormats() {
    try {
      return document.getElementById('viewer').contentWindow.vaporviewValueFormats || null;
    } catch (error) {
      return null;
    }
  }

  function resetIfReopened() {
    if (host.loadGeneration === generation) { return; }
    generation = host.loadGeneration;
    signals.clear();
    asked.clear();
    seen.clear();
    decided.clear();
    eligible.clear();
    pendingAsk.clear();
  }

  // Shown netlist rows outside the debugger's Locals: [{ path, segments, format }].
  function shownRows(context) {
    const out = [];
    const walk = (list) => (list || []).forEach((d) => {
      if (host.isTransientGroup && host.isTransientGroup(d)) { return; }
      if (d.dataType === 'netlist-variable' || (d.dataType === undefined && d.netlistId !== undefined)) {
        const v = d.netlistId !== undefined ? host.netlistItem(d.netlistId) : null;
        const segments = v && window.cmuxWaveform.host.pathOf ? window.cmuxWaveform.host.pathOf(v) : String(d.name || '').split('.');
        if (segments.length) { out.push({ path: dotted(segments), segments, format: d.numberFormat }); }
      }
      walk(d.children);
    });
    walk(context && context.displayedSignals);
    return out;
  }

  function onContext(m) {
    resetIfReopened();
    if (!m || !m.displayedSignals) { return; }
    const rows = shownRows(m);
    const now = new Set(rows.map((r) => r.path));
    for (const path of Array.from(seen)) {
      if (!now.has(path)) { seen.delete(path); decided.delete(path); eligible.delete(path); }
    }
    const restored = RESTORED.has(m.stateChangeType);
    for (const r of rows) {
      if (seen.has(r.path)) { continue; }
      seen.add(r.path);
      if (restored) { decided.add(r.path); } else { eligible.add(r.path); }
      if (!asked.has(r.path)) { pendingAsk.set(r.path, r.segments); }
    }
    if (pendingAsk.size && !askTimer) { askTimer = setTimeout(ask, 120); }
  }

  function ask() {
    askTimer = null;
    const paths = Array.from(pendingAsk.entries()).slice(0, MAX_ASK);
    paths.forEach(([path]) => { pendingAsk.delete(path); asked.add(path); });
    if (paths.length) { host.toNative({ type: 'enumTypes', paths: paths.map(([, segments]) => segments) }); }
    if (pendingAsk.size) { askTimer = setTimeout(ask, 120); }
  }

  // The alias table for one enum type: every member, then (narrow types) every other value
  // as its hex with a `?`.
  function aliasTable(table) {
    const out = {};
    for (const [name, bits] of table.members) {
      const key = table.width + "'b" + bits;
      if (!(key in out)) { out[key] = name; }
    }
    if (table.width <= FILL_WIDTH) {
      for (let n = 0; n < (1 << table.width); n++) {
        const bits = n.toString(2).padStart(table.width, '0');
        const key = table.width + "'b" + bits;
        if (!(key in out)) { out[key] = hexLiteral(bits) + '?'; }
      }
    }
    return out;
  }

  function aliasFile(ids, paths) {
    const t = {};
    ids.forEach((id) => { const table = tables.get(id); if (table) { t[table.label] = aliasTable(table); } });
    const s = {};
    paths.forEach((path) => { const table = tables.get(signals.get(path)); if (table) { s[path] = table.label; } });
    return JSON.stringify({ tables: t, signals: s });
  }

  // cmux's answer: { tables, signals } (see the top). Returns { tables, signals, bound }.
  function define(answer) {
    resetIfReopened();
    const list = Array.isArray(answer && answer.tables) ? answer.tables : [];
    const changed = new Set();
    for (const t of list) {
      if (!t || typeof t.id !== 'string' || typeof t.label !== 'string' || !Number.isInteger(t.width) || t.width < 1 || t.width > 4096
        || !Array.isArray(t.members)) { continue; }
      const members = t.members.filter((m) => Array.isArray(m) && typeof m[0] === 'string' && typeof m[1] === 'string'
        && m[1].length === t.width && /^[01]+$/.test(m[1])).slice(0, 4096);
      const byBits = new Map();
      const byName = new Map();
      members.forEach(([name, bits]) => { if (!byBits.has(bits)) { byBits.set(bits, name); } if (!byName.has(name)) { byName.set(name, bits); } });
      tables.set(t.id, { id: t.id, label: t.label, width: t.width, members, byBits, byName });
      changed.add(t.id);
    }
    const paths = [];
    const given = answer && typeof answer.signals === 'object' && answer.signals ? answer.signals : {};
    for (const [path, id] of Object.entries(given)) {
      if (typeof id === 'string' && tables.has(id)) { signals.set(path, id); paths.push(path); }
    }
    const formats = frameFormats();
    let bound = 0;
    if (formats && paths.length) {
      const ids = new Set(paths.map((p) => signals.get(p)));
      changed.forEach((id) => ids.add(id));
      // Tables and every binding, so rows added from now on get theirs in their own add.
      formats.loadValueAliases(aliasFile(Array.from(ids), paths), FILE_NAME, { apply: false });
      // Rows the user added before their type was known: once, while still in the default format.
      const rows = shownRows(window.cmuxWaveform.viewerContext.webview);
      const now = rows.filter((r) => eligible.has(r.path) && !decided.has(r.path) && signals.has(r.path)
        && (r.format === undefined || r.format === 'hexadecimal'));
      rows.forEach((r) => { if (signals.has(r.path) && eligible.has(r.path)) { decided.add(r.path); } });
      if (now.length) {
        const nowPaths = Array.from(new Set(now.map((r) => r.path)));
        const result = formats.loadValueAliases(aliasFile(Array.from(new Set(nowPaths.map((p) => signals.get(p)))), nowPaths), FILE_NAME, { apply: true });
        bound = result && Number.isInteger(result.applied) ? result.applied : 0;
      }
    }
    return { tables: changed.size, signals: paths.length, bound };
  }

  function tableFor(path) {
    const key = Array.isArray(path) ? dotted(path.map(String)) : String(path);
    const id = signals.get(key);
    return id === undefined ? null : tables.get(id) || null;
  }

  host.contextListeners.push(onContext);

  const api = Object.freeze({
    define,
    // The enum type cmux gave for a dump path: { label, width, members: [[name, bits]] } or null.
    tableFor: (path) => { const t = tableFor(path); return t ? { label: t.label, width: t.width, members: t.members.slice() } : null; },
    // The bits of member `name` of the signal's type, or null (for breakpoints and conditions).
    memberBits: (path, name) => { const t = tableFor(path); return t ? (t.byName.get(String(name)) ?? null) : null; },
    // The signal's value as its enum type reads, or null when it has none.
    format: (path, bits) => { const t = tableFor(path); return t ? display(t, String(bits)).text : null; },
    // Pure helpers, for tests.
    display: (table, bits) => display({ width: table.width, byBits: new Map((table.members || []).map(([n, b]) => [b, n])) }, String(bits)).text,
    hexLiteral,
  });
  Object.defineProperty(window.cmuxWaveform, 'enums', { value: api, writable: false, configurable: false, enumerable: true });
})();
