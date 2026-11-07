// SPDX-License-Identifier: MIT
// simctl reusable testbench, the worker's side: stimulus text -> the packed file simctl_port reads
// (simctl_tb.sv), and the build manifest behind `staleness`.
//
// Stimulus text (what an agent writes), one transaction per line; `#` starts a comment:
//   port <name>                      optional: must be the port it is given to
//   fields <f>[msb:lsb] ...          optional: the layout over the port's data (default: the port's FIELDS)
//   [@N | +N] f=v f=v ...            @N: not before the N-th rising edge after the arm; +N: N rising edges after
//   [@N | +N] <value>                the previous transaction (default +0); a bare value is the whole bus
// Values: 0x.., 0b.., decimal, or Verilog 'h/'b/'d literals; `_` allowed. Unnamed fields are 0.
'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');

function parseValue(s) {
  const t = String(s).replace(/_/g, '');
  let m;
  if ((m = /^(?:0x|'h)([0-9a-fA-F]+)$/.exec(t))) return BigInt('0x' + m[1]);
  if ((m = /^(?:0b|'b)([01]+)$/.exec(t))) return BigInt('0b' + m[1]);
  if ((m = /^(?:'d)?([0-9]+)$/.exec(t))) return BigInt(m[1]);
  return null;
}
// "addr[31:0] len[7:0] flag" -> [{name, msb, lsb}] (a field without a range is one bit)
function parseFields(spec) {
  const out = [];
  for (const f of String(spec || '').trim().split(/\s+/).filter(Boolean)) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)(?:\[(\d+)(?::(\d+))?\])?$/.exec(f);
    if (!m) throw new Error(`bad field ${JSON.stringify(f)}: use name[msb:lsb]`);
    const msb = m[2] === undefined ? 0 : Number(m[2]), lsb = m[3] === undefined ? msb : Number(m[3]);
    if (lsb > msb) throw new Error(`field ${m[1]}: msb below lsb`);
    out.push({ name: m[1], msb, lsb });
  }
  return out;
}
// A port from describe ({name, kind, width, fields}) and a stimulus text -> {packed, count} or throws.
// Errors that only a rebuild can fix carry needsRebuild.
function packStim(port, text) {
  const W = port.width;
  let fields = parseFields(port.fields || '');
  const rebuild = (msg, hint) => Object.assign(new Error(msg), { needsRebuild: true, hint });
  const lines = String(text).split('\n');
  const out = [`# simctl packed stimulus for port ${port.name} (${port.kind}, ${W} bits)`];
  let count = 0;
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i].replace(/#.*$/, '').trim();
    if (!raw) continue;
    const at = `line ${i + 1}`;
    const words = raw.split(/\s+/);
    if (words[0] === 'port') {
      if (words[1] !== port.name) throw new Error(`${at}: this stimulus is for port ${words[1]}, given to ${port.name}`);
      continue;
    }
    if (words[0] === 'fields') {
      fields = parseFields(words.slice(1).join(' '));
      const top = Math.max(-1, ...fields.map((f) => f.msb));
      if (top >= W) throw rebuild(`${at}: field layout needs ${top + 1} bits; port ${port.name} is ${W} bits`, `a wider port is a rebuild: simctl_port #(.W(${top + 1}))`);
      continue;
    }
    let how = 0, n = 0n, k = 0;
    const tm = /^([@+])(\d+)$/.exec(words[0]);
    if (tm) { how = tm[1] === '@' ? 1 : 0; n = BigInt(tm[2]); k = 1; }
    let v = 0n;
    const rest = words.slice(k);
    if (!rest.length) throw new Error(`${at}: no value`);
    if (rest.length === 1 && !rest[0].includes('=')) {
      const x = parseValue(rest[0]);
      if (x === null) throw new Error(`${at}: bad value ${rest[0]}`);
      if (x >> BigInt(W)) throw new Error(`${at}: ${rest[0]} does not fit port ${port.name} (${W} bits)`);
      v = x;
    } else {
      for (const a of rest) {
        const m = /^([A-Za-z_][A-Za-z0-9_]*)=(\S+)$/.exec(a);
        if (!m) throw new Error(`${at}: expected field=value, got ${a}`);
        const f = fields.find((x) => x.name === m[1]);
        if (!f) throw new Error(`${at}: no field ${m[1]} on port ${port.name} (fields: ${fields.map((x) => x.name).join(' ') || 'none; give a fields line'})`);
        const x = parseValue(m[2]);
        if (x === null) throw new Error(`${at}: bad value ${m[2]}`);
        const fw = BigInt(f.msb - f.lsb + 1);
        if (x >> fw) throw new Error(`${at}: ${m[1]}=${m[2]} does not fit ${fw} bits`);
        v |= x << BigInt(f.lsb);
      }
    }
    out.push(`${how} ${n} ${v.toString(16)}`);
    count++;
  }
  return { packed: out.join('\n') + '\n', count };
}

// ---- memory images: $readmemh / $readmemb text (IEEE 1800 21.4: words separated by white space, @<hex address>,
// // and /* */ comments, _ in numbers, x/z digits) -> {packed: '<index> <hex>' lines, words, ignored}.
// Words go from `start` (default 0, or an @ address) upward; past `end` they are ignored (counted).
function packMem(text, { format = 'h', start = 0, end = Infinity } = {}) {
  const src = String(text).replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
  const out = []; let addr = Number(start), words = 0, ignored = 0;
  if (!Number.isSafeInteger(addr) || addr < 0) throw new Error('loadmem: start must be a whole number >= 0');
  for (const tok of src.split(/\s+/).filter(Boolean)) {
    if (tok[0] === '@') {
      if (!/^@[0-9a-fA-F_]+$/.test(tok)) throw new Error(`loadmem: bad address ${tok}`);
      addr = parseInt(tok.slice(1).replace(/_/g, ''), 16); continue;
    }
    const t = tok.replace(/_/g, '').toLowerCase();
    let hex;
    if (format === 'h') {
      if (!/^[0-9a-fxz]+$/.test(t)) throw new Error(`loadmem: bad hex word ${tok}`);
      hex = t;
    } else if (format === 'b') {
      if (!/^[01xz]+$/.test(t)) throw new Error(`loadmem: bad binary word ${tok}`);
      const b = t.padStart(Math.ceil(t.length / 4) * 4, '0'); hex = '';
      for (let i = 0; i < b.length; i += 4) {
        const g = b.slice(i, i + 4);
        if (/^[01]+$/.test(g)) hex += parseInt(g, 2).toString(16);
        else if (/^x+$/.test(g)) hex += 'x'; else if (/^z+$/.test(g)) hex += 'z';
        else throw new Error(`loadmem: binary word ${tok} mixes x/z with 0/1 inside a hex digit; give it as hex`);
      }
    } else throw new Error('loadmem: format must be h or b');
    if (addr > end) ignored++; else { out.push(`${addr} ${hex}`); words++; }
    addr++;
  }
  return { packed: out.join('\n') + '\n', words, ignored };
}

// ---- build manifest: <simv>.simctl.json, written at build time by simctl-manifest.js
const sha = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
function writeManifest(simv, files) {
  const m = { simv, simvMtimeMs: fs.statSync(simv).mtimeMs, created: new Date().toISOString(),
    files: files.map((f) => ({ path: f, sha256: sha(f), bytes: fs.statSync(f).size })) };
  fs.writeFileSync(simv + '.simctl.json', JSON.stringify(m, null, 1));
  return m;
}
// {known, stale, changed, missing, rebuiltSince, needsRebuild, hint}
function staleness(simv) {
  let m;
  try { m = JSON.parse(fs.readFileSync(simv + '.simctl.json', 'utf8')); } catch {
    return { known: false, hint: `no build manifest (${simv}.simctl.json): write one after each build with simctl-manifest.js <simv> <sources...>` };
  }
  const changed = [], missing = [];
  for (const f of m.files || []) {
    let h; try { h = sha(f.path); } catch { missing.push(f.path); continue; }
    if (h !== f.sha256) changed.push(f.path);
  }
  let rebuiltSince = false; try { rebuiltSince = fs.statSync(simv).mtimeMs !== m.simvMtimeMs; } catch { /* gone */ }
  const stale = changed.length > 0 || missing.length > 0;
  return { known: true, stale, changed, missing, rebuiltSince, files: (m.files || []).length, created: m.created,
    needsRebuild: stale, ...(stale ? { hint: 'a source changed since this build: RTL/testbench edits need a rebuild (stimulus files do not)' } : {}),
    ...(rebuiltSince ? { notice: 'the simulator was rebuilt after its manifest was written: refresh it' } : {}) };
}

module.exports = { packMem, packStim, parseFields, parseValue, writeManifest, staleness };
