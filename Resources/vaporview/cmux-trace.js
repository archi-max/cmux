// cmux's driver tracing, the engine (design: status/tracex-design.md, phase P1): the active
// driver of a signal at a time. It finds the statement that produced the value in effect: a
// continuous assignment, the branch of a procedure actually taken (re-executed with simulator
// semantics on the dump's values), or a port connection, with the fan-in of that statement and
// its conditions at the time it was sampled, and says how far to trust it (exact, computed,
// approximate or inconsistent, with reasons).
//
// Pure: no DOM, no host. The design comes from cmux-sv-model (Resources/vaporview/sv-model, built
// on slang), one instance at a time; values come from the dump; both are injected. Expressions are
// evaluated by cmux-expr.js. Paths are design paths (slang's hierarchy); the dump provider maps
// them to the dump's names.
//
//   createEngine({ models, dump, options }) -> { active(path, time) -> step, model(path) }
//     models.instance(path) -> Promise<model>          cmux-sv-model's instance reply (its "model")
//     models.lookup(path) -> Promise<{ instance, name }> the instance a path is in, and the rest
//     models.writers(path) -> Promise<[instance path]>  (optional) the other instances that write
//         into an instance (an interface instance's signals, written through modport ports)
//     dump.values(paths, time) -> Promise<Map(path -> bits | undefined)>   undefined: not dumped
//     dump.lastChange(path, time) -> Promise<number | null>   the change in effect at time (0: the
//         start), null: not dumped
//     dump.prevEdge(path, time, 'PosEdge' | 'NegEdge' | 'BothEdges') -> Promise<number | null>
//         the last such edge at or before time
//     options.xprop: 'auto' (default) | 'on' | 'off'   X-propagation (VCS -xprop): an if or case on
//         an x condition merges its branches. 'auto' re-runs a step that way when the dump
//         disagrees with the x-optimistic run and agrees with the merged one.
//
// A step: { signal, time, value (bits), since, driver (driver.writer: the instance of a statement
// that writes into the signal's instance from outside it), stmt, decisions, fanin, predicted,
// trust, reasons, drivers, root?, activation? }. Reasons are codes with arguments; the page
// words them (strings in cmux).
(function (root) {
  'use strict';
  const MODEL_VERSION = 1;
  // Statements run per activation before giving up (loops are P3; this bounds bad models).
  const MAX_STATEMENTS = 4096;
  // Re-executions to fetch unpacked-array elements whose index is only known after a run.
  const MAX_ELEMENT_ROUNDS = 3;
  // Elements an x index may name that X-propagation's resolution read merges (more: all x).
  const MAX_RESOLUTION = 64;

  const maskOf = (w) => (1n << BigInt(w)) - 1n;
  const allX = (w) => ({ w, a: maskOf(w), b: maskOf(w) });
  const hasX = (v) => v.b !== 0n;
  const fit = (v, w) => ({ w, a: v.a & maskOf(w), b: v.b & maskOf(w) });
  const bitsOf = (X, v) => (v ? X.toBits(v) : null);

  // Bits [lsb, lsb + w) of v.
  const slice = (v, lsb, w) => ({ w, a: (v.a >> BigInt(lsb)) & maskOf(w), b: (v.b >> BigInt(lsb)) & maskOf(w) });
  // v with bits [lsb, lsb + part.w) replaced by part.
  function insert(v, lsb, part) {
    const m = maskOf(part.w) << BigInt(lsb);
    return { w: v.w, a: ((v.a & ~m) | ((part.a << BigInt(lsb)) & m)) & maskOf(v.w), b: ((v.b & ~m) | ((part.b << BigInt(lsb)) & m)) & maskOf(v.w) };
  }
  // Per bit: the same known value in both, else x (X-propagation's merge).
  function merge(p, q) {
    const w = Math.max(p.w, q.w);
    const a = fit(p, w), b = fit(q, w);
    const differ = (a.a ^ b.a) | (a.b ^ b.b) | a.b | b.b;
    return { w, a: (a.a & ~differ) | differ, b: differ & maskOf(w) };
  }
  const same = (p, q) => p.w === q.w && p.a === q.a && p.b === q.b;

  function caseMatch(a, b, cond) {
    const w = Math.max(a.w, b.w);
    const x = fit(a, w), y = fit(b, w);
    let care = maskOf(w);
    const zOf = (v) => ~v.a & v.b;
    if (cond === 'WildcardJustZ') { care &= ~(zOf(x) | zOf(y)); }
    if (cond === 'WildcardXOrZ') { care &= ~(x.b | y.b); }
    return ((x.a ^ y.a) & care) === 0n && ((x.b ^ y.b) & care) === 0n;
  }
  // Whether a case item can match a selector with x bits (X-propagation's candidates).
  function caseMayMatch(a, b) {
    const w = Math.max(a.w, b.w);
    const x = fit(a, w), y = fit(b, w);
    const care = maskOf(w) & ~(x.b | y.b);
    return ((x.a ^ y.a) & care) === 0n;
  }

  function createEngine(config) {
    const X = config.expr || root.cmuxExpr;
    const models = config.models;
    const dump = config.dump;
    const options = Object.assign({ xprop: 'auto' }, config.options || {});
    const modelCache = new Map();
    const parsed = new Map();
    const indexCache = new WeakMap();

    const writersCache = new Map();
    // Drivers outside the signal's instance: the statements of the instances that write into it
    // ($abs: lvalues), each run in its own instance's model. [{ m, d, name }]
    async function outsideDrivers(m, name) {
      if (typeof models.writers !== 'function' || isLocal(name)) { return []; }
      if (!writersCache.has(m.path)) {
        writersCache.set(m.path, Promise.resolve(models.writers(m.path)).then((w) => (Array.isArray(w) ? w : []), () => []));
      }
      const s = signalOf(m, name);
      const base = '$abs:' + m.path + '.' + (s && s.element ? s.element.array : name);
      const out = [];
      for (const w of await writersCache.get(m.path)) {
        const wm = await model(w);
        if (!wm) { continue; }
        for (const d of driversOf(wm, base)) { out.push({ m: wm, d, name: '$abs:' + m.path + '.' + name }); }
      }
      return out;
    }

    async function model(path) {
      if (!modelCache.has(path)) {
        modelCache.set(path, Promise.resolve(models.instance(path)).then((m) => {
          if (m && m.version !== undefined && m.version !== MODEL_VERSION) { throw new Error('model version ' + m.version); }
          return m;
        }));
      }
      try {
        return await modelCache.get(path);
      } catch (error) {
        modelCache.delete(path);
        throw error;
      }
    }

    // ---- names ----
    const absOf = (inst, name) => (name.startsWith('$abs:') ? name.slice(5) : inst + '.' + name);
    const isLocal = (name) => name.startsWith('$local:');
    function relOf(m, path) { return path.startsWith(m.path + '.') ? path.slice(m.path.length + 1) : '$abs:' + path; }

    // ---- locations ----
    function locOf(m, l) {
      if (!l || !Array.isArray(l)) { return null; }
      return { file: m.files[l[0]], line: l[1], col: l[2], endLine: l[3], endCol: l[4] };
    }

    // ---- expressions ----
    function parse(text) {
      if (!parsed.has(text)) {
        // Internal callers lift the user-facing caps when cmux-expr supports it.
        let r = X.parse(text, { maxSignals: Infinity, maxText: Infinity });
        parsed.set(text, r);
      }
      return parsed.get(text);
    }

    // The signals' info in a model by relative name (and $abs paths, by their own instance).
    function signalOf(m, name) {
      if (!m || isLocal(name)) { return null; }
      if (m.signals[name]) { return m.signals[name]; }
      const em = /^(.*)\[(-?\d+)\]$/.exec(name);
      if (em && m.signals[em[1]] && m.signals[em[1]].array) {
        const s = m.signals[em[1]];
        return { width: s.array.elemWidth, kind: s.kind, element: { array: em[1], k: Number(em[2]) } };
      }
      return null;
    }

    // The dump paths an expression reads (its leaves, element indices' leaves).
    function leafPaths(m, e, out) {
      if (!e) { return out; }
      for (const l of e.leaves) { if (!isLocal(l)) { out.add(absOf(m.path, l)); } }
      for (const el of e.elems || []) { leafPaths(m, el.index, out); }
      return out;
    }

    // ctx: { m, vals: Map(path -> value | undefined), locals, blocking, writes, decisions, reasons,
    //        needElems: Set(path), elemsRead, statements }
    function evalExpr(e, ctx, width) {
      const reads = [];
      const leafValue = (name) => {
        if (isLocal(name)) {
          const l = ctx.locals.get(name);
          return { value: l ? l.value : allX(1), src: 'local', name, write: l && l.write };
        }
        const p = absOf(ctx.m.path, name);
        if (ctx.blocking.has(p)) { const b = ctx.blocking.get(p); return { value: b.value, src: 'blocking', path: p, write: b.write }; }
        const v = ctx.vals.get(p);
        if (v === undefined) {
          const s = signalOf(ctx.m, name);
          const w = s ? Math.max(1, s.width) : 1;
          ctx.missing.add(p);
          return { value: allX(w), src: ctx.vals.has(p) ? 'notDumped' : 'notFetched', path: p };
        }
        return { value: v, src: 'signal', path: p };
      };
      const env = (segs) => {
        const tok = segs.join('.');
        let r;
        const lm = /^_L(\d+)_$/.exec(tok);
        const em = /^_E(\d+)_$/.exec(tok);
        const om = /^_O(\d+)_$/.exec(tok);
        if (lm) {
          const name = e.leaves[Number(lm[1])];
          r = leafValue(name);
          reads.push(Object.assign({ leaf: Number(lm[1]), name }, r));
        } else if (em) {
          const el = e.elems[Number(em[1])];
          r = elemValue(el, ctx);
          reads.push(Object.assign({ elem: Number(em[1]), name: el.array }, r));
        } else if (om) {
          const o = e.opaque[Number(om[1])];
          ctx.reasons.push({ code: 'opaque', src: o.src, why: o.why });
          r = { value: allX(Math.max(1, o.width || 32)), src: 'opaque' };
          reads.push(Object.assign({ opaque: Number(om[1]) }, r));
        } else {
          return null;
        }
        return { width: r.value.w, msb: r.value.w - 1, lsb: 0, value: r.value };
      };
      const text = width ? `(${width}'b0 | (${e.text}))` : e.text;
      const p = parse(text);
      if (p.error) {
        ctx.reasons.push({ code: p.error === 'tooManySignals' || p.error === 'tooLong' ? 'limits' : 'evaluator', src: e.src, error: p.error });
        return { value: allX(width || Math.max(1, e.width || 1)), reads, failed: true };
      }
      const r = X.evaluate(p.ast, env);
      if (r.error) {
        ctx.reasons.push({ code: 'evaluator', src: e.src, error: r.error });
        return { value: allX(width || Math.max(1, e.width || 1)), reads, failed: true };
      }
      return { value: width ? fit(r.value, width) : r.value, reads };
    }

    // An unpacked-array element: its index first; x index or out of range reads all x.
    function elemValue(el, ctx) {
      const idx = evalExpr(el.index, ctx);
      if (hasX(idx.value)) {
        ctx.sawXIndex = true;
        // X-propagation's "resolution" read: the merge of every element the index could name.
        if (ctx.mode === 'xprop') {
          const known = idx.value.a & ~idx.value.b;
          let merged = null, count = 0;
          for (let k = el.lo; k <= el.hi && count <= MAX_RESOLUTION; k++) {
            if ((BigInt(k) & ~idx.value.b & maskOf(idx.value.w)) !== known) { continue; }
            count++;
            const p = absOf(ctx.m.path, el.array) + `[${k}]`;
            ctx.elemsRead.add(p);
            if (!ctx.vals.has(p)) { ctx.needElems.add(p); merged = allX(el.width); continue; }
            const v = ctx.vals.get(p);
            if (v === undefined) { ctx.missing.add(p); }
            const ev = v === undefined ? allX(el.width) : fit(v, el.width);
            merged = merged ? merge(merged, ev) : ev;
          }
          if (merged && count <= MAX_RESOLUTION) { return { value: fit(merged, el.width), src: 'xIndex', index: idx, resolution: count }; }
        }
        return { value: allX(el.width), src: 'xIndex', index: idx };
      }
      const k = Number(idx.value.a);
      if (k < el.lo || k > el.hi) { return { value: allX(el.width), src: 'outOfRange', k }; }
      const p = absOf(ctx.m.path, el.array) + `[${k}]`;
      ctx.elemsRead.add(p);
      if (!ctx.vals.has(p)) { ctx.needElems.add(p); return { value: allX(el.width), src: 'notFetched', path: p, k, index: idx }; }
      const v = ctx.vals.get(p);
      if (v === undefined) { ctx.missing.add(p); return { value: allX(el.width), src: 'elemNotDumped', path: p, k, index: idx }; }
      return { value: v, src: 'element', path: p, k, index: idx };
    }

    // ---- statements ----
    function newCtx(m, vals, mode) {
      return { m, vals, mode: mode || 'optimistic', locals: new Map(), blocking: new Map(), writes: new Map(), decisions: [],
        reasons: [], missing: new Set(), needElems: new Set(), elemsRead: new Set(), statements: 0, path: [] };
    }
    function fork(ctx) {
      return Object.assign({}, ctx, { locals: new Map(ctx.locals), blocking: new Map(ctx.blocking), writes: new Map([...ctx.writes].map(([k, v]) => [k, v.slice()])), decisions: ctx.decisions.slice(), path: ctx.path.slice() });
    }

    function widthOfTarget(ctx, name) {
      if (isLocal(name)) { const l = ctx.locals.get(name); return l ? l.value.w : null; }
      const s = signalOf(ctx.m, name);
      return s ? s.width : null;
    }
    // The current value of a variable inside a run: its blocking writes so far, else sampled.
    function currentValue(ctx, name, width) {
      if (isLocal(name)) { const l = ctx.locals.get(name); return l ? l.value : allX(width); }
      const p = absOf(ctx.m.path, name);
      if (ctx.blocking.has(p)) { return ctx.blocking.get(p).value; }
      const v = ctx.vals.get(p);
      return v === undefined ? allX(width) : fit(v, width);
    }

    function write(ctx, s, lhs, value) {
      if (lhs.concat) {
        // {a, b} = rhs: the parts take rhs's bits from the top down.
        let top = value.w;
        for (const part of lhs.concat) {
          const w = part.width || 1;
          top -= w;
          write(ctx, s, part, slice(value, Math.max(0, top), w));
        }
        return;
      }
      if (lhs.opaque !== undefined || !lhs.name) { ctx.reasons.push({ code: 'lvalue', src: lhs.opaque || s.src }); return; }
      const name = lhs.name;
      let target = name, lsb = lhs.lsb !== undefined ? lhs.lsb : 0;
      const full = lhs.full || widthOfTarget(ctx, name) || value.w;
      if (lhs.elem) {
        const idx = evalExpr(lhs.elem, ctx).value;
        // An x index writes nothing (as VCS does).
        if (hasX(idx)) { ctx.decisions.push({ kind: 'xWriteIndex', stmt: s, value: idx }); return; }
        target = name + `[${Number(idx.a)}]`;
      }
      if (lhs.off) {
        const off = evalExpr(lhs.off, ctx).value;
        if (hasX(off)) { ctx.decisions.push({ kind: 'xWriteIndex', stmt: s, value: off }); return; }
        lsb = Number(off.a);
      }
      const width = lhs.width || value.w;
      const rec = { stmt: s, lhs, target, lsb, width, value: fit(value, width), decisions: ctx.decisions.slice(), path: ctx.path.slice(), ctx: null };
      rec.ctx = { m: ctx.m, vals: ctx.vals, locals: new Map(ctx.locals), blocking: new Map(ctx.blocking) };
      if (isLocal(target)) {
        const old = ctx.locals.get(target);
        const base = old ? old.value : allX(full);
        ctx.locals.set(target, { value: lsb === 0 && width >= base.w ? fit(value, base.w) : insert(base, lsb, fit(value, width)), write: rec });
        return;
      }
      const p = absOf(ctx.m.path, target);
      if (!ctx.writes.has(p)) { ctx.writes.set(p, []); }
      ctx.writes.get(p).push(rec);
      if (!s.nb && !lhs.elem) {
        const base = currentValue(ctx, target, full);
        ctx.blocking.set(p, { value: lsb === 0 && width >= base.w ? fit(value, base.w) : insert(base, lsb, fit(value, width)), write: rec });
      }
    }

    function exec(s, ctx) {
      if (!s) { return; }
      if (++ctx.statements > MAX_STATEMENTS) { if (ctx.statements === MAX_STATEMENTS + 1) { ctx.reasons.push({ code: 'budget' }); } return; }
      switch (s.k) {
        case 'seq': for (const x of s.s) { exec(x, ctx); } return;
        case 'decl': {
          const v = s.init ? evalExpr(s.init, ctx, s.width).value : allX(s.width);
          ctx.locals.set(s.name, { value: v, write: s.init ? { stmt: s, value: v, decl: true, lhs: { name: s.name }, ctx: { m: ctx.m, vals: ctx.vals, locals: new Map(ctx.locals), blocking: new Map(ctx.blocking) }, decisions: ctx.decisions.slice() } : null });
          return;
        }
        case 'asgn': {
          const lhs = s.lhs;
          const w = lhs.concat ? lhs.width : (lhs.width || widthOfTarget(ctx, lhs.name) || s.rhs.width || 1);
          const v = evalExpr(s.rhs, ctx, w).value;
          write(ctx, s, lhs, v);
          return;
        }
        case 'timed': ctx.reasons.push({ code: 'delay', src: s.src }); exec(s.stmt, ctx); return;
        case 'if': {
          const c = evalExpr(s.c, ctx).value;
          const t = X.truthy(c);
          const unknown = !t && hasX(c);
          const d = { kind: 'if', stmt: s, value: c, taken: t ? 'then' : 'else', xCond: unknown };
          if (unknown && ctx.mode === 'xprop') {
            d.taken = 'merge';
            ctx.decisions.push(d);
            runMerged(ctx, [s.t, s.f || null], d);
            return;
          }
          ctx.decisions.push(d);
          ctx.path.push({ stmt: s, branch: t ? 't' : 'f' });
          exec(t ? s.t : s.f, ctx);
          ctx.path.pop();
          return;
        }
        case 'case': {
          const sel = evalExpr(s.e, ctx).value;
          let hit = -1;
          // Items are compared as written (a width context would turn their z wildcards into x).
          const matches = s.items.map((it) => it.m.map((m) => evalExpr(m, ctx).value));
          for (let i = 0; i < s.items.length && hit < 0; i++) {
            if (matches[i].some((v) => caseMatch(sel, v, s.cond))) { hit = i; }
          }
          const d = { kind: 'case', stmt: s, value: sel, taken: hit >= 0 ? hit : 'default', xCond: hasX(sel) };
          if (d.xCond && ctx.mode === 'xprop' && s.cond === 'Normal') {
            // Every item that could match an x selector, and the default.
            const branches = [];
            s.items.forEach((it, i) => { if (matches[i].some((v) => caseMayMatch(sel, v))) { branches.push(it.s); } });
            branches.push(s.dflt || null);
            d.taken = 'merge';
            ctx.decisions.push(d);
            runMerged(ctx, branches, d);
            return;
          }
          if (s.check === 'Unique' || s.check === 'Unique0' || s.check === 'Priority') {
            const n = matches.filter((ms) => ms.some((v) => caseMatch(sel, v, s.cond))).length;
            if (n === 0 && !s.dflt && s.check !== 'Unique0') { d.violation = 'noMatch'; }
            if (n > 1 && s.check !== 'Priority') { d.violation = 'multipleMatches'; }
          }
          ctx.decisions.push(d);
          ctx.path.push({ stmt: s, branch: hit >= 0 ? hit : 'd' });
          exec(hit >= 0 ? s.items[hit].s : s.dflt, ctx);
          ctx.path.pop();
          return;
        }
        default:
          ctx.reasons.push({ code: 'statement', why: s.why, src: s.src });
      }
    }

    // X-propagation: run each branch from the same state and merge what they write, per bit
    // (a branch that doesn't write a variable keeps its value there).
    function runMerged(ctx, branches, decision) {
      const runs = branches.map((b) => { const c = fork(ctx); exec(b, c); return c; });
      const targets = new Set();
      for (const r of runs) { for (const p of r.writes.keys()) { targets.add(p); } for (const p of r.blocking.keys()) { targets.add(p); } }
      for (const r of runs) { r.reasons.forEach((x) => ctx.reasons.push(x)); r.missing.forEach((x) => ctx.missing.add(x)); r.needElems.forEach((x) => ctx.needElems.add(x)); }
      for (const p of targets) {
        const name = relOf(ctx.m, p);
        const w = widthOfTarget(ctx, name) || 1;
        let merged = null;
        const recs = [];
        for (const r of runs) {
          const v = r.blocking.has(p) ? r.blocking.get(p).value : lastFull(r, p, name, w);
          merged = merged ? merge(merged, v) : v;
          const ws = r.writes.get(p);
          const before = ctx.writes.get(p) || [];
          if (ws && ws.length > before.length) { recs.push(...ws.slice(before.length)); }
        }
        const rec = { stmt: recs.length ? recs[recs.length - 1].stmt : null, merged: recs, lhs: { name }, target: name, lsb: 0, width: w, value: merged, decisions: ctx.decisions.slice(), path: ctx.path.slice(), ctx: { m: ctx.m, vals: ctx.vals, locals: new Map(ctx.locals), blocking: new Map(ctx.blocking) }, xprop: decision };
        if (!ctx.writes.has(p)) { ctx.writes.set(p, []); }
        ctx.writes.get(p).push(rec);
        if (runs.some((r) => r.blocking.has(p))) { ctx.blocking.set(p, { value: merged, write: rec }); }
      }
      ctx.statements = Math.max(...runs.map((r) => r.statements));
    }
    // A variable's value at the end of a run: its writes applied to the value before.
    function lastFull(run, p, name, w) {
      let v = currentValue(Object.assign({}, run, { blocking: new Map() }), name, w);
      for (const rec of run.writes.get(p) || []) { v = rec.lsb === 0 && rec.width >= w ? fit(rec.value, w) : insert(v, rec.lsb, fit(rec.value, rec.width)); }
      return v;
    }

    // Every leaf a procedure may read (fetched in one batch at its sample time).
    function procReads(m, p, out) {
      const visit = (s) => {
        if (!s) { return; }
        switch (s.k) {
          case 'seq': s.s.forEach(visit); return;
          case 'decl': leafPaths(m, s.init, out); return;
          case 'asgn': leafPaths(m, s.rhs, out); lvalReads(m, s.lhs, out); return;
          case 'timed': visit(s.stmt); return;
          case 'if': leafPaths(m, s.c, out); visit(s.t); visit(s.f); return;
          case 'case': leafPaths(m, s.e, out); s.items.forEach((it) => { it.m.forEach((x) => leafPaths(m, x, out)); visit(it.s); }); visit(s.dflt); return;
          default:
        }
      };
      visit(p.body);
      return out;
    }
    function lvalReads(m, lhs, out) {
      if (!lhs) { return; }
      if (lhs.concat) { lhs.concat.forEach((x) => lvalReads(m, x, out)); return; }
      if (lhs.elem) { leafPaths(m, lhs.elem, out); }
      if (lhs.off) { leafPaths(m, lhs.off, out); }
      // A partial write keeps the other bits: the target's own value is read too.
      if (lhs.name && !isLocal(lhs.name) && (lhs.lsb !== undefined || lhs.off)) { out.add(absOf(m.path, lhs.name)); }
    }
    function writesTo(lhs, name) {
      if (!lhs) { return false; }
      if (lhs.concat) { return lhs.concat.some((x) => writesTo(x, name)); }
      return lhs.name === name;
    }
    function stmtWrites(s, name) {
      if (!s) { return false; }
      switch (s.k) {
        case 'seq': return s.s.some((x) => stmtWrites(x, name));
        case 'asgn': return writesTo(s.lhs, name);
        case 'timed': return stmtWrites(s.stmt, name);
        case 'if': return stmtWrites(s.t, name) || stmtWrites(s.f, name);
        case 'case': return s.items.some((it) => stmtWrites(it.s, name)) || stmtWrites(s.dflt, name);
        default: return false;
      }
    }

    // ---- drivers ----
    // The drivers of `name` (relative to model m): assigns, procedures, the instance's input
    // port (connected in the parent), and child instances' output ports connected to it.
    function driversOf(m, name) {
      let idx = indexCache.get(m);
      if (!idx) { idx = new Map(); indexCache.set(m, idx); }
      if (idx.has(name)) { return idx.get(name); }
      const out = [];
      const s = signalOf(m, name);
      const base = s && s.element ? s.element.array : name;
      m.assigns.forEach((a, i) => { if (writesTo(a.lhs, base)) { out.push({ type: 'assign', a, i }); } });
      m.procs.forEach((p) => { if (stmtWrites(p.body, base)) { out.push({ type: 'proc', p }); } });
      for (const port of m.ports) {
        if ((port.dir === 'In' || port.dir === 'InOut') && port.internal === base && port.conn && m.parent) { out.push({ type: 'portIn', port }); }
      }
      for (const child of m.children) {
        for (const port of child.ports) {
          if ((port.dir === 'Out' || port.dir === 'InOut') && port.connLval && writesTo(port.connLval, base)) { out.push({ type: 'portOut', child, port }); }
        }
      }
      idx.set(name, out);
      return out;
    }

    async function fetch(paths, t) {
      const list = [...paths];
      const raw = list.length ? await dump.values(list, t) : new Map();
      const out = new Map();
      for (const p of list) {
        const bits = raw.get(p);
        out.set(p, bits === undefined || bits === null ? undefined : X.fromBits(String(bits), String(bits).length));
      }
      return out;
    }

    // Runs a procedure at one sample time, fetching array elements its run reads.
    async function runProc(m, p, sample, extra, mode) {
      const reads = procReads(m, p, new Set());
      const vals = await fetch(reads, sample);
      for (const [k, v] of extra || []) { vals.set(k, v); }
      let ctx;
      for (let round = 0; ; round++) {
        ctx = newCtx(m, vals, mode);
        exec(p.body, ctx);
        if (!ctx.needElems.size || round >= MAX_ELEMENT_ROUNDS) { break; }
        const more = await fetch(ctx.needElems, sample);
        for (const [k, v] of more) { vals.set(k, v); }
      }
      return ctx;
    }

    // Values for display: a cmux value -> bits text.
    const shown = (v) => bitsOf(X, v);

    function faninOf(m, e, reads, time, role, out) {
      for (const r of reads) {
        if (r.src === 'opaque') { continue; }
        const entry = { role, time };
        if (r.leaf !== undefined) {
          entry.name = r.name;
          entry.locs = (e.leafLocs && e.leafLocs[r.leaf] || []).map((l) => locOf(m, l)).filter(Boolean);
        } else if (r.elem !== undefined) {
          entry.name = r.k !== undefined ? `${r.name}[${r.k}]` : r.name;
          const el = e.elems[r.elem];
          if (el && el.index) { faninOf(m, el.index, r.index ? r.index.reads : [], time, 'index', out); }
        }
        entry.value = shown(r.value);
        entry.width = r.value.w;
        if (r.src === 'local') { entry.local = true; entry.name = r.name.slice(7); if (r.write) { entry.via = { src: r.write.stmt.src, loc: locOf(m, r.write.stmt.loc) }; } }
        else if (r.src === 'blocking') { entry.path = r.path; entry.blocking = true; if (r.write) { entry.via = { src: r.write.stmt && r.write.stmt.src, loc: r.write.stmt && locOf(m, r.write.stmt.loc) }; } }
        else if (r.path) { entry.path = r.path; }
        entry.dumped = !(r.src === 'notDumped' || r.src === 'elemNotDumped' || r.src === 'notFetched');
        if (r.src === 'xIndex') { entry.xIndex = true; }
        const key = (entry.path || entry.name) + '|' + role;
        if (!out.some((x) => (x.path || x.name) + '|' + x.role === key)) { out.push(entry); }
      }
      return out;
    }

    // Re-runs an expression only to list its reads (fan-in), in the context it was evaluated in.
    function readsOf(e, wctx, width) {
      const ctx = Object.assign(newCtx(wctx.m, wctx.vals), { locals: wctx.locals || new Map(), blocking: wctx.blocking || new Map() });
      return evalExpr(e, ctx, width).reads;
    }

    function decisionsOut(m, ds) {
      return ds.filter((d) => d.kind === 'if' || d.kind === 'case').map((d) => {
        const s = d.stmt;
        const out = { kind: d.kind, src: d.kind === 'if' ? s.c.src : s.e.src, loc: locOf(m, (d.kind === 'if' ? s.c.loc : s.e.loc) || s.loc), stmtLoc: locOf(m, s.loc), value: shown(d.value), taken: d.taken, xCond: d.xCond };
        // The branch taken and the ones not taken (the editor dims those).
        const branches = d.kind === 'if' ? [['then', s.t], ['else', s.f]] : s.items.map((it, i) => [i, it.s]).concat([['default', s.dflt]]);
        out.untaken = branches.filter(([k, b]) => b && b.loc && k !== d.taken && d.taken !== 'merge').map(([, b]) => locOf(m, b.loc));
        const taken = branches.find(([k]) => k === d.taken);
        if (taken && taken[1]) { out.takenLoc = locOf(m, taken[1].loc); }
        if (d.kind === 'case' && typeof d.taken === 'number' && s.items[d.taken].m[0]) { out.item = s.items[d.taken].m.map((x) => x.src).join(', '); }
        if (d.violation) { out.violation = d.violation; }
        return out;
      });
    }

    // The clock and async controls of an edge procedure: an event whose signal the top if reads
    // is an async control; the remaining one is the clock (the usual synthesis rule).
    function clocking(m, p) {
      let top = p.body;
      while (top && top.k === 'seq' && top.s.length === 1) { top = top.s[0]; }
      if (top && top.k === 'seq' && top.s[0] && top.s[0].k === 'if') { top = top.s[0]; }
      const condLeaves = new Set(top && top.k === 'if' ? top.c.leaves : []);
      const evs = p.events.filter((e) => e.edge !== 'Other' && e.expr && e.expr.leaves.length).map((e) => ({ edge: e.edge, name: e.expr.leaves[0], path: absOf(m.path, e.expr.leaves[0]), iff: e.iff, simple: /^_L0_$/.test(e.expr.text) }));
      const asyncs = evs.filter((e) => condLeaves.has(e.name));
      const clocks = evs.filter((e) => !condLeaves.has(e.name));
      return { clock: clocks.length === 1 ? clocks[0] : (clocks[0] || null), asyncs, all: evs };
    }
    // Initial and final blocks, and an always that waits on a delay (always #5 clk = ~clk): the
    // testbench's stimulus, not logic re-run from its inputs.
    const isStimulus = (p) => p.kind === 'Initial' || p.kind === 'Final'
      || (p.kind === 'Always' && p.events.some((e) => e.edge === 'Other' && e.kind !== 'ImplicitEvent'));
    const isEdgeProc = (p) => p.events.some((e) => e.edge === 'PosEdge' || e.edge === 'NegEdge' || e.edge === 'BothEdges');

    // ---- the step ----
    async function active(path, time, opts) {
      const o = opts || {};
      const t = Number(time);
      const where = await models.lookup(path);
      if (!where || !where.instance) { return { signal: path, time: t, error: 'notInDesign' }; }
      const m = await model(where.instance);
      const name = where.name;
      const sig = signalOf(m, name);
      const step = { signal: path, time: t, instance: m.path, name, reasons: [] };
      if (!sig) { step.error = 'notASignal'; return step; }
      step.width = sig.width;
      if (sig.loc) { step.declLoc = locOf(m, sig.loc); }
      const now = (await fetch([path], t)).get(path);
      step.value = shown(now);
      step.dumped = now !== undefined;
      if (now === undefined) { step.reasons.push({ code: 'targetNotDumped', path }); }
      step.since = now === undefined ? null : await dump.lastChange(path, t);
      // The instance's own drivers, else statements of other instances that write into it.
      let cands = driversOf(m, name).map((d) => ({ m, d, name }));
      if (!cands.length) { cands = await outsideDrivers(m, name); }
      const all = cands.map((c) => c.d);
      step.drivers = cands.map((c) => Object.assign(driverSummary(c.m, c.d), c.m === m ? {} : { writer: c.m.path }));
      const live = cands.filter((c) => c.d.type !== 'proc' || !isStimulus(c.d.p));
      if (!all.length) {
        step.driver = { kind: sig.kind === 'net' ? 'undriven' : 'none' };
        if (!m.parent && m.ports.some((p) => p.internal === name && p.dir === 'In')) { step.driver.kind = 'topInput'; }
        if (sig.init) { step.driver.kind = 'initializer'; step.stmt = { src: sig.init.src, loc: locOf(m, sig.init.loc) }; }
        step.trust = 'exact';
        return step;
      }
      if (!live.length) {
        // Only stimulus: the testbench (tracing stops here by default).
        const c = cands.find((x) => x.d.type === 'proc') || cands[0];
        const d = c.d, cm = c.m;
        step.driver = { kind: 'initial', procKind: d.p.kind, loc: locOf(cm, d.p.loc) };
        if (cm !== m) { step.driver.writer = cm.path; }
        const writes = [];
        collectWrites(d.p.body, c.name, writes);
        step.stmt = writes.length ? { src: writes[writes.length - 1].src, loc: locOf(cm, writes[writes.length - 1].loc) } : { src: d.p.body.src, loc: locOf(cm, d.p.loc) };
        step.candidates = writes.slice(0, 32).map((s) => ({ src: s.src, loc: locOf(cm, s.loc) }));
        step.root = 'testbench';
        step.trust = 'approximate';
        step.reasons.push({ code: 'testbench' });
        return step;
      }
      if (live.length > 1) { step.reasons.push({ code: 'multiDriven', count: live.length }); }
      // Each live driver is tried; the one whose prediction agrees with the dump is the active one.
      let best = null;
      for (const c of live) {
        const r = await runDriver(c.m, c.d, c.name, sig, t, now, step.since, o);
        if (c.m !== m) { r.driver.writer = c.m.path; }
        if (!best || rank(r) > rank(best)) { best = r; }
        if (rank(r) >= 3) { break; }
      }
      Object.assign(step, best, { reasons: step.reasons.concat(best.reasons || []) });
      step.trust = trustOf(step);
      return step;
    }

    function rank(r) {
      if (r.wrote === false) { return 0; }
      if (r.consistent === true) { return 3; }
      if (r.consistent === undefined) { return 2; }
      return 1;
    }

    function trustOf(step) {
      if (step.consistent === false) { return 'inconsistent'; }
      const approximate = step.reasons.some((r) => ['opaque', 'limits', 'evaluator', 'statement', 'delay', 'lvalue', 'budget', 'notDumped', 'testbench', 'xprop', 'race', 'targetNotDumped', 'noActivation'].includes(r.code));
      if (approximate) { return 'approximate'; }
      return step.computed ? 'computed' : 'exact';
    }

    function collectWrites(s, name, out) {
      if (!s) { return; }
      switch (s.k) {
        case 'seq': s.s.forEach((x) => collectWrites(x, name, out)); return;
        case 'asgn': if (writesTo(s.lhs, name)) { out.push(s); } return;
        case 'timed': collectWrites(s.stmt, name, out); return;
        case 'if': collectWrites(s.t, name, out); collectWrites(s.f, name, out); return;
        case 'case': s.items.forEach((it) => collectWrites(it.s, name, out)); collectWrites(s.dflt, name, out); return;
        default:
      }
    }

    function driverSummary(m, d) {
      if (d.type === 'assign') { return { kind: 'assign', src: d.a.src, loc: locOf(m, d.a.loc) }; }
      if (d.type === 'proc') { return { kind: 'proc', procKind: d.p.kind, src: d.p.body.src, loc: locOf(m, d.p.loc) }; }
      if (d.type === 'portIn') { return { kind: 'portIn', port: d.port.name, instance: m.path, src: d.port.conn.src, loc: locOf(m, d.port.loc) }; }
      return { kind: 'portOut', port: d.port.name, instance: d.child.path, src: d.port.conn ? d.port.conn.src : '', loc: locOf(m, d.port.loc) };
    }

    // The bits of the target a write covers, compared with the dump: undefined when not comparable.
    function consistentWith(rec, now, sig) {
      if (!now || !rec || !rec.value) { return undefined; }
      if (rec.width >= now.w && rec.lsb === 0) { return same(fit(rec.value, now.w), now); }
      if (rec.lsb + rec.width > now.w) { return undefined; }
      return same(slice(now, rec.lsb, rec.width), rec.value);
    }

    async function runDriver(m, d, name, sig, t, now, since, o) {
      const r = { reasons: [] };
      r.driver = driverSummary(m, d);
      if (d.type === 'assign') {
        const vals = await fetch(leafPaths(m, d.a.rhs, new Set()), t);
        let ctx = newCtx(m, vals, options.xprop === 'on' ? 'xprop' : 'optimistic');
        await fillElements(ctx, m, d.a.rhs, t);
        if (d.a.opaque !== undefined || !d.a.lhs) { r.reasons.push({ code: 'lvalue', src: d.a.src }); return r; }
        const w = d.a.lhs.concat ? d.a.lhs.width : (d.a.lhs.width || sig.width);
        let ev = evalExpr(d.a.rhs, ctx, w);
        if (options.xprop === 'auto' && ctx.sawXIndex && now) {
          // An x index under X-propagation reads the merge of the elements it could name.
          const xctx = newCtx(m, vals, 'xprop');
          await fillElements(xctx, m, d.a.rhs, t);
          const xev = evalExpr(xctx.m ? d.a.rhs : d.a.rhs, xctx, w);
          const before = recFor(ctx, d.a.lhs, name, ev.value, w), after = recFor(xctx, d.a.lhs, name, xev.value, w);
          if (consistentWith(before, now, sig) === false && consistentWith(after, now, sig) === true) { ctx = xctx; ev = xev; r.reasons.push({ code: 'xprop' }); }
        }
        ctx.reasons.forEach((x) => r.reasons.push(x));
        if (d.a.delay) { r.reasons.push({ code: 'delay', src: d.a.src }); }
        const rec = recFor(ctx, d.a.lhs, name, ev.value, w);
        r.stmt = { src: d.a.src, loc: locOf(m, d.a.loc), rhs: d.a.rhs.src, rhsLoc: locOf(m, d.a.rhs.loc) };
        r.sample = t;
        r.predicted = rec ? shown(rec.value) : null;
        r.bits = rec ? { lsb: rec.lsb, width: rec.width } : null;
        r.consistent = consistentWith(rec, now, sig);
        r.fanin = faninOf(m, d.a.rhs, ev.reads, t, 'data', []);
        notDumped(r, ctx);
        if (r.consistent === false) { explainMismatch(r, ctx); }
        return r;
      }
      if (d.type === 'portIn' || d.type === 'portOut') {
        // A port hop: the value passes through unchanged.
        let pm, e, label;
        if (d.type === 'portIn') { pm = await model(m.parent); e = d.port.conn; label = d.port.name; }
        else { pm = await model(d.child.path); e = { text: '_L0_', leaves: [d.port.internal], leafLocs: [[]], width: d.port.width, src: d.port.internal }; label = d.port.name; }
        const vals = await fetch(leafPaths(pm, e, new Set()), t);
        const ctx = newCtx(pm, vals);
        await fillElements(ctx, pm, e, t);
        const ev = evalExpr(e, ctx, sig.width);
        ctx.reasons.forEach((x) => r.reasons.push(x));
        r.stmt = { src: d.type === 'portIn' ? `.${label}(${e.src || e.text})` : `.${label}(${d.port.conn ? d.port.conn.src : ''})`, loc: locOf(m, d.port.loc) };
        r.port = { name: label, dir: d.port.dir, instance: d.type === 'portIn' ? m.path : d.child.path };
        r.sample = t;
        // An output port into a part of the parent's net covers those bits only.
        const lhs = d.type === 'portOut' ? d.port.connLval : null;
        const rec = lhs ? recFor(ctx, lhs, name, ev.value, lhs.concat ? lhs.width : (lhs.width || sig.width)) : { lsb: 0, width: sig.width, value: fit(ev.value, sig.width) };
        r.predicted = rec ? shown(rec.value) : null;
        r.bits = rec ? { lsb: rec.lsb, width: rec.width } : null;
        r.consistent = consistentWith(rec, now, sig);
        r.fanin = faninOf(pm, e, ev.reads, t, 'data', []);
        notDumped(r, ctx);
        if (r.consistent === false) { explainMismatch(r, ctx); }
        return r;
      }
      return runProcDriver(m, d.p, name, sig, t, now, since, o, r);
    }

    // A write record for the part of an lvalue (assign or port) that names `name`.
    function recFor(ctx, lhs, name, value, width) {
      const c = newCtx(ctx.m, ctx.vals);
      c.locals = ctx.locals; c.blocking = new Map();
      write(c, { src: '', nb: true }, lhs, fit(value, width));
      const s = signalOf(ctx.m, name);
      const base = s && s.element ? s.element.array : name;
      for (const [p, recs] of c.writes) {
        const rel = relOf(ctx.m, p);
        if (rel === name || (s && s.element && rel === name) || (!s?.element && rel === base)) { return recs[recs.length - 1]; }
      }
      return null;
    }

    async function fillElements(ctx, m, e, t) {
      for (let round = 0; round < MAX_ELEMENT_ROUNDS; round++) {
        ctx.needElems = new Set();
        evalExpr(e, ctx);
        if (!ctx.needElems.size) { break; }
        const more = await fetch(ctx.needElems, t);
        for (const [k, v] of more) { ctx.vals.set(k, v); }
      }
      ctx.reasons = [];
      ctx.missing = new Set();
    }

    // Leaves missing from the dump: listed, and the prediction (made with x for them) can't be
    // held against the dump.
    function notDumped(r, ctx) {
      for (const p of ctx.missing) { r.reasons.push({ code: 'notDumped', path: p }); }
      if (ctx.missing.size && r.consistent === false) { r.consistent = undefined; }
    }

    function explainMismatch(r, ctx) {
      if (ctx.missing.size) { return; }
      if (!r.reasons.some((x) => ['opaque', 'limits', 'evaluator', 'statement', 'lvalue'].includes(x.code))) {
        r.reasons.push({ code: 'mismatch', predicted: r.predicted });
      }
    }

    async function runProcDriver(m, p, name, sig, t, now, since, o, r) {
      const s = sig;
      // An outside writer's target is already an $abs: path.
      const target = s.element && !name.startsWith('$abs:') ? `${s.element.array}[${s.element.k}]` : name;
      const targetPath = absOf(m.path, target);
      r.procKind = p.kind;
      let sample = t;
      let trigger = null;
      const extra = new Map();
      const edge = isEdgeProc(p);
      if (edge) {
        const ck = clocking(m, p);
        r.clock = ck.clock ? { edge: ck.clock.edge, path: ck.clock.path } : null;
        // The activation that produced the value in effect: the edge at its last change, else
        // (x since the start, or no change) the last clock edge at or before t.
        let te = null;
        const xFromStart = now && hasX(now) && (since === 0 || since === null);
        if (since !== null && since !== undefined && !xFromStart) {
          for (const ev of ck.all) {
            if (await dump.prevEdge(ev.path, since, ev.edge) === since) { te = since; trigger = ev; break; }
          }
          if (te === null) {
            if (since === 0) { r.reasons.push({ code: 'initialValue' }); }
            else { r.reasons.push({ code: 'noActivation', time: since }); }
            te = since;
          }
        } else if (ck.clock) {
          te = await dump.prevEdge(ck.clock.path, t, ck.clock.edge);
          trigger = ck.clock;
        }
        if (te === null) { r.wrote = false; r.reasons.push({ code: 'noEdge' }); r.stmt = { src: p.body.src, loc: locOf(m, p.loc) }; return r; }
        sample = te > 0 ? te - 1 : 0;
        r.activation = { time: te, trigger: trigger ? { edge: trigger.edge, path: trigger.path } : null };
        if (trigger) { const tv = await fetch([trigger.path], te); extra.set(trigger.path, tv.get(trigger.path)); }
      }
      r.sample = sample;
      let ctx = await runProc(m, p, sample, extra, options.xprop === 'on' ? 'xprop' : 'optimistic');
      let pick = pickWrite(ctx, targetPath, s);
      let consistent = pick ? consistentWith(pick, now, sig) : undefined;
      // X-propagation: an x condition on the path and a dump that disagrees: try merged branches.
      if (options.xprop === 'auto' && consistent === false && (ctx.decisions.some((d) => d.xCond) || ctx.sawXIndex)) {
        const merged = await runProc(m, p, sample, extra, 'xprop');
        const mp = pickWrite(merged, targetPath, s);
        if (mp && consistentWith(mp, now, sig) === true) {
          ctx = merged; pick = mp; consistent = true;
          r.reasons.push({ code: 'xprop' });
        }
      }
      // A same-time race: inputs changed at the edge itself; the post-edge values may explain it.
      if (edge && consistent === false && r.activation) {
        const late = await runProc(m, p, r.activation.time, extra, ctx.mode);
        const lp = pickWrite(late, targetPath, s);
        if (lp && consistentWith(lp, now, sig) === true) { r.reasons.push({ code: 'race', time: r.activation.time }); ctx = late; pick = lp; consistent = true; }
      }
      // A comb procedure that didn't write the target on its path holds it (a latch): the
      // activation is when it last changed.
      if (!pick && !edge && since !== null && since !== undefined && since !== t) {
        const held = await runProc(m, p, since, extra, ctx.mode);
        const hp = pickWrite(held, targetPath, s);
        if (hp) { r.reasons.push({ code: 'held', time: since }); ctx = held; pick = hp; consistent = consistentWith(hp, now, sig); r.sample = since; }
      }
      ctx.reasons.forEach((x) => r.reasons.push(x));
      r.decisions = decisionsOut(m, pick ? pick.decisions : ctx.decisions);
      r.fanin = [];
      if (r.activation && r.activation.trigger) {
        const tp = r.activation.trigger.path;
        r.fanin.push({ role: 'clock', path: tp, name: relOf(m, tp), value: shown(extra.get(tp)), time: r.activation.time, dumped: extra.get(tp) !== undefined });
      }
      // The conditions on the way to the write (or to nowhere: everything decided).
      for (const dd of (pick ? pick.decisions : ctx.decisions)) {
        if (dd.kind !== 'if' && dd.kind !== 'case') { continue; }
        const e = dd.kind === 'if' ? dd.stmt.c : dd.stmt.e;
        faninOf(m, e, readsOf(e, { m, vals: ctx.vals, locals: new Map(), blocking: new Map() }), r.sample, 'control', r.fanin);
      }
      if (!pick) {
        r.wrote = false;
        r.stmt = { src: p.body.src, loc: locOf(m, p.loc) };
        r.reasons.push({ code: 'noWrite' });
        notDumped(r, ctx);
        return r;
      }
      if (pick.merged) {
        r.merged = pick.merged.map((w) => ({ src: w.stmt.src, loc: locOf(m, w.stmt.loc) }));
        r.stmt = pick.stmt ? { src: pick.stmt.src, loc: locOf(m, pick.stmt.loc) } : { src: p.body.src, loc: locOf(m, p.loc) };
        for (const w of pick.merged) { faninOf(m, w.stmt.rhs, readsOf(w.stmt.rhs, w.ctx, w.width), r.sample, 'data', r.fanin); }
      } else {
        r.stmt = { src: pick.stmt.src, loc: locOf(m, pick.stmt.loc), rhs: pick.stmt.rhs.src, rhsLoc: locOf(m, pick.stmt.rhs.loc), nb: !!pick.stmt.nb };
        const reads = readsOf(pick.stmt.rhs, pick.ctx, pick.lhs && pick.lhs.concat ? pick.lhs.width : pick.width);
        faninOf(m, pick.stmt.rhs, reads, r.sample, 'data', r.fanin);
        if (pick.lhs && pick.lhs.elem) { faninOf(m, pick.lhs.elem, readsOf(pick.lhs.elem, pick.ctx), r.sample, 'index', r.fanin); }
        if (reads.some((x) => x.src === 'local' || x.src === 'blocking')) { r.computed = true; }
      }
      r.predicted = shown(pick.value);
      r.bits = { lsb: pick.lsb, width: pick.width };
      r.consistent = consistent;
      r.path = (pick.path || []).map((x) => ({ loc: locOf(m, x.stmt.loc), branch: x.branch }));
      // A plain `always @*` does not run at time 0 (always_comb does): x since the start
      // with an input that has not changed yet is the block not having run.
      if (consistent === false && !edge && p.kind === 'Always' && now && hasX(now) && (since === 0 || since === null || since === undefined)) {
        r.reasons.push({ code: 'noActivation', time: 0 });
        r.consistent = undefined;
      }
      notDumped(r, ctx);
      if (r.consistent === false) { explainMismatch(r, ctx); }
      return r;
    }

    // The write that produced the target: the last one in the run that covers it.
    function pickWrite(ctx, targetPath, s) {
      const recs = ctx.writes.get(targetPath);
      if (recs && recs.length) { return recs[recs.length - 1]; }
      return null;
    }

    return { active, model, driversOf: async (path) => { const w = await models.lookup(path); const m = await model(w.instance); return driversOf(m, w.name).map((d) => driverSummary(m, d)); } };
  }

  root.cmuxTrace = Object.freeze({ createEngine, MODEL_VERSION });
})(typeof window !== 'undefined' ? window : globalThis);
