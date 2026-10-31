// Part of cmux's FSDB helper v2, written for cmux. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), whose helper it extends; see ../LICENSE.
// Derived-signal expressions for FSDB helper v2: a SystemVerilog subset,
// parsed here and compiled into the flat program addon/deval.h runs.
//
//   {a, b[3:0], 2'b01}  {4{a}}  a[3]  a[7:0]  ~ & | ^ ~^  unary & | ^ ~& ~| ~^ (reduce)
//   ! && ||  == != === !==  < > <= >=  + - * / %  << >> <<< >>>  ?:  ( )
//   $signed(e) $unsigned(e)
//   literals: 8'hff 4'b10x1 4'sd5 'd12 12 (unsized = 32 bits; plain decimals are signed)
//   signals: full hierarchical paths (tb.dut.x, tb.gen[0].u.x, tb.mon.pc_rdata[0]), a
//   unique path suffix, or ids as #1916; `$` is the candidate signal in searchAll.
//
// Sizing follows IEEE 1800 §11.6/§11.8: each operand has a self-determined
// width and signedness; context-determined operands (+ - * / % & | ^ ~^ ~ and
// unary -, the arms of ?:, the two sides of a comparison against each other,
// the left side of a shift) are extended to the largest width in their
// context, sign-extended only if the whole context is signed. Comparisons,
// reductions, logical ops, concatenation, replication and selects are
// self-determined and unsigned (1 bit for the first three); the shift amount
// and the ?: condition are self-determined. So (a + b) == 9'h100 with 8-bit a
// and b adds in 9 bits and sees the carry; a derive's own width is its
// self-determined width (a + b alone stays 8 bits). === and !== compare
// 4-state exactly, but the dump's z reads as x, so z === x is 1. Declared
// signedness comes from the var type (integer/int/... are signed; this
// reader reports plain reg/wire for logic signed, so use $signed there).
'use strict';

const OPS = ['SIG', 'CONST', 'SEL', 'CONCAT', 'REPL', 'NOT', 'AND', 'OR', 'XOR', 'RAND', 'ROR', 'RXOR',
  'LNOT', 'LAND', 'LOR', 'EQ', 'NE', 'LT', 'GT', 'LE', 'GE', 'ADD', 'SUB', 'TERN', 'BOOL',
  'EXT', 'MUL', 'DIV', 'MOD', 'SHL', 'SHR', 'ASHR', 'CEQ', 'CNE'];  // order = DOp in addon/deval.h
const OP = Object.fromEntries(OPS.map((n, i) => [n, i]));
const MAX_BITS = 65536;      // any node; addon/deval.h enforces the same
const MAX_EXPR_CHARS = 65536;
const MAX_NODES = 100000;

const tooWide = () => new Error(`expression wider than ${MAX_BITS} bits`);

// ---- literals ----
// '8'hff' -> {bits: MSB-first string of exactly `width` chars ('0' '1' 'x'), signed}.
function literal(text) {
  const m = /^(\d+)?'([sS]?)([bBoOdDhH])([0-9a-fA-FxXzZ?_]+)$/.exec(text);
  let width, digits, base, signed;
  if (m) {
    if (m[1] && m[1].length > 6) { throw new Error(`bad literal width ${text}`); }
    width = m[1] ? Number(m[1]) : 32;
    signed = !!m[2];
    base = m[3].toLowerCase();
    digits = m[4].replace(/_/g, '').toLowerCase().replace(/[z?]/g, 'x');
  } else if (/^\d[\d_]*$/.test(text)) {
    width = 32; base = 'd'; digits = text.replace(/_/g, ''); signed = true;
  } else {
    throw new Error(`bad literal ${text}`);
  }
  if (!(width >= 1 && width <= MAX_BITS)) { throw new Error(`bad literal width ${text}`); }
  if (digits.length > MAX_BITS) { throw new Error(`literal too long ${text.slice(0, 20)}...`); }
  let bits;
  if (base === 'd') {
    if (/x/.test(digits)) { bits = digits.length === 1 ? 'x' : null; if (!bits) { throw new Error(`bad decimal ${text}`); } }
    else { bits = BigInt(digits).toString(2); }
  } else {
    const per = { b: 1, o: 3, h: 4 }[base];
    bits = '';
    for (const ch of digits) {
      if (ch === 'x') { bits += 'x'.repeat(per); continue; }
      const v = parseInt(ch, 1 << per);
      if (Number.isNaN(v)) { throw new Error(`bad digit in ${text}`); }
      bits += v.toString(2).padStart(per, '0');
    }
  }
  // SV: a leading x extends with x, otherwise zero-extend; truncate on the left.
  if (bits.length < width) { bits = (bits[0] === 'x' ? 'x' : '0').repeat(width - bits.length) + bits; }
  return { bits: bits.slice(bits.length - width), signed };
}
const literalBits = (text) => literal(text).bits;

// ---- tokenizer ----
const PUNCT = ['===', '!==', '<<<', '>>>', '&&', '||', '==', '!=', '<=', '>=', '<<', '>>', '~^', '^~', '~&', '~|', '**',
  '(', ')', '{', '}', '[', ']', ',', ':', '?', '~', '!', '&', '|', '^', '<', '>', '+', '-', '*', '/', '%'];
// A path may hold generate indices inside it (tb.gen[0].u.x); a trailing
// [n] stays a select and is resolved against the names by the compiler.
const PATH_RE = /^[A-Za-z_][\w$]*(?:(?:\[\d+\])*\.[A-Za-z_$][\w$]*)*/;
function tokenize(src) {
  const toks = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (/\s/.test(c)) { i++; continue; }
    let m;
    const rest = src.slice(i, i + 4096);  // longest token we accept
    if ((m = /^(\d+)?'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ?_]+/.exec(rest)) || (m = /^\d[\d_]*/.exec(rest))) {
      toks.push({ t: 'lit', v: m[0], at: i }); i += m[0].length; continue;
    }
    if ((m = /^#(\d+)/.exec(rest))) { toks.push({ t: 'id', v: Number(m[1]), at: i }); i += m[0].length; continue; }
    if ((m = /^\$(signed|unsigned)\b/.exec(rest))) { toks.push({ t: 'cast', v: m[1], at: i }); i += m[0].length; continue; }
    if (c === '$' && !/^\$[A-Za-z_]/.test(rest)) { toks.push({ t: 'cand', at: i }); i++; continue; }
    if (c === '$') { throw new Error(`unknown system function at ${i}`); }
    if ((m = PATH_RE.exec(rest))) { toks.push({ t: 'path', v: m[0], at: i }); i += m[0].length; continue; }
    const p = PUNCT.find((s) => rest.startsWith(s));
    if (!p) { throw new Error(`unexpected '${c}' at ${i}`); }
    if (p === '**') { throw new Error(`'**' is not supported (at ${i})`); }
    toks.push({ t: p, at: i }); i += p.length;
  }
  toks.push({ t: 'end', at: src.length });
  return toks;
}

// ---- parser -> AST ----
function parse(src) {
  src = String(src);
  if (src.length > MAX_EXPR_CHARS) { throw new Error(`expression longer than ${MAX_EXPR_CHARS} characters`); }
  const toks = tokenize(src);
  let p = 0;
  const peek = () => toks[p];
  const eat = (t) => { if (toks[p].t !== t) { throw new Error(`expected '${t}' at ${toks[p].at}, got '${toks[p].v ?? toks[p].t}'`); } return toks[p++]; };
  const accept = (...ts) => (ts.includes(toks[p].t) ? toks[p++] : null);

  function expr() {
    const c = lor();
    if (accept('?')) { const a = expr(); eat(':'); const b = expr(); return { k: 'TERN', c, a, b }; }
    return c;
  }
  const binary = (next, ops) => () => {
    let l = next();
    for (let o; (o = accept(...Object.keys(ops)));) { l = { k: ops[o.t], a: l, b: next() }; }
    return l;
  };
  const mul = binary(unary, { '*': 'MUL', '/': 'DIV', '%': 'MOD' });
  const add = binary(mul, { '+': 'ADD', '-': 'SUB' });
  const shift = binary(add, { '<<': 'SHL', '>>': 'SHR', '<<<': 'SHL', '>>>': 'ASHR' });
  const rel = binary(shift, { '<': 'LT', '>': 'GT', '<=': 'LE', '>=': 'GE' });
  const eq = binary(rel, { '==': 'EQ', '!=': 'NE', '===': 'CEQ', '!==': 'CNE' });
  const band = binary(eq, { '&': 'AND' });
  const bxor = binary(band, { '^': 'XOR', '~^': 'XNOR', '^~': 'XNOR' });
  const bor = binary(bxor, { '|': 'OR' });
  const land = binary(bor, { '&&': 'LAND' });
  const lor = binary(land, { '||': 'LOR' });

  function unary() {
    const o = accept('~', '!', '&', '|', '^', '~&', '~|', '~^', '^~', '-', '+');
    if (!o) { return primary(); }
    const a = unary();
    return { k: { '~': 'NOT', '!': 'LNOT', '&': 'RAND', '|': 'ROR', '^': 'RXOR', '~&': 'RNAND', '~|': 'RNOR', '~^': 'RXNOR', '^~': 'RXNOR', '-': 'NEG', '+': 'POS' }[o.t], a };
  }
  function selects() {
    const out = [];
    while (peek().t === '[') {
      eat('[');
      const mt = eat('lit').v;
      let lt = mt;
      if (accept(':')) { lt = eat('lit').v; }
      eat(']');
      if (!/^\d{1,9}$/.test(mt) || !/^\d{1,9}$/.test(lt)) { throw new Error('select bounds must be decimal integers'); }
      out.push([Number(mt), Number(lt)]);
    }
    return out;
  }
  function primary() {
    const t = peek();
    if (accept('(')) { const e = expr(); eat(')'); return e; }
    if (accept('{')) {
      const first = expr();
      if (accept('{')) {  // replication {n{a, b}}
        const parts = [expr()];
        while (accept(',')) { parts.push(expr()); }
        eat('}'); eat('}');
        return { k: 'REPL', n: first, a: parts.length === 1 ? parts[0] : { k: 'CONCAT', args: parts } };
      }
      const parts = [first];
      while (accept(',')) { parts.push(expr()); }
      eat('}');
      return { k: 'CONCAT', args: parts };
    }
    if (accept('lit')) { const l = literal(t.v); return { k: 'LIT', bits: l.bits, signed: l.signed, text: t.v }; }
    if (accept('cast')) { eat('('); const a = expr(); eat(')'); return { k: 'CAST', signed: t.v === 'signed', a }; }
    if (accept('id')) { return { k: 'REF', id: t.v, sel: selects() }; }
    if (accept('cand')) { return { k: 'CAND', sel: selects() }; }
    if (accept('path')) { return { k: 'REF', path: t.v, sel: selects() }; }
    throw new Error(`unexpected '${t.v ?? t.t}' at ${t.at}`);
  }
  const e = expr();
  eat('end');
  return e;
}

// ---- compile AST -> program ----
// resolve(ref) -> {signalId, width, msb, lsb, path, signed?, sel}; ref = {path, sel} | {id, sel}.
// Returns {program, operands: [signalId], width, signed, refs: [path]}. With
// cand ({width}), `$` becomes operand 0.
function compile(ast, resolve, cand) {
  const program = [];
  const operands = cand ? ['$'] : [];  // `$` is always operand 0
  const sigNode = new Map();
  const refs = [];
  const push = (n) => {
    if (program.length >= MAX_NODES) { throw new Error('expression too large'); }
    program.push(n); return program.length - 1;
  };
  const w = (i) => program[i].w;
  const sig = (id, width) => {
    if (!sigNode.has(id)) {
      let k = operands.indexOf(id);
      if (k < 0) { k = operands.length; operands.push(id); }
      sigNode.set(id, push({ op: OP.SIG, w: width, k }));
    }
    return sigNode.get(id);
  };
  const constOf = (bits) => push({ op: OP.CONST, w: bits.length, bits });
  const ext = (n, W, S) => (w(n) === W ? n : push({ op: OP.EXT, w: W, a: n, s: S ? 1 : 0 }));
  const constValue = (node) => {  // replication counts must be constant
    if (node.k !== 'LIT' || /x/.test(node.bits)) { throw new Error('replication count must be a known constant'); }
    const n = BigInt('0b' + node.bits);
    if (n < 1n) { throw new Error('replication count must be >= 1'); }
    if (n > BigInt(MAX_BITS)) { throw tooWide(); }
    return Number(n);
  };
  // LSB-index of declared bit i for a [msb:lsb] vector.
  const bitIndex = (v, i) => (v.msb >= v.lsb ? i - v.lsb : v.lsb - i);
  const selWidths = (v, sel) => {  // -> [{lo, width}] per select, vector re-based after each
    const out = [];
    for (const [m, l] of sel) {
      const a = bitIndex(v, m), b = bitIndex(v, l);
      const lo = Math.min(a, b), width = Math.abs(a - b) + 1;
      if (width > MAX_BITS || Math.abs(lo) > MAX_BITS) { throw tooWide(); }
      out.push({ lo, width });
      v = { msb: width - 1, lsb: 0 };
    }
    return out;
  };
  const isSignedType = (v) => !!v.signed;

  // Pass 1: self-determined width and signedness of every node (memoized).
  function size(e) {
    if (e._w !== undefined) { return e; }
    let W, S = false;
    switch (e.k) {
      case 'LIT': W = e.bits.length; S = e.signed; break;
      case 'REF': {
        const v = resolve(e);
        e._v = v;
        e._sel = selWidths(v, v.sel || []);
        W = e._sel.length ? e._sel[e._sel.length - 1].width : v.width;
        S = !e._sel.length && isSignedType(v);
        break;
      }
      case 'CAND': {
        if (!cand) { throw new Error('`$` is only allowed in searchAll'); }
        e._sel = selWidths({ msb: cand.width - 1, lsb: 0 }, e.sel);
        W = e._sel.length ? e._sel[e._sel.length - 1].width : cand.width;
        break;
      }
      case 'CONCAT': W = 0; for (const a of e.args) { W += size(a)._w; if (W > MAX_BITS) { throw tooWide(); } } break;
      case 'REPL': { const n = constValue(e.n); const a = size(e.a)._w; if (n * a > MAX_BITS) { throw tooWide(); } e._n = n; W = n * a; break; }
      case 'CAST': W = size(e.a)._w; S = e.signed; break;
      case 'NOT': case 'POS': case 'NEG': W = size(e.a)._w; S = e.a._s; break;
      case 'AND': case 'OR': case 'XOR': case 'XNOR': case 'ADD': case 'SUB': case 'MUL': case 'DIV': case 'MOD':
        size(e.a); size(e.b); W = Math.max(e.a._w, e.b._w); S = e.a._s && e.b._s; break;
      case 'SHL': case 'SHR': case 'ASHR': size(e.b); W = size(e.a)._w; S = e.a._s; break;
      case 'TERN': size(e.c); size(e.a); size(e.b); W = Math.max(e.a._w, e.b._w); S = e.a._s && e.b._s; break;
      case 'EQ': case 'NE': case 'CEQ': case 'CNE': case 'LT': case 'GT': case 'LE': case 'GE':
      case 'LAND': case 'LOR': size(e.a); size(e.b); W = 1; break;
      case 'LNOT': case 'RAND': case 'ROR': case 'RXOR': case 'RNAND': case 'RNOR': case 'RXNOR': size(e.a); W = 1; break;
      default: throw new Error('unsupported ' + e.k);
    }
    if (W > MAX_BITS) { throw tooWide(); }
    e._w = W; e._s = S;
    return e;
  }

  const selectsOn = (n, sels) => { for (const { lo, width } of sels) { n = push({ op: OP.SEL, w: width, a: n, lo }); } return n; };

  // Pass 2: emit e at context width W with context signedness S.
  function gen(e, W, S) {
    switch (e.k) {
      case 'LIT': return ext(constOf(e.bits), W, S);
      case 'REF': {
        const v = e._v;
        refs.push(v.path || `#${v.signalId}`);
        return ext(selectsOn(sig(v.signalId, v.width), e._sel), W, S);
      }
      case 'CAND': {
        if (!sigNode.has('$')) { sigNode.set('$', push({ op: OP.SIG, w: cand.width, k: 0 })); }
        return ext(selectsOn(sigNode.get('$'), e._sel), W, S);
      }
      case 'CONCAT': { const args = e.args.map((a) => gen(a, a._w, a._s)); return ext(push({ op: OP.CONCAT, w: e._w, args }), W, S); }
      case 'REPL': { const a = gen(e.a, e.a._w, e.a._s); return ext(push({ op: OP.REPL, w: e._w, a, n: e._n }), W, S); }
      case 'CAST': return ext(gen(e.a, e.a._w, e.a._s), W, S);  // only the type changes
      case 'POS': return gen(e.a, W, S);
      case 'NOT': return push({ op: OP.NOT, w: W, a: gen(e.a, W, S) });
      case 'NEG': { const z = constOf('0'.repeat(W)); return push({ op: OP.SUB, w: W, a: z, b: gen(e.a, W, S) }); }
      case 'AND': case 'OR': case 'XOR': case 'ADD': case 'SUB': case 'MUL': case 'DIV': case 'MOD':
        return push({ op: OP[e.k], w: W, a: gen(e.a, W, S), b: gen(e.b, W, S), s: S ? 1 : 0 });
      case 'XNOR': { const x = push({ op: OP.XOR, w: W, a: gen(e.a, W, S), b: gen(e.b, W, S) }); return push({ op: OP.NOT, w: W, a: x }); }
      case 'SHL': case 'SHR': case 'ASHR': {
        const a = gen(e.a, W, S), b = gen(e.b, e.b._w, e.b._s);
        return push({ op: e.k === 'ASHR' && S ? OP.ASHR : e.k === 'SHL' ? OP.SHL : OP.SHR, w: W, a, b });
      }
      case 'TERN': {
        const c = gen(e.c, e.c._w, e.c._s), a = gen(e.a, W, S), b = gen(e.b, W, S);
        return push({ op: OP.TERN, w: W, a: c, b: a, c: b });
      }
      case 'EQ': case 'NE': case 'CEQ': case 'CNE': case 'LT': case 'GT': case 'LE': case 'GE': {
        const cw = Math.max(e.a._w, e.b._w), cs = e.a._s && e.b._s;
        return ext(push({ op: OP[e.k], w: 1, a: gen(e.a, cw, cs), b: gen(e.b, cw, cs), s: cs ? 1 : 0 }), W, S);
      }
      case 'LAND': case 'LOR': return ext(push({ op: OP[e.k], w: 1, a: gen(e.a, e.a._w, e.a._s), b: gen(e.b, e.b._w, e.b._s) }), W, S);
      case 'LNOT': case 'RAND': case 'ROR': case 'RXOR': return ext(push({ op: OP[e.k], w: 1, a: gen(e.a, e.a._w, e.a._s) }), W, S);
      case 'RNAND': case 'RNOR': case 'RXNOR': {
        const r = push({ op: OP[{ RNAND: 'RAND', RNOR: 'ROR', RXNOR: 'RXOR' }[e.k]], w: 1, a: gen(e.a, e.a._w, e.a._s) });
        return ext(push({ op: OP.NOT, w: 1, a: r }), W, S);
      }
      default: throw new Error('unsupported ' + e.k);
    }
  }
  const ast2 = structuredClone(ast);  // sizing annotates nodes; keep the caller's AST clean
  size(ast2);
  const root = gen(ast2, ast2._w, ast2._s);
  if (!sigNode.size) { throw new Error('expression has no signals'); }
  if (root !== program.length - 1) { program.push({ ...program[root] }); }  // result must be last
  return { program, operands, width: ast2._w, signed: ast2._s, refs };
}

// Wrap a program so its result is the 1-bit truth value (for searchAll expr).
function asBool(c) {
  const program = c.program.concat([{ op: OP.BOOL, w: 1, a: c.program.length - 1 }]);
  return { ...c, program, width: 1 };
}

module.exports = { parse, compile, asBool, literal, literalBits, OP, MAX_BITS };
