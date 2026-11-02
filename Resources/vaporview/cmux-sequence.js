// cmux's instruction-sequence search (status/asm-breakpoints-design.md §3A): "X then Y then Z" over the
// committed instruction stream, in an SVA sequence subset where one commit is one tick.
//
//   {lw} as L ##1 {add | sub} && (rs1 == L.rd || rs2 == L.rd)       load-use, adjacent
//   /jal\s+(ra|x1)/ ##[1:$] {ret}                                   a call, later a return
//   (cls == STORE, a = mem_addr) ##[1:$] cls == LOAD && mem_addr == a
//
// A step is a cmux-expr boolean over one commit, plus text atoms: {mnemonic operands} (a token prefix of the
// decoded text, `|` for alternatives; a class word such as {branch} tests the class) and /regex/ (over the
// decoded text with ABI and x-number register names, with and without pseudo-instructions). Names: the decoded fields insn, cls (LOAD, STORE,
// BRANCH, JUMP, ALU, ALUI, MUL, DIV, CSR, SYSTEM, FENCE, AMO), compressed, size, rd, rs1, rs2, imm, csr;
// the stream's pc, taken and any role the commit table has (rd_wdata, mem_addr, trap, ...); a step named
// `as L` gives L.<name> at its commit; an SVA local variable `(cond, v = expr)` gives v. Delays: ##n,
// ##[m:n], ##[m:$]; ##0 is the same commit. Braces are text atoms, so a step has no concatenation.
//
// Matching decodes each distinct insn once, evaluates each step's insn-only conjuncts per distinct insn
// (a bitmap), and extends each start like SVA threads, reporting its first (earliest-ending) match.
//
//   window.cmuxSequence = { parse, compile, search, decode, CLASSES }
//   parse(text) -> { steps: [{ text, delay: { min, max } | null, capture, assigns, expr }] } | { error, at }
//   search(stream, query, { from, limit, budget, maxThreads, budgetMs }) -> { matches: [{ start, end, ks }], incomplete,
//     reason, evaluated, next }; reason (when incomplete): 'limit' (`limit` matches; `next` is the first start not
//     searched), 'budget' (`budget` step evaluations) or 'time' (`budgetMs`): the starts from `next` on are not
//     searched; 'threads': a start had over `maxThreads` threads (it may be missing or end later; later starts are searched)
//   searchAsync(stream, query, { ...search's, sliceMs, pause }) -> Promise of search's result, plus `yields`: the same
//     search, pausing (`pause()`, default a zero timeout) after each `sliceMs` (default 25) of work, so the page stays
//     responsive
//     stream: { count, insn: (k) -> number | null, pc: (k) -> number | null, value: (role, k) -> BigInt | null, roles: [names] }
(function (root) {
  'use strict';

  const X = () => root.cmuxExpr;
  const D = () => root.cmuxRiscvDisasm;
  const link = (text, ra) => (root.cmuxMachineCore && text ? root.cmuxMachineCore.withLink(text, ra) : text);
  const CLASSES = ['LOAD', 'STORE', 'BRANCH', 'JUMP', 'ALU', 'ALUI', 'MUL', 'DIV', 'CSR', 'SYSTEM', 'FENCE', 'AMO', 'OTHER'];
  const CLASS_CODE = Object.fromEntries(CLASSES.map((c, i) => [c, i + 1]));
  const CLASS_WORDS = Object.fromEntries(CLASSES.map((c) => [c.toLowerCase(), CLASS_CODE[c]]));
  const MAX_STEPS = 16;
  const DEFAULT_BUDGET = 2000000;
  const DEFAULT_LIMIT = 100000;
  const DEFAULT_THREADS = 4096;
  const DEFAULT_SLICE_MS = 25;  // searchAsync's work between pauses
  const CLOCK_EVERY = 256;      // units of work (step evaluations, commits of a pass) between clock reads
  // Names decided by the instruction word alone: a conjunct over only these is evaluated per distinct insn.
  const STATIC = new Set(['insn', 'cls', 'compressed', 'size', 'rd', 'rs1', 'rs2', 'imm', 'csr', 'mnemonic'].concat(CLASSES));

  // ---- decoding: per distinct instruction word ----
  const MNEMONIC_CLASS = (() => {
    const out = new Map();
    const put = (cls, names) => names.split(' ').forEach((n) => out.set(n, CLASS_CODE[cls]));
    put('LOAD', 'lb lh lw ld lbu lhu lwu flw fld lwsp ldsp flwsp fldsp');
    put('STORE', 'sb sh sw sd fsw fsd swsp sdsp fswsp fsdsp');
    put('BRANCH', 'beq bne blt bge bltu bgeu beqz bnez blez bgez bltz bgtz bgt ble bgtu bleu');
    put('JUMP', 'jal jalr j jr ret call tail');
    put('ALU', 'add sub sll slt sltu xor srl sra or and addw subw sllw srlw sraw mv neg negw snez sltz sgtz not seqz');
    put('ALUI', 'addi slti sltiu xori ori andi slli srli srai addiw slliw srliw sraiw lui auipc li nop addi4spn addi16sp sext.w');
    put('MUL', 'mul mulh mulhsu mulhu mulw');
    put('DIV', 'div divu rem remu divw divuw remw remuw');
    put('CSR', 'csrrw csrrs csrrc csrrwi csrrsi csrrci csrr csrw csrs csrc csrwi csrsi csrci rdcycle rdtime rdinstret rdcycleh rdtimeh rdinstreth');
    put('SYSTEM', 'ecall ebreak mret sret uret wfi dret sfence.vma unimp');
    put('FENCE', 'fence fence.i fence.tso pause');
    return out;
  })();

  const bitsOf = (w, hi, lo) => (w >>> lo) & ((1 << (hi - lo + 1)) - 1);
  const sext = (v, bits) => (v << (32 - bits)) >> (32 - bits);
  const normalize = (text) => String(text || '').toLowerCase().replace(/,/g, ' ').replace(/\s+/g, ' ').trim();

  // { mnemonic, cls, compressed, size, rd, rs1, rs2, imm, csr, texts: [abi, numeric] } (fields absent: null).
  const decodeCache = new Map();
  function decode(word) {
    const w = word >>> 0;
    const key = (w & 3) === 3 ? w : w & 0xffff;
    const hit = decodeCache.get(key);
    if (hit) { return hit; }
    const dis = D();
    const abi = dis ? dis.disassembleRiscv(key) : null;
    const num = dis ? dis.disassembleRiscv(key, { abiNames: false }) : null;
    const raw = dis ? dis.disassembleRiscv(key, { abiNames: false, aliases: false }) : null;
    const compressed = (key & 3) !== 3;
    const out = { mnemonic: abi ? abi.split(' ')[0] : null, cls: CLASS_CODE.OTHER, compressed, size: compressed ? 2 : 4,
      rd: null, rs1: null, rs2: null, imm: null, csr: null,
      // With and without the pseudo-instructions (jal pc+16 is jal ra,pc+16), ABI and x-number names.
      // and with a call's implicit ra written out (c.jal pc+16 is jal ra,pc+16 too).
      texts: Array.from(new Set([abi, num, link(abi, 'ra'), link(num, 'x1'), dis ? dis.disassembleRiscv(key, { aliases: false }) : null, raw].filter(Boolean).map(normalize))) };
    const rawName = raw ? raw.split(' ')[0].replace(/^c\./, '') : '';
    if (/^(lr|sc|amo)/.test(rawName)) { out.cls = CLASS_CODE.AMO; } else if (MNEMONIC_CLASS.has(rawName)) { out.cls = MNEMONIC_CLASS.get(rawName); }
    if (!compressed) {
      const op = w & 0x7f;
      const rd = bitsOf(w, 11, 7), rs1 = bitsOf(w, 19, 15), rs2 = bitsOf(w, 24, 20);
      const immI = sext(w >>> 20, 12);
      const immS = sext((bitsOf(w, 31, 25) << 5) | bitsOf(w, 11, 7), 12);
      const immB = sext((bitsOf(w, 31, 31) << 12) | (bitsOf(w, 7, 7) << 11) | (bitsOf(w, 30, 25) << 5) | (bitsOf(w, 11, 8) << 1), 13);
      const immJ = sext((bitsOf(w, 31, 31) << 20) | (bitsOf(w, 19, 12) << 12) | (bitsOf(w, 20, 20) << 11) | (bitsOf(w, 30, 21) << 1), 21);
      const set = (f) => Object.assign(out, f);
      switch (op) {
        case 0x37: case 0x17: set({ rd, imm: (w >>> 12) | 0 }); break;                      // lui, auipc
        case 0x6f: set({ rd, imm: immJ }); break;                                           // jal
        case 0x67: case 0x03: case 0x07: case 0x13: case 0x1b: set({ rd, rs1, imm: immI }); break;  // jalr, loads, op-imm
        case 0x23: case 0x27: set({ rs1, rs2, imm: immS }); break;                          // stores
        case 0x63: set({ rs1, rs2, imm: immB }); break;                                     // branches
        case 0x33: case 0x3b: case 0x2f: set({ rd, rs1, rs2 }); break;                      // op, op-32, amo
        case 0x73: if (bitsOf(w, 14, 12)) { set({ rd, rs1, csr: w >>> 20 }); } break;        // csr ops (rs1 is uimm for the i forms)
        default: break;
      }
    } else if (raw) {
      // RVC: the registers in the expanded text's order (aliases off: c.lw x8,4(x9) / c.addi x2,-16).
      const ops = raw.split(' ').slice(1).join(' ').split(',');
      const regOf = (s) => { const m = /^x(\d+)$/.exec(String(s).trim()); return m ? Number(m[1]) : null; };
      const memOf = (s) => { const m = /^(-?\d+)\(x(\d+)\)$/.exec(String(s).trim()); return m ? { imm: Number(m[1]), base: Number(m[2]) } : null; };
      const numOf = (s) => { const t = String(s).trim(); if (/^-?(0x)?[0-9a-f]+$/i.test(t)) { return Number(t); } const m = /^pc([+-]\d+)$/.exec(t); return m ? Number(m[1]) : null; };
      const cls = out.cls;
      if (cls === CLASS_CODE.LOAD) { const m = memOf(ops[1]); Object.assign(out, { rd: regOf(ops[0]), rs1: m && m.base, imm: m && m.imm }); }
      else if (cls === CLASS_CODE.STORE) { const m = memOf(ops[1]); Object.assign(out, { rs2: regOf(ops[0]), rs1: m && m.base, imm: m && m.imm }); }
      else if (cls === CLASS_CODE.BRANCH) { Object.assign(out, { rs1: regOf(ops[0]), rs2: 0, imm: numOf(ops[ops.length - 1]) }); }
      else if (rawName === 'jr' || rawName === 'jalr') { Object.assign(out, { rs1: regOf(ops[0]), rd: rawName === 'jalr' ? 1 : 0, imm: 0 }); }
      else if (rawName === 'j' || rawName === 'jal') { Object.assign(out, { rd: rawName === 'jal' ? 1 : 0, imm: numOf(ops[0]) }); }
      else if (rawName === 'mv') { Object.assign(out, { rd: regOf(ops[0]), rs1: 0, rs2: regOf(ops[1]) }); }
      else if (rawName === 'addi4spn') { Object.assign(out, { rd: regOf(ops[0]), rs1: 2, imm: numOf(ops[2] !== undefined ? ops[2] : ops[1]) }); }
      else if (ops.length >= 2 && regOf(ops[1]) !== null) { Object.assign(out, { rd: regOf(ops[0]), rs1: regOf(ops[0]), rs2: regOf(ops[1]) }); }
      else if (ops.length >= 1 && regOf(ops[0]) !== null) {
        const imm = ops.length >= 2 ? numOf(ops[ops.length - 1]) : null;
        Object.assign(out, { rd: regOf(ops[0]), rs1: /^(li|lui)$/.test(rawName) ? null : regOf(ops[0]), imm });
      }
    }
    // RVC jumps as their base-ISA forms too (c.jal writes ra: jal ra,pc+22), so /jal\s+ra/ finds them.
    if (compressed && raw && /^c\.(jal|j|jalr|jr) /.test(raw)) {
      const op = raw.split(' ')[1];
      const forms = { 'c.jal': ['jal ra,' + op, 'jal x1,' + op], 'c.j': ['jal zero,' + op, 'jal x0,' + op],
        'c.jalr': ['jalr ra,0(' + op + ')', 'jalr x1,0(' + op + ')'], 'c.jr': ['jalr zero,0(' + op + ')', 'jalr x0,0(' + op + ')'] }[raw.split(' ')[0]] || [];
      out.texts = Array.from(new Set(out.texts.concat(forms.map(normalize))));
    }
    decodeCache.set(key, out);
    return out;
  }

  // ---- parsing ----
  // Split at top-level ## delays (not inside braces, a regex, parentheses or brackets).
  function splitSteps(text) {
    const parts = [];
    let depth = 0, inBrace = false, inRegex = false, start = 0;
    let pendingDelay = null;
    const prevSignificant = (i) => { for (let j = i - 1; j >= start; j--) { if (!/\s/.test(text[j])) { return text[j]; } } return null; };
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (inRegex) { if (c === '\\') { i++; } else if (c === '/') { inRegex = false; } continue; }
      if (inBrace) { if (c === '}') { inBrace = false; } continue; }
      if (c === '{') { inBrace = true; continue; }
      if (c === '/') { const p = prevSignificant(i); if (p === null || /[(&|!=,<>]/.test(p)) { inRegex = true; } continue; }
      if (c === '(' || c === '[') { depth++; continue; }
      if (c === ')' || c === ']') { depth--; continue; }
      if (depth === 0 && c === '#' && text[i + 1] === '#') {
        const m = /^##\s*(?:(\d+)|\[\s*(\d+)\s*:\s*(\d+|\$)\s*\])/.exec(text.slice(i));
        if (!m) { return { error: 'badDelay', at: i }; }
        parts.push({ text: text.slice(start, i), at: start, delay: pendingDelay });
        pendingDelay = m[1] !== undefined ? { min: Number(m[1]), max: Number(m[1]) } : { min: Number(m[2]), max: m[3] === '$' ? Infinity : Number(m[3]) };
        if (pendingDelay.max < pendingDelay.min) { return { error: 'badDelay', at: i }; }
        i += m[0].length - 1;
        start = i + 1;
      }
    }
    if (inRegex || inBrace) { return { error: 'syntax', at: text.length }; }
    parts.push({ text: text.slice(start), at: start, delay: pendingDelay });
    return { parts };
  }

  // Split at top-level commas.
  function splitCommas(text) {
    const out = [];
    let depth = 0, inBrace = false, inRegex = false, start = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (inRegex) { if (c === '\\') { i++; } else if (c === '/') { inRegex = false; } continue; }
      if (inBrace) { if (c === '}') { inBrace = false; } continue; }
      if (c === '{') { inBrace = true; } else if (c === '/' && /^\s*$|[(&|!=,<>]\s*$/.test(text.slice(start, i))) { inRegex = true; }
      else if (c === '(' || c === '[') { depth++; } else if (c === ')' || c === ']') { depth--; }
      else if (c === ',' && depth === 0) { out.push(text.slice(start, i)); start = i + 1; }
    }
    out.push(text.slice(start));
    return out;
  }

  // A step's text atoms become names __t0, __t1, ...; the rest is cmux-expr.
  function extractAtoms(text, atoms) {
    let out = '';
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (c === '{') {
        const end = text.indexOf('}', i);
        if (end < 0) { return { error: 'syntax', at: i }; }
        atoms.push(literalAtom(text.slice(i + 1, end)));
        out += ' __t' + (atoms.length - 1) + ' ';
        i = end;
      } else if (c === '/' && /^\s*$|[(&|!=,<>]\s*$/.test(out)) {
        let j = i + 1;
        for (; j < text.length && text[j] !== '/'; j++) { if (text[j] === '\\') { j++; } }
        if (j >= text.length) { return { error: 'syntax', at: i }; }
        const flags = /^[imsu]*/.exec(text.slice(j + 1))[0];
        let re;
        try { re = new RegExp(text.slice(i + 1, j), flags.includes('i') ? flags : flags + 'i'); } catch (error) { return { error: 'badRegex', at: i }; }
        atoms.push({ kind: 're', re });
        out += ' __t' + (atoms.length - 1) + ' ';
        i = j + flags.length;
      } else {
        out += c;
      }
    }
    // `cls == COMPRESSED` is the compressed flag (an RVC instruction is also a LOAD, an ALU ...).
    out = out.replace(/\bcls\s*==\s*COMPRESSED\b/g, 'compressed').replace(/\bcls\s*!=\s*COMPRESSED\b/g, '!compressed');
    return { text: out };
  }

  function literalAtom(body) {
    const alts = body.split('|').map((a) => normalize(a)).filter(Boolean);
    return { kind: 'lit', alts: alts.map((a) => (CLASS_WORDS[a] !== undefined ? { cls: CLASS_WORDS[a] } : { tokens: a.split(' ') })) };
  }

  function atomHolds(atom, info) {
    if (atom.kind === 're') { return info.texts.some((t) => atom.re.test(t)); }
    return atom.alts.some((alt) => {
      if (alt.cls !== undefined) { return info.cls === alt.cls; }
      return info.texts.some((t) => {
        const tokens = t.split(' ');
        return alt.tokens.every((tok, i) => tokens[i] === tok);
      });
    });
  }

  function parse(text) {
    const src = String(text || '');
    if (!src.trim()) { return { error: 'empty', at: null }; }
    const split = splitSteps(src);
    if (split.error) { return split; }
    if (split.parts.length > MAX_STEPS) { return { error: 'tooManySteps', at: null }; }
    const steps = [];
    for (const part of split.parts) {
      let body = part.text.trim();
      if (!body) { return { error: 'emptyStep', at: part.at }; }
      let capture = null;
      const cap = /\s+as\s+([A-Za-z_][A-Za-z0-9_]*)\s*$/.exec(body);
      if (cap) { capture = cap[1]; body = body.slice(0, cap.index).trim(); }
      // SVA local variables: (cond, v = expr, ...).
      const assigns = [];
      if (body[0] === '(' && body[body.length - 1] === ')' && closesAtEnd(body)) {
        const items = splitCommas(body.slice(1, -1));
        if (items.length > 1) {
          body = items[0].trim();
          for (const item of items.slice(1)) {
            const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)\s*([\s\S]+)$/.exec(item);
            if (!m) { return { error: 'badAssign', at: part.at }; }
            assigns.push({ name: m[1], text: m[2].trim() });
          }
        }
      }
      const atoms = [];
      const ex = extractAtoms(body, atoms);
      if (ex.error) { return { error: ex.error, at: part.at + (ex.at || 0) }; }
      const parsed = X().parse(ex.text);
      if (parsed.error) { return { error: parsed.error, at: part.at, detail: parsed }; }
      const parsedAssigns = [];
      for (const a of assigns) {
        const aa = [];
        const ax = extractAtoms(a.text, aa);
        const p = ax.error ? ax : X().parse(ax.text);
        if (p.error || aa.length) { return { error: p.error || 'badAssign', at: part.at }; }
        parsedAssigns.push({ name: a.name, ast: p.ast });
      }
      steps.push({ text: part.text.trim(), delay: part.delay, capture, assigns: parsedAssigns, ast: parsed.ast, atoms });
    }
    // Names a later step reads: captures and local variables must come from an earlier step.
    const known = new Set();
    for (const step of steps) {
      for (const path of X().names(step.ast).concat(...step.assigns.map((a) => X().names(a.ast)))) {
        if (path.length === 2 && !known.has(path[0])) { return { error: 'unknownCapture', at: null, detail: path.join('.') }; }
      }
      if (step.capture) { known.add(step.capture); }
      step.assigns.forEach((a) => known.add(a.name));
    }
    return { steps };
  }

  function closesAtEnd(body) {
    let depth = 0;
    for (let i = 0; i < body.length; i++) {
      if (body[i] === '(') { depth++; } else if (body[i] === ')') { depth--; if (depth === 0 && i < body.length - 1) { return false; } }
    }
    return depth === 0;
  }

  // ---- evaluation ----
  const mk = (w, v) => ({ width: w, value: { w, a: BigInt.asUintN(w, BigInt(v)), b: 0n } });
  const unknown = (w) => ({ width: w, value: { w, a: (1n << BigInt(w)) - 1n, b: (1n << BigInt(w)) - 1n } });

  // Top-level && conjuncts.
  function conjuncts(ast) { return ast.t === 'bin' && ast.op === '&&' ? conjuncts(ast.l).concat(conjuncts(ast.r)) : [ast]; }
  function isStatic(ast) { return X().names(ast).every((p) => p.length === 1 && (STATIC.has(p[0]) || /^__t\d+$/.test(p[0]))); }
  function and(list) { return list.reduce((l, r) => ({ t: 'bin', op: '&&', l, r, at: 0 })); }

  function compile(query, stream) {
    const q = typeof query === 'string' ? parse(query) : query;
    if (q.error) { return q; }
    const xlen = stream.xlen || 32;
    const roles = new Set(stream.roles || []);
    const steps = q.steps.map((s) => {
      const parts = conjuncts(s.ast);
      const stat = parts.filter(isStatic);
      const dyn = parts.filter((p) => !isStatic(p));
      return { src: s, staticAst: stat.length ? and(stat) : null, dynamicAst: dyn.length ? and(dyn) : null };
    });
    // A field's value at commit k: { width, value } | null (not a name here) | unknown (x).
    const fieldAt = (name, k) => {
      if (name === 'pc') { const v = stream.pc(k); return v === null ? unknown(xlen) : mk(xlen, v); }
      if (name === 'taken') {
        const info = decodeAt(k);
        const next = stream.value('pc_wdata', k);
        const pc = stream.pc(k);
        const after = next !== null ? Number(next) : stream.pc(k + 1);
        if (pc === null || after === null || after === undefined || !info) { return unknown(1); }
        return mk(1, after !== (pc + info.size) % 2 ** xlen ? 1 : 0);
      }
      if (STATIC.has(name)) { const info = decodeAt(k); return info ? staticField(info, name, stream.insn(k)) : unknown(32); }
      if (roles.has(name)) { const v = stream.value(name, k); return v === null ? unknown(xlen) : mk(stream.widthOf ? stream.widthOf(name) : xlen, v); }
      return null;
    };
    const decodeAt = (k) => { const w = stream.insn(k); return w === null || w === undefined ? null : decode(w); };
    const staticField = (info, name, word) => {
      if (CLASS_CODE[name] !== undefined) { return mk(4, CLASS_CODE[name]); }
      switch (name) {
        case 'insn': return mk(32, word >>> 0);
        case 'cls': return mk(4, info.cls);
        case 'compressed': return mk(1, info.compressed ? 1 : 0);
        case 'size': return mk(4, info.size);
        case 'imm': return info.imm === null ? unknown(32) : mk(32, info.imm);
        case 'csr': return info.csr === null ? unknown(12) : mk(12, info.csr);
        case 'mnemonic': return unknown(1);
        default: return info[name] === null ? unknown(5) : mk(5, info[name]);
      }
    };
    // Evaluate `ast` at commit k with captures (name -> k) and locals (name -> { width, value }).
    const holds = (step, ast, k, ctx) => {
      const info = decodeAt(k);
      const env = (path) => {
        if (path.length === 2) {
          if (ctx.caps[path[0]] === undefined) { return null; }
          return fieldAt(path[1], ctx.caps[path[0]]);
        }
        const name = path[0];
        const t = /^__t(\d+)$/.exec(name);
        if (t) { return mk(1, info && atomHolds(step.src.atoms[Number(t[1])], info) ? 1 : 0); }
        if (ctx.locals[name] !== undefined) { return ctx.locals[name]; }
        return fieldAt(name, k);
      };
      const r = X().evaluate(ast, env);
      if (r.error) { throw Object.assign(new Error(r.error), { sequenceError: r.error, at: r.at, step: step.src.text }); }
      return X().truthy(r.value) === true;
    };
    // The static part per distinct insn (the bitmap), cached.
    steps.forEach((step) => {
      step.cache = new Map();
      step.staticHolds = (k) => {
        if (!step.staticAst) { return true; }
        const w = stream.insn(k);
        if (w === null || w === undefined) { return false; }
        let v = step.cache.get(w);
        if (v === undefined) { v = holds(step, step.staticAst, k, { caps: {}, locals: {} }); step.cache.set(w, v); }
        return v;
      };
    });
    return { steps, holds, fieldAt };
  }

  // Each start's first (earliest-ending) match, starts ascending from `from`.
  function search(stream, query, options) {
    const run = searchSteps(stream, query, options || {});
    let step = run.next();
    while (!step.done) { step = run.next(); }
    return step.value;
  }

  async function searchAsync(stream, query, options) {
    const opts = options || {};
    const pause = typeof opts.pause === 'function' ? opts.pause
      : (typeof setTimeout === 'function' ? () => new Promise((resolve) => setTimeout(resolve, 0)) : () => Promise.resolve());
    const run = searchSteps(stream, query, Object.assign({}, opts, { sliceMs: Math.max(1, opts.sliceMs || DEFAULT_SLICE_MS) }));
    let yields = 0;
    let step = run.next();
    while (!step.done) { yields++; await pause(); step = run.next(); }
    return step.value.error ? step.value : Object.assign(step.value, { yields });
  }

  const now = () => (typeof performance !== 'undefined' && performance.now ? performance.now() : Date.now());

  // search's loop as a generator: it yields after each `sliceMs` of work (searchAsync), never when `sliceMs` is unset.
  function* searchSteps(stream, query, opts) {
    const started = now();
    const c = compile(query, stream);
    if (c.error) { return c; }
    const steps = c.steps;
    const n = stream.count;
    const budget = opts.budget || DEFAULT_BUDGET;
    const limit = opts.limit || DEFAULT_LIMIT;
    const maxThreads = opts.maxThreads || DEFAULT_THREADS;
    let evaluated = 0;
    const deadline = opts.budgetMs > 0 ? started + opts.budgetMs : null;
    const sliceMs = opts.sliceMs > 0 ? opts.sliceMs : null;
    let work = 0;          // step evaluations and commits of the passes below
    let nextClock = CLOCK_EVERY;
    let lastPause = started;
    let pauseDue = false;
    let timedOut = false;
    let reason = null;
    // The clock, read every CLOCK_EVERY units of work: past the deadline, or time to pause.
    const tick = () => {
      if (work < nextClock) { return; }
      nextClock = work + CLOCK_EVERY;
      if (deadline === null && sliceMs === null) { return; }
      const t = now();
      if (deadline !== null && t > deadline) { timedOut = true; }
      if (sliceMs !== null && t - lastPause >= sliceMs) { pauseDue = true; }
    };
    // Out of steps or time.
    const spent = () => {
      if (evaluated > budget) { reason = reason || 'budget'; return true; }
      tick();
      if (timedOut) { reason = reason || 'time'; return true; }
      return false;
    };
    // Next commit at or after k where step s's static part holds (for unbounded gaps), filled lazily backwards.
    // A step that reads no capture or local variable holds or not at k alone: its whole condition goes in the
    // array (one pass), so an unbounded gap to it is one lookup. Else only its static part does.
    const nextStatic = steps.map(() => null);
    const free = steps.map((st) => X().names(st.src.ast).every((p) => p.length === 1 && !isLocal(steps, p[0])));
    const nextOf = (s, k) => {
      if (k >= n) { return -1; }
      if (!steps[s].staticAst && !(free[s] && steps[s].dynamicAst)) { return k; }
      if (!nextStatic[s]) {
        const arr = new Int32Array(n + 1);
        arr[n] = -1;
        const empty = { caps: {}, locals: {} };
        for (let j = n - 1; j >= 0; j--) { arr[j] = passHolds(s, j, empty) ? j : arr[j + 1]; }
        nextStatic[s] = arr;
      }
      return nextStatic[s][k];
    };
    const passHolds = (s, j, empty) => {
      work++;
      return steps[s].staticHolds(j) && (!free[s] || !steps[s].dynamicAst || (evaluated++, c.holds(steps[s], steps[s].dynamicAst, j, empty)));
    };
    const usesPass = (s) => (s === 0 || (steps[s].src.delay && steps[s].src.delay.max === Infinity))
      && (steps[s].staticAst || (free[s] && steps[s].dynamicAst));
    const stepHolds = (s, k, ctx) => {
      evaluated++;
      work++;
      const step = steps[s];
      if (!step.staticHolds(k)) { return null; }
      if (step.dynamicAst && !c.holds(step, step.dynamicAst, k, ctx)) { return null; }
      // Captures and local variables after the step holds.
      const caps = step.src.capture ? Object.assign({}, ctx.caps, { [step.src.capture]: k }) : ctx.caps;
      let locals = ctx.locals;
      if (step.src.assigns.length) {
        locals = Object.assign({}, locals);
        for (const a of step.src.assigns) {
          const r = X().evaluate(a.ast, (path) => (path.length === 1 && locals[path[0]] !== undefined ? locals[path[0]] : c.fieldAt(path[0], k)));
          if (r.error) { throw Object.assign(new Error(r.error), { sequenceError: r.error, step: step.src.text }); }
          locals[a.name] = { width: r.value.w, value: r.value };
        }
      }
      return { caps, locals };
    };
    const matches = [];
    let incomplete = false;
    let cut = false;  // some start had too many threads
    let next = null;
    try {
      // The passes for the first step and the unbounded gaps, here so they pause and keep to the deadline too.
      const empty = { caps: {}, locals: {} };
      for (let s = 0; s < steps.length; s++) {
        if (!usesPass(s) || nextStatic[s]) { continue; }
        const arr = new Int32Array(n + 1);
        arr[n] = -1;
        for (let j = n - 1; j >= 0; j--) {
          arr[j] = passHolds(s, j, empty) ? j : arr[j + 1];
          if (work >= nextClock) {
            tick();
            if (timedOut) { return { matches, incomplete: true, reason: 'time', evaluated, next: Math.max(0, opts.from || 0), ms: Math.round(now() - started) }; }
            if (pauseDue) { pauseDue = false; yield; lastPause = now(); }
          }
        }
        nextStatic[s] = arr;
      }
      for (let start = nextOf(0, Math.max(0, opts.from || 0)); start >= 0 && start < n; start = nextOf(0, start + 1)) {
        if (pauseDue) { pauseDue = false; yield; lastPause = now(); }
        if (spent()) { incomplete = true; next = start; break; }
        if (matches.length >= limit) { incomplete = true; reason = 'limit'; next = start; break; }
        const first = stepHolds(0, start, { caps: {}, locals: {} });
        if (!first) { continue; }
        // Threads: { k, ks, ctx }; level by level, deduplicated by (k, captures, locals).
        let threads = [{ k: start, ks: [start], ctx: first }];
        for (let s = 1; s < steps.length && threads.length; s++) {
          const { min, max } = steps[s].src.delay;
          const last = s === steps.length - 1;
          const out = [];
          const seen = new Set();
          let best = Infinity;
          for (const t of threads) {
            const hi = Math.min(n - 1, max === Infinity ? n - 1 : t.k + max);
            for (let j = max === Infinity ? nextOf(s, t.k + min) : t.k + min; j >= 0 && j <= hi; j = max === Infinity ? nextOf(s, j + 1) : j + 1) {
              if (last && j >= best) { break; }
              if (pauseDue) { pauseDue = false; yield; lastPause = now(); }
              if (spent()) { break; }
              const ctx = stepHolds(s, j, t.ctx);
              if (!ctx) { continue; }
              const key = j + '|' + keyOf(ctx);
              if (!seen.has(key)) { seen.add(key); out.push({ k: j, ks: t.ks.concat([j]), ctx }); }
              // The last step: the earliest end wins (first_match); the rest only need their first hold per thread
              // when nothing later reads what this step captured.
              if (last) { best = Math.min(best, j); break; }
              if (!needsAll(steps, s)) { break; }
              if (out.length > maxThreads) { break; }
            }
            if (out.length > maxThreads) { incomplete = true; cut = true; break; }
            if (spent()) { incomplete = true; break; }
          }
          threads = last ? out.filter((t) => t.k === best) : out;
        }
        // Stopped inside this start: it is searched again from `next`, not reported half-done.
        if (reason) { next = start; break; }
        if (threads.length) {
          const t = threads.reduce((a, b) => (b.k < a.k ? b : a));
          matches.push({ start, end: t.k, ks: t.ks });
        }
      }
    } catch (error) {
      if (error && error.sequenceError) { return { error: error.sequenceError, at: error.at === undefined ? null : error.at, step: error.step }; }
      throw error;
    }
    return { matches, incomplete, reason: reason || (cut ? 'threads' : null), evaluated, next, ms: Math.round(now() - started) };
  }

  function isLocal(steps, name) { return steps.some((st) => st.src.assigns.some((a) => a.name === name)); }

  // Whether a step after s reads s's capture or locals, or has a bounded delay (so a later hold of s
  // can still lead to an earlier end): then every hold of s is a thread, else only the first.
  function needsAll(steps, s) {
    const names = new Set([steps[s].src.capture].concat(steps[s].src.assigns.map((a) => a.name)).filter(Boolean));
    for (let j = s + 1; j < steps.length; j++) {
      if (steps[j].src.delay.max !== Infinity) { return true; }
      if (names.size) {
        const used = X().names(steps[j].src.ast).concat(...steps[j].src.assigns.map((a) => X().names(a.ast)));
        if (used.some((p) => names.has(p[0]))) { return true; }
      }
    }
    return false;
  }

  function keyOf(ctx) {
    const caps = Object.keys(ctx.caps).sort().map((k) => k + '=' + ctx.caps[k]).join(',');
    const locals = Object.keys(ctx.locals).sort().map((k) => k + '=' + ctx.locals[k].value.a.toString(16) + '/' + ctx.locals[k].value.b.toString(16)).join(',');
    return caps + ';' + locals;
  }

  // A search stream over the machine state's commit table (cmux-machine-core.js StateIndex).
  function streamOf(index) {
    const C = root.cmuxMachineCore;
    const cols = index.table.cols;
    return { count: index.count, xlen: index.xlen, roles: Object.keys(cols),
      insn: (k) => (k >= 0 && k < index.count ? C.num(cols.insn, k) : null),
      pc: (k) => (k >= 0 && k < index.count ? C.num(cols.pc_rdata, k) : null),
      value: (role, k) => (k >= 0 && k < index.count && cols[role] ? C.big(cols[role], k) : null),
      widthOf: (role) => (cols[role] ? cols[role].w : index.xlen) };
  }

  root.cmuxSequence = Object.freeze({ parse, compile, search, searchAsync, decode, streamOf, CLASSES, MAX_STEPS });
})(typeof window !== 'undefined' ? window : globalThis);
