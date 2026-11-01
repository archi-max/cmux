// cmux's waveform debugger: SystemVerilog expressions over a dump's values, for Evaluate,
// watches and condition breakpoints (cmux-debugger.js), per IEEE 1800-2017: operators and their
// 4-state results (11.3, 11.4), expression widths and signedness (11.6, 11.8), literals (5.7).
// Pure: no DOM, no host. Names are resolved by the caller (env), so one parse serves any scope.
//
// The semantics follow slang (https://github.com/MikePopoloski/slang, master commit cd5a3d2,
// which includes 0f89ca187): SVInt's 4-state operators and the width and sign propagation of
// its expression types, reimplemented here. A VCS differential fuzz checks them
// (scripts/waveform-viewer-checks/expr/fuzz.js); where slang and VCS differ (?: with an unknown
// condition and z in both arms), this follows VCS and the LRM. slang's license:
//
//   Copyright (c) 2015-2026 Michael Popoloski
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy
//   of this software and associated documentation files (the "Software"), to deal
//   in the Software without restriction, including without limitation the rights
//   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//   copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in
//   all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//   THE SOFTWARE.
//
//   parse(text) -> { ast } | { error, at }      at: 0-based column
//   names(ast) -> [[segment, ...], ...]         each signal once, as written
//   evaluate(ast, env) -> { value } | { error, at }
//       env(path) -> { width, msb, lsb, value, signed } | null   (msb/lsb: the declared range,
//       optional; signed: optional, a dump's signals are unsigned unless it says)
//   format(value, 'hex' | 'binary' | 'octal' | 'decimal') -> "8'h3c"
//   truthy(value), same(v1, v2), fromBits('10x1', width)
//
// Signed: unsized decimals, 's literals and signed signals; an operator over context-determined
// operands is signed when all of them are (so -1 < 0, 8'sd200 * 2 sign-extends, a[-1 +: 2] reads
// below the range, >>> shifts in the top bit). format() prints values unsigned. Simplifications
// (the debugger's docs say these too): z is x in every operator but ===, selects,
// concatenation, unary plus and the display; the whole expression is one context with no
// assignment target; no $signed / $unsigned, / % ** ==? !=?, no function calls, no memories or
// struct members.
(function (root) {
  'use strict';
  const MAX_TEXT = 1000;
  const MAX_SIGNALS = 16;
  const MAX_WIDTH = 4096;

  // A value: { w, a, b }, w bits; per bit (a, b) as VPI encodes it: 0 (0,0), 1 (1,0), z (0,1), x (1,1).
  const maskOf = (w) => (1n << BigInt(w)) - 1n;
  const val = (w, a, b) => { const m = maskOf(w); return { w, a: a & m, b: b & m }; };
  const allX = (w) => val(w, maskOf(w), maskOf(w));
  const ones = (v) => v.a & ~v.b & maskOf(v.w);
  const zeros = (v) => ~v.a & ~v.b & maskOf(v.w);
  // From the known 1s and 0s; every other bit is x.
  const fromKnown = (w, o, z) => { const m = maskOf(w); const u = m & ~(o | z); return val(w, o | u, u); };
  // Zero-extended to w (unsigned).
  const ext = (v, w) => (w === v.w ? v : val(w, v.a, v.b));
  // Extended to w with its top bit (0, 1, x or z) when signed, as slang's SVInt::extend does.
  const sext = (v, w) => {
    if (w <= v.w || v.w === 0) { return ext(v, w); }
    const top = BigInt(v.w - 1);
    const high = maskOf(w) & ~maskOf(v.w);
    return val(w, v.a | (((v.a >> top) & 1n) ? high : 0n), v.b | (((v.b >> top) & 1n) ? high : 0n));
  };
  const extend = (v, w, signed) => (signed ? sext(v, w) : ext(v, w));
  // A known value as a two's-complement BigInt.
  const signedOf = (v) => (v.w > 0 && ((v.a >> BigInt(v.w - 1)) & 1n) ? v.a - (1n << BigInt(v.w)) : v.a);
  const bit1 = (t) => (t === 1 ? val(1, 1n, 0n) : (t === 0 ? val(1, 0n, 0n) : allX(1)));
  // 1, 0 or 'x' as an SV if, && and || take a value.
  const truth = (v) => (ones(v) !== 0n ? 1 : (v.b === 0n ? 0 : 'x'));

  // '10x1' (most significant first) as a value of `width` bits: shorter is extended with its top
  // bit when that is x or z, else 0; longer keeps the low bits. A dump's other states: h is 1,
  // l is 0, z (and ?) z, anything else (u, w, -) x.
  function fromBits(text, width) {
    let s = String(text).toLowerCase();
    if (s.length < width) { s = (s[0] === 'x' || s[0] === 'z' ? s[0] : '0').repeat(width - s.length) + s; }
    s = s.slice(s.length - width);
    let a = 0n, b = 0n;
    for (const c of s) {
      a <<= 1n; b <<= 1n;
      if (c === '1' || c === 'h') { a |= 1n; } else if (c === 'z' || c === '?') { b |= 1n; } else if (c !== '0' && c !== 'l') { a |= 1n; b |= 1n; }
    }
    return val(width, a, b);
  }

  const fail = (error, at) => { throw { exprError: error, at }; };

  // ---- tokens ----
  const OPERATORS = ['<<<', '>>>', '===', '!==', '==?', '!=?', '**', '==', '!=', '<=', '>=', '&&', '||', '<<', '>>',
    '~&', '~|', '~^', '^~', '+:', '-:', '+', '-', '*', '/', '%', '&', '|', '^', '~', '!', '<', '>', '?', ':', '(', ')',
    '[', ']', '{', '}', ',', '.', '='];
  const DIGITS = { b: /^[01xz?]+$/, o: /^[0-7xz?]+$/, h: /^[0-9a-fxz?]+$/, d: /^(\d+|[xz?])$/ };

  // Literal digits as bits for `base`; null when they are not that base's.
  function digitBits(digits, base) {
    const d = digits.toLowerCase();
    if (!DIGITS[base].test(d)) { return null; }
    if (base === 'd') { return /^[xz?]$/.test(d) ? d.replace('?', 'z') : BigInt(d).toString(2); }
    const per = base === 'b' ? 1 : (base === 'o' ? 3 : 4);
    let bits = '';
    for (const c of d) {
      if ('xz?'.includes(c)) { bits += (c === '?' ? 'z' : c).repeat(per); continue; }
      bits += parseInt(c, 16).toString(2).padStart(per, '0');
    }
    return bits;
  }

  // Bits fitted to `size`: extended as fromBits does; cut only when what goes is all 0 (or all
  // the same x or z); null otherwise.
  function fit(bits, size) {
    if (bits.length <= size) { return bits; }
    const cut = bits.slice(0, bits.length - size);
    return /^0+$/.test(cut) || /^x+$/.test(cut) || /^z+$/.test(cut) ? bits.slice(bits.length - size) : null;
  }

  function tokenize(text) {
    const tokens = [];
    let i = 0;
    const n = text.length;
    const space = () => { while (i < n && /\s/.test(text[i])) { i++; } };
    // A based literal at text[i] === "'": [size] 's? base digits. `at` is where it started.
    const based = (at, size) => {
      const m = /^'([sS]?)([bBoOdDhH])/.exec(text.slice(i));
      i += m[0].length;
      space();
      const start = i;
      while (i < n && /[0-9a-fA-FxXzZ?_]/.test(text[i])) { i++; }
      const digits = text.slice(start, i).replace(/_/g, '');
      if (!digits) { fail('badLiteral', at); }
      const bits = digitBits(digits, m[2].toLowerCase());
      if (bits === null) { fail('badLiteral', at); }
      let width = size;
      if (width === null) { width = Math.max(32, bits.length); } else if (!(width >= 1 && width <= MAX_WIDTH)) { fail('badLiteral', at); }
      const fitted = fit(bits, width);
      if (fitted === null) { fail('badLiteral', at); }
      // Unsized with a leftmost x or z digit: that x/z fills whatever width the context gives (5.7.1).
      const fill = size === null && (fitted[0] === 'x' || fitted[0] === 'z') ? fitted[0] : null;
      tokens.push({ t: 'lit', at, v: fromBits(fitted, width), fill, signed: m[1] !== '', unsized: size === null });
    };
    for (;;) {
      space();
      if (i >= n) { break; }
      const at = i;
      const c = text[i];
      if (c === '\\') {
        let j = i + 1;
        while (j < n && !/\s/.test(text[j])) { j++; }
        if (j === i + 1) { fail('syntax', at); }
        tokens.push({ t: 'id', at, name: text.slice(i + 1, j) });
        i = j;
      } else if (/[A-Za-z_]/.test(c)) {
        let j = i + 1;
        while (j < n && /[A-Za-z0-9_$]/.test(text[j])) { j++; }
        tokens.push({ t: 'id', at, name: text.slice(i, j) });
        i = j;
      } else if (c === '$') {
        fail('unsupported', at);
      } else if (/[0-9]/.test(c)) {
        let j = i;
        while (j < n && /[0-9_]/.test(text[j])) { j++; }
        const digits = text.slice(i, j).replace(/_/g, '');
        i = j;
        space();
        if (/^'[sS]?[bBoOdDhH]/.test(text.slice(i))) {
          based(at, Number(digits));
        } else {
          i = j;
          const big = BigInt(digits);
          // Wider than 32 bits: one more, so the signed value stays positive (slang, 1800-2023).
          const bits = big.toString(2).length;
          const width = bits > 32 ? bits + 1 : 32;
          if (width > MAX_WIDTH) { fail('badLiteral', at); }
          // An unsized decimal number is a signed integer (5.7.1).
          tokens.push({ t: 'lit', at, v: val(width, big, 0n), text: digits, signed: true, unsized: true });
        }
      } else if (c === "'") {
        if (/^'[sS]?[bBoOdDhH]/.test(text.slice(i))) {
          based(at, null);
        } else if (/^'[01xXzZ](?![0-9A-Za-z_])/.test(text.slice(i))) {
          tokens.push({ t: 'fill', at, bit: text[i + 1].toLowerCase() });
          i += 2;
        } else {
          fail('badLiteral', at);
        }
      } else {
        const op = OPERATORS.find((o) => text.startsWith(o, i));
        if (!op) { fail('syntax', at); }
        tokens.push({ t: 'op', at, op });
        i += op.length;
      }
    }
    tokens.push({ t: 'end', at: n });
    return tokens;
  }

  // ---- grammar (precedence climbing; binding power, tighter is higher) ----
  const BINARY = { '||': 2, '&&': 3, '|': 4, '^': 5, '~^': 5, '^~': 5, '&': 6, '==': 7, '!=': 7, '===': 7, '!==': 7,
    '<': 8, '<=': 8, '>': 8, '>=': 8, '<<': 9, '>>': 9, '<<<': 9, '>>>': 9, '+': 10, '-': 10, '*': 11 };
  const UNSUPPORTED = new Set(['/', '%', '**', '==?', '!=?', '=']);
  const UNARY = new Set(['!', '~', '+', '-', '&', '|', '^', '~&', '~|', '~^', '^~']);

  function parser(tokens) {
    let k = 0;
    const peek = (o = 0) => tokens[k + o];
    const isOp = (tok, op) => tok.t === 'op' && tok.op === op;
    const expect = (op) => { const tok = peek(); if (!isOp(tok, op)) { fail('syntax', tok.at); } k++; return tok; };

    function expr(minBp) {
      let left = unary();
      for (;;) {
        const tok = peek();
        if (tok.t !== 'op') { return left; }
        if (UNSUPPORTED.has(tok.op)) { fail('unsupported', tok.at); }
        if (tok.op === '?' && minBp <= 1) {
          k++;
          const a = expr(0);
          expect(':');
          const b = expr(1);
          left = { t: 'cond', at: tok.at, c: left, a, b };
          continue;
        }
        const bp = BINARY[tok.op];
        if (!bp || bp < minBp) { return left; }
        k++;
        left = { t: 'bin', at: tok.at, op: tok.op, l: left, r: expr(bp + 1) };
      }
    }

    function unary() {
      const tok = peek();
      if (tok.t === 'op' && UNARY.has(tok.op)) {
        k++;
        return { t: 'un', at: tok.at, op: tok.op, e: unary() };
      }
      return postfix(primary());
    }

    function primary() {
      const tok = peek();
      if (tok.t === 'lit') { k++; return { t: 'lit', at: tok.at, v: tok.v, fill: tok.fill || null, signed: !!tok.signed, unsized: !!tok.unsized }; }
      if (tok.t === 'fill') { k++; return { t: 'fill', at: tok.at, bit: tok.bit }; }
      if (tok.t === 'id') {
        k++;
        const path = [tok.name];
        for (;;) {
          // gen[0].q: a constant index followed by a dot names a generate scope.
          if (isOp(peek(), '[') && peek(1).t === 'lit' && peek(1).text !== undefined && isOp(peek(2), ']') && isOp(peek(3), '.')) {
            path[path.length - 1] += '[' + peek(1).text + ']';
            k += 3;
          }
          if (!isOp(peek(), '.')) { break; }
          k++;
          const next = peek();
          if (next.t !== 'id') { fail('syntax', next.at); }
          k++;
          path.push(next.name);
        }
        return { t: 'name', at: tok.at, path };
      }
      if (isOp(tok, '(')) {
        k++;
        const e = expr(0);
        expect(')');
        return e;
      }
      if (isOp(tok, '{')) {
        k++;
        const first = expr(0);
        if (isOp(peek(), '{')) {
          k++;
          const parts = [expr(0)];
          while (isOp(peek(), ',')) { k++; parts.push(expr(0)); }
          expect('}');
          expect('}');
          const n = constant(first);
          if (n === null || n < 1) { fail('badReplication', first.at); }
          parts.forEach(noFill);
          return { t: 'rep', at: tok.at, n, e: { t: 'cat', at: tok.at, parts } };
        }
        const parts = [first];
        while (isOp(peek(), ',')) { k++; parts.push(expr(0)); }
        expect('}');
        parts.forEach(noFill);
        return { t: 'cat', at: tok.at, parts };
      }
      fail('syntax', tok.at);
      return null;
    }

    function postfix(e) {
      let node = e;
      while (isOp(peek(), '[')) {
        const open = peek();
        k++;
        const i = expr(0);
        const tok = peek();
        if (isOp(tok, ':')) {
          k++;
          const j = expr(0);
          expect(']');
          const m = constant(i), l = constant(j);
          if (m === null || l === null) { fail('notConstant', (m === null ? i : j).at); }
          node = { t: 'sel', at: open.at, kind: 'part', e: node, m, l };
        } else if (isOp(tok, '+:') || isOp(tok, '-:')) {
          k++;
          const wNode = expr(0);
          expect(']');
          const w = constant(wNode);
          if (w === null || w < 1) { fail('notConstant', wNode.at); }
          node = { t: 'sel', at: open.at, kind: tok.op === '+:' ? 'up' : 'down', e: node, i, w };
        } else {
          expect(']');
          node = { t: 'sel', at: open.at, kind: 'bit', e: node, i };
        }
      }
      return node;
    }

    return { expr, peek };
  }

  // An unbased unsized literal ('1) has no width of its own: not in a concatenation.
  // A concatenation's parts have widths of their own: no '0/'1/'x/'z, and no unsized number
  // (11.4.12; slang and Icarus refuse it, VCS takes it as 32 bits).
  function noFill(node) {
    if (node.t === 'fill') { fail('badLiteral', node.at); }
    if (node.t === 'lit' && node.unsized) { fail('unsizedInConcat', node.at); }
  }

  function firstName(node) {
    if (!node || typeof node !== 'object') { return null; }
    if (node.t === 'name') { return node; }
    for (const key of ['e', 'l', 'r', 'c', 'a', 'b', 'i']) {
      const found = firstName(node[key]);
      if (found) { return found; }
    }
    for (const part of node.parts || []) { const found = firstName(part); if (found) { return found; } }
    return null;
  }

  // A constant expression's value as a number (no names; known; not huge); null when it is not one.
  function constant(node) {
    const name = firstName(node);
    if (name) { fail('notConstant', name.at); }
    const v = evaluateNode(node, () => null);
    if (v.b !== 0n || v.a > 1000000n) { return null; }
    return Number(v.a);
  }

  // `options` ({ maxText, maxSignals }) lifts the user-facing caps for internal callers (the trace
  // engine's lowered RTL); anything but a number >= 0 keeps the default.
  const capOf = (value, fallback) => (typeof value === 'number' && value >= 0 ? value : fallback);

  function parse(text, options) {
    const s = String(text === undefined || text === null ? '' : text);
    const maxText = capOf((options || {}).maxText, MAX_TEXT), maxSignals = capOf((options || {}).maxSignals, MAX_SIGNALS);
    try {
      if (s.length > maxText) { fail('tooLong', 0); }
      if (!s.trim()) { fail('empty', s.length); }
      const tokens = tokenize(s);
      const p = parser(tokens);
      const ast = p.expr(0);
      const rest = p.peek();
      if (rest.t !== 'end') {
        if (rest.t === 'op' && UNSUPPORTED.has(rest.op)) { fail('unsupported', rest.at); }
        fail('syntax', rest.at);
      }
      const seen = new Set();
      walkNames(ast, (node) => {
        const key = JSON.stringify(node.path);
        if (seen.has(key)) { return; }
        seen.add(key);
        if (seen.size > maxSignals) { fail('tooManySignals', node.at); }
      });
      return { ast };
    } catch (error) {
      if (error && error.exprError) { return { error: error.exprError, at: error.at }; }
      throw error;
    }
  }

  function walkNames(node, visit) {
    if (!node || typeof node !== 'object') { return; }
    if (node.t === 'name') { visit(node); return; }
    for (const key of ['c', 'l', 'e', 'i', 'r', 'a', 'b']) { walkNames(node[key], visit); }
    for (const part of node.parts || []) { walkNames(part, visit); }
  }

  function names(ast) {
    const out = [];
    const seen = new Set();
    walkNames(ast, (node) => {
      const key = JSON.stringify(node.path);
      if (!seen.has(key)) { seen.add(key); out.push(node.path.slice()); }
    });
    return out;
  }

  // ---- values ----
  const ARITH = new Set(['+', '-', '*']);
  const BITWISE = new Set(['&', '|', '^', '~^', '^~']);
  const COMPARE = new Set(['==', '!=', '===', '!==', '<', '<=', '>', '>=']);
  const SHIFT = new Set(['<<', '>>', '<<<', '>>>']);

  function evaluateNode(rootNode, env) {
    const signals = new Map();
    const signal = (node) => {
      if (!signals.has(node)) {
        const s = env(node.path);
        if (!s) { fail('unknownName', node.at); }
        signals.set(node, s);
      }
      return signals.get(node);
    };
    const widths = new Map();
    function width(node) {
      if (widths.has(node)) { return widths.get(node); }
      let w;
      switch (node.t) {
        case 'lit': w = node.v.w; break;
        case 'fill': w = 1; break;
        case 'name': w = Number(signal(node).width) || 1; break;
        case 'un': w = ['+', '-', '~'].includes(node.op) ? width(node.e) : 1; break;
        case 'bin':
          if (ARITH.has(node.op) || BITWISE.has(node.op)) { w = Math.max(width(node.l), width(node.r)); } else if (SHIFT.has(node.op)) { w = width(node.l); width(node.r); } else { width(node.l); width(node.r); w = 1; }
          break;
        case 'cond': width(node.c); w = Math.max(width(node.a), width(node.b)); break;
        case 'cat': w = node.parts.reduce((sum, p) => sum + width(p), 0); break;
        case 'rep': w = node.n * width(node.e); break;
        case 'sel':
          width(node.e);
          if (node.i) { width(node.i); }
          w = node.kind === 'bit' ? 1 : (node.kind === 'part' ? Math.abs(node.m - node.l) + 1 : node.w);
          break;
        default: fail('syntax', node.at);
      }
      if (w > MAX_WIDTH) { fail('tooWide', node.at); }
      widths.set(node, w);
      return w;
    }

    // The declared range a select indexes: the signal's, else [w-1:0].
    function range(node) {
      const w = width(node);
      if (node.t === 'name') {
        const s = signal(node);
        const msb = Number(s.msb), lsb = Number(s.lsb);
        if (Number.isInteger(msb) && Number.isInteger(lsb) && Math.abs(msb - lsb) + 1 === w) { return { msb, lsb, w }; }
      }
      return { msb: w - 1, lsb: 0, w };
    }

    // The bits of `v` at declared indices `indices` (result bit 0 first); out of range is x.
    function pick(v, r, indices) {
      let a = 0n, b = 0n;
      indices.forEach((index, k) => {
        const off = r.msb >= r.lsb ? index - r.lsb : r.lsb - index;
        const bit = BigInt(k);
        if (!(off >= 0 && off < r.w)) { a |= 1n << bit; b |= 1n << bit; return; }
        const o = BigInt(off);
        a |= ((v.a >> o) & 1n) << bit;
        b |= ((v.b >> o) & 1n) << bit;
      });
      return val(indices.length, a, b);
    }

    // Whether a node's self-determined type is signed (11.8.1, as slang's propagateType has it):
    // unsized decimals, 's literals and signed signals are; an operator whose operands are context
    // determined is signed when all of them are; shifts and unary +, -, ~ take their operand's;
    // comparisons, reductions, logical operators, selects and concatenations are unsigned.
    const signs = new Map();
    function signed(node) {
      if (signs.has(node)) { return signs.get(node); }
      let s = false;
      switch (node.t) {
        case 'lit': s = !!node.signed; break;
        case 'name': s = signal(node).signed === true; break;
        case 'un': s = ['+', '-', '~'].includes(node.op) && signed(node.e); break;
        case 'bin':
          if (ARITH.has(node.op) || BITWISE.has(node.op)) { s = signed(node.l) && signed(node.r); } else if (SHIFT.has(node.op)) { s = signed(node.l); }
          break;
        case 'cond': s = signed(node.a) && signed(node.b); break;
        default: s = false;
      }
      signs.set(node, s);
      return s;
    }

    // A select index: a number (negative when signed), or null when it has an x or z bit.
    const index = (node) => {
      const v = ev(node, width(node), signed(node));
      if (v.b !== 0n) { return null; }
      const n = signed(node) ? signedOf(v) : v.a;
      return n > 1000000000n ? 1000000000 : (n < -1000000000n ? -1000000000 : Number(n));
    };

    // `node` at width w in a context that is signed (s) or not; operands of a signed context are
    // signed themselves, so leaves extend with their top bit exactly when s is set.
    function ev(node, w, s) {
      switch (node.t) {
        case 'lit': {
          if (!node.fill || w <= node.v.w) { return extend(node.v, w, s); }
          const high = maskOf(w) & ~maskOf(node.v.w);
          return val(w, node.v.a | (node.fill === 'x' ? high : 0n), node.v.b | high);
        }
        case 'fill': {
          const m = maskOf(w);
          return node.bit === '0' ? val(w, 0n, 0n) : (node.bit === '1' ? val(w, m, 0n) : (node.bit === 'x' ? allX(w) : val(w, 0n, m)));
        }
        case 'name': return extend(signal(node).value, w, s);
        case 'un': {
          // Unary plus is the operand itself (slang: OP(Plus, v)); minus of any unknown is all x.
          if (node.op === '+') { return ev(node.e, w, s); }
          if (node.op === '-') {
            const v = ev(node.e, w, s);
            return v.b !== 0n ? allX(w) : val(w, -v.a, 0n);
          }
          if (node.op === '~') { const v = ev(node.e, w, s); return fromKnown(w, zeros(v), ones(v)); }
          const v = ev(node.e, width(node.e), signed(node.e));
          let t;
          if (node.op === '!') {
            const x = truth(v);
            t = x === 'x' ? 'x' : 1 - x;
          } else {
            const op = node.op.replace('^~', '~^');
            const base = op.replace('~', '');
            if (base === '&') { t = zeros(v) !== 0n ? 0 : (v.b === 0n ? 1 : 'x'); }
            if (base === '|') { t = ones(v) !== 0n ? 1 : (v.b === 0n ? 0 : 'x'); }
            if (base === '^') {
              if (v.b !== 0n) { t = 'x'; } else { let p = 0; for (let a = v.a; a; a &= a - 1n) { p ^= 1; } t = p; }
            }
            if (op.startsWith('~') && t !== 'x') { t = 1 - t; }
          }
          return ext(bit1(t), w);
        }
        case 'bin': {
          const op = node.op;
          if (ARITH.has(op) || BITWISE.has(op)) {
            const l = ev(node.l, w, s), r = ev(node.r, w, s);
            const m = maskOf(w);
            if (op === '&') { return fromKnown(w, ones(l) & ones(r), zeros(l) | zeros(r)); }
            if (op === '|') { return fromKnown(w, ones(l) | ones(r), zeros(l) & zeros(r)); }
            if (BITWISE.has(op)) {
              const u = l.b | r.b;
              const diff = (l.a ^ r.a) & ~u & m;
              const same = ~(l.a ^ r.a) & ~u & m;
              return op === '^' ? fromKnown(w, diff, same) : fromKnown(w, same, diff);
            }
            if (l.b !== 0n || r.b !== 0n) { return allX(w); }
            return val(w, op === '+' ? l.a + r.a : (op === '-' ? l.a - r.a : l.a * r.a), 0n);
          }
          if (SHIFT.has(op)) {
            const l = ev(node.l, w, s);
            // The amount is self-determined and always unsigned (11.4.10).
            const amount = ev(node.r, width(node.r), signed(node.r));
            if (amount.b !== 0n) { return allX(w); }
            // >>> of a signed value shifts in its top bit, x and z included (slang: SVInt::ashr).
            if (op === '>>>' && s) {
              const n = amount.a >= BigInt(w) ? BigInt(w - 1) : amount.a;
              return sext(val(w - Number(n), l.a >> n, l.b >> n), w);
            }
            if (amount.a >= BigInt(w)) { return val(w, 0n, 0n); }
            return op.startsWith('<') ? val(w, l.a << amount.a, l.b << amount.a) : val(w, l.a >> amount.a, l.b >> amount.a);
          }
          if (COMPARE.has(op)) {
            const cw = Math.max(width(node.l), width(node.r));
            const cs = signed(node.l) && signed(node.r);
            const l = ev(node.l, cw, cs), r = ev(node.r, cw, cs);
            let t;
            if (op === '===' || op === '!==') {
              t = l.a === r.a && l.b === r.b ? 1 : 0;
              if (op === '!==') { t = 1 - t; }
            } else if (op === '==' || op === '!=') {
              const mismatch = (ones(l) & zeros(r)) | (zeros(l) & ones(r));
              t = mismatch !== 0n ? 0 : ((l.b | r.b) !== 0n ? 'x' : 1);
              if (op === '!=' && t !== 'x') { t = 1 - t; }
            } else if (l.b !== 0n || r.b !== 0n) {
              t = 'x';
            } else {
              const x = cs ? signedOf(l) : l.a, y = cs ? signedOf(r) : r.a;
              t = (op === '<' ? x < y : op === '<=' ? x <= y : op === '>' ? x > y : x >= y) ? 1 : 0;
            }
            return ext(bit1(t), w);
          }
          // && and ||
          const l = truth(ev(node.l, width(node.l), signed(node.l))), r = truth(ev(node.r, width(node.r), signed(node.r)));
          let t;
          if (op === '&&') { t = l === 0 || r === 0 ? 0 : (l === 1 && r === 1 ? 1 : 'x'); } else { t = l === 1 || r === 1 ? 1 : (l === 0 && r === 0 ? 0 : 'x'); }
          return ext(bit1(t), w);
        }
        case 'cond': {
          const t = truth(ev(node.c, width(node.c), signed(node.c)));
          if (t === 1) { return ev(node.a, w, s); }
          if (t === 0) { return ev(node.b, w, s); }
          const a = ev(node.a, w, s), b = ev(node.b, w, s);
          // An unknown condition: bits both arms agree are 0 or 1 keep it, every other bit is x,
          // z and z included (11.4.11 table 11-20, as VCS does). slang's SVInt::conditional keeps
          // equal arms whole (z stays z); this follows the LRM and VCS instead.
          return fromKnown(w, ones(a) & ones(b), zeros(a) & zeros(b));
        }
        case 'cat': {
          let a = 0n, b = 0n, total = 0;
          for (const part of node.parts) {
            const pw = width(part);
            const v = ev(part, pw, signed(part));
            a = (a << BigInt(pw)) | v.a;
            b = (b << BigInt(pw)) | v.b;
            total += pw;
          }
          return ext(val(total, a, b), w);
        }
        case 'rep': {
          const inner = ev(node.e, width(node.e), signed(node.e));
          let a = 0n, b = 0n;
          const step = BigInt(inner.w);
          for (let n = 0; n < node.n; n++) { a = (a << step) | inner.a; b = (b << step) | inner.b; }
          return ext(val(inner.w * node.n, a, b), w);
        }
        case 'sel': {
          const v = ev(node.e, width(node.e), signed(node.e));
          const r = range(node.e);
          const descending = r.msb >= r.lsb;
          let indices;
          if (node.kind === 'part') {
            const n = Math.abs(node.m - node.l) + 1;
            const step = node.m >= node.l ? 1 : -1;
            indices = Array.from({ length: n }, (_, k) => node.l + step * k);
          } else {
            const i = index(node.i);
            const n = node.kind === 'bit' ? 1 : node.w;
            if (i === null) { return ext(allX(n), w); }
            if (node.kind === 'bit') {
              indices = [i];
            } else if (node.kind === 'up') {
              indices = Array.from({ length: n }, (_, k) => (descending ? i + k : i + n - 1 - k));
            } else {
              indices = Array.from({ length: n }, (_, k) => (descending ? i - n + 1 + k : i - k));
            }
          }
          return ext(pick(v, r, indices), w);
        }
        default: fail('syntax', node.at);
      }
      return null;
    }
    return ev(rootNode, width(rootNode), signed(rootNode));
  }

  function evaluate(ast, env) {
    try {
      return { value: evaluateNode(ast, env || (() => null)) };
    } catch (error) {
      if (error && error.exprError) { return { error: error.exprError, at: error.at }; }
      throw error;
    }
  }

  // ---- display ----
  const bitChar = (v, i) => {
    const a = (v.a >> BigInt(i)) & 1n, b = (v.b >> BigInt(i)) & 1n;
    return b ? (a ? 'x' : 'z') : (a ? '1' : '0');
  };

  function toBits(v) {
    let s = '';
    for (let i = v.w - 1; i >= 0; i--) { s += bitChar(v, i); }
    return s;
  }

  // A group of bits as one digit: x or z when all are, X when some are x, Z when some are z.
  function digit(bits) {
    if (/^[01]+$/.test(bits)) { return parseInt(bits, 2).toString(16); }
    if (/^x+$/.test(bits)) { return 'x'; }
    if (/^z+$/.test(bits)) { return 'z'; }
    return bits.includes('x') ? 'X' : 'Z';
  }

  function format(v, radix) {
    const bits = toBits(v);
    if (radix === 'binary') { return v.w + "'b" + bits; }
    if (radix === 'decimal') {
      if (v.b === 0n) { return v.w + "'d" + v.a.toString(10); }
      // As $display's %d: x or z when every bit is, X or Z when some are (x first).
      if (/^x+$/.test(bits)) { return v.w + "'dx"; }
      if (/^z+$/.test(bits)) { return v.w + "'dz"; }
      return v.w + "'d" + (bits.includes('x') ? 'X' : 'Z');
    }
    const per = radix === 'octal' ? 3 : 4;
    let out = '';
    for (let end = bits.length; end > 0; end -= per) { out = digit(bits.slice(Math.max(0, end - per), end)) + out; }
    return v.w + (per === 3 ? "'o" : "'h") + out;
  }

  const truthy = (v) => ones(v) !== 0n;
  const same = (x, y) => !!x && !!y && x.w === y.w && x.a === y.a && x.b === y.b;

  root.cmuxExpr = Object.freeze({ parse, names, evaluate, format, truthy, same, fromBits, toBits, MAX_SIGNALS, MAX_TEXT, MAX_WIDTH });
})(typeof window !== 'undefined' ? window : globalThis);
