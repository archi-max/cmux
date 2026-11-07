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
//     dump.nextChange(path, time) -> Promise<number | null>   (optional) the first change at or
//         after time, null: none (or not dumped). Without it, nextOf answers null.
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
      // The target's width is the context width (no `W'b0 | (...)` wrapper: an OR makes z bits x).
      const p = parse(e.text);
      if (p.error) {
        ctx.reasons.push({ code: p.error === 'tooManySignals' || p.error === 'tooLong' ? 'limits' : 'evaluator', src: e.src, error: p.error });
        return { value: allX(width || Math.max(1, e.width || 1)), reads, failed: true };
      }
      const r = X.evaluate(p.ast, env, width ? { width } : undefined);
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
        reasons: [], missing: new Set(), needElems: new Set(), elemsRead: new Set(), statements: 0, path: [], opaque: [], ran: new Set() };
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
      if (lhs.opaque !== undefined || !lhs.name) {
        ctx.reasons.push({ code: 'lvalue', src: lhs.opaque || s.src });
        // The variable it writes, when the model knows it: the write ran, its bits aren't modelled.
        if (lhs.name) { ctx.opaque.push({ stmt: s, name: lhs.name }); }
        return;
      }
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
      ctx.ran.add(s);
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
          // What the functions its right side calls write (the model's "writes").
          ranWrites(s, ctx);
          return;
        }
        case 'timed': ctx.reasons.push({ code: 'delay', src: s.src }); exec(s.stmt, ctx); return;
        case 'if': {
          ranWrites(s, ctx);
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
          ranWrites(s, ctx);
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
          ranWrites(s, ctx);
      }
    }
    // A statement that isn't re-executed (or a condition with side effects, such as a
    // $value$plusargs output, or an assignment whose right side calls a function that writes a
    // module variable) ran: what the model says it writes.
    function ranWrites(s, ctx) {
      if (Array.isArray(s.writes)) { s.writes.forEach((w) => ctx.opaque.push({ stmt: s, name: w.name })); }
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
    // What an opaque statement or a condition with side effects writes (the model's "writes").
    const opaqueWrites = (s, name) => Array.isArray(s.writes) && s.writes.some((w) => w.name === name);
    function stmtWrites(s, name) {
      if (!s) { return false; }
      if (opaqueWrites(s, name)) { return true; }
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
      // A net's declaration assignment (wire w = e) is a continuous assignment, not an initializer.
      if (s && s.kind === 'net' && s.init && !s.element) {
        out.push({ type: 'assign', i: -1, a: { lhs: { name, width: s.width, full: s.width, loc: s.loc }, rhs: s.init, src: `${name} = ${s.init.src || leafText(s.init)}`, loc: s.init.loc } });
      }
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

    // A read of a temp written earlier in the same run (a local, or a variable written blocking) also
    // lists what that write read: the temp's dumped value is not what was read (a block may end with
    // tmp = 'bx), so following the temp alone would go astray. `through` names the temp.
    function faninOf(m, e, reads, time, role, out, seen) {
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
        if (seen && seen.through) { entry.through = seen.through; }
        const key = (entry.path || entry.name) + '|' + role;
        if (!out.some((x) => (x.path || x.name) + '|' + x.role === key)) { out.push(entry); }
        const w = (r.src === 'local' || r.src === 'blocking') && r.write;
        const done = (seen && seen.writes) || new Set();
        // What the temp's write read: its rhs, or a declaration's initializer (logic t = e;).
        const rhs = w && w.stmt && (w.stmt.rhs || (w.decl && w.stmt.init));
        if (rhs && w.ctx && !done.has(w)) {
          // At most 16 temps' writes are followed; past that the fan-in is cut, and the step says so.
          if (done.size >= 16) { out.limited = true; continue; }
          done.add(w);
          faninOf(m, rhs, readsOf(rhs, w.ctx, w.width || w.stmt.width), time, role, out, { writes: done, through: (seen && seen.through) || entry.path || entry.name });
        }
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

    // The first statement slang could not elaborate (its writes unknown), or null.
    function unknownWrites(s) {
      if (!s || typeof s !== 'object') { return null; }
      if (s.k === 'opaque' && s.why === 'Invalid') { return s; }
      for (const k of ['s', 'stmt', 't', 'f', 'dflt']) {
        const v = s[k];
        const hit = Array.isArray(v) ? v.map(unknownWrites).find(Boolean) : unknownWrites(v);
        if (hit) { return hit; }
      }
      return Array.isArray(s.items) ? s.items.map((it) => unknownWrites(it.s)).find(Boolean) || null : null;
    }
    // Whether `now`, unchanged since `since`, is what the signal started with: its declaration's
    // initializer, else x, or 0 for a 2-state type (the model's `twoState`; without it, 4-state).
    // False when it changed after the start.
    async function startValue(m, sig, now, since) {
      if (Number(since) !== 0) { return false; }
      if (!sig.init) { return sig.twoState === true ? /^0+$/.test(shown(now)) : /^x+$/.test(shown(now)); }
      const vals = await fetch(leafPaths(m, sig.init, new Set()), 0);
      const ctx = newCtx(m, vals);
      await fillElements(ctx, m, sig.init, 0);
      const ev = evalExpr(sig.init, ctx, sig.width);
      return !ctx.reasons.length && same(fit(ev.value, now.w), now);
    }

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
      // Dumped, but when it last changed is unknown (the reader refused it): the activation found
      // from the clock is a guess.
      if (now !== undefined && step.since === null) { step.reasons.push({ code: 'sinceUnknown' }); }
      // The instance's own drivers, else statements of other instances that write into it.
      let cands = driversOf(m, name).map((d) => ({ m, d, name }));
      if (!cands.length) { cands = await outsideDrivers(m, name); }
      const all = cands.map((c) => c.d);
      step.drivers = cands.map((c) => Object.assign(driverSummary(c.m, c.d), c.m === m ? {} : { writer: c.m.path }));
      const live = cands.filter((c) => c.d.type !== 'proc' || !isStimulus(c.d.p));
      if (!all.length) {
        // A statement slang could not elaborate may write anything in its instance: its block is
        // the candidate, approximate.
        const unknown = m.procs.filter((p) => unknownWrites(p.body));
        if (unknown.length) {
          const uc = unknown.map((p) => ({ m, d: { type: 'proc', p }, name }));
          step.drivers = uc.map((c) => driverSummary(m, c.d));
          const op = unknownWrites(unknown[0].body);
          const opaque = { code: 'opaque', src: op.src, why: op.why };
          if (unknown.every(isStimulus)) { const r = stimulusStep(step, uc, m, name, sig, t); r.reasons.push(opaque); r.trust = trustOf(r); return r; }
          const p = unknown.find((x) => !isStimulus(x));
          step.driver = driverSummary(m, { type: 'proc', p });
          step.procKind = p.kind;
          step.stmt = { src: op.src, loc: locOf(m, op.loc || p.loc) };
          step.reasons.push(opaque);
          step.trust = trustOf(step);
          return step;
        }
        step.driver = { kind: sig.kind === 'net' ? 'undriven' : 'none' };
        const topInput = !m.parent && m.ports.some((p) => p.internal === name && p.dir === 'In');
        if (topInput) { step.driver.kind = 'topInput'; }
        if (sig.init) { step.driver.kind = 'initializer'; step.stmt = { src: sig.init.src, loc: locOf(m, sig.init.loc) }; }
        // Nothing found writes it, so its value is the one it started with: unless it changed after
        // the start or isn't that value, a write the model doesn't show made it (never exact).
        if (!topInput && now !== undefined && step.since !== null && !(await startValue(m, sig, now, step.since))) {
          if (step.driver.kind === 'initializer') { step.candidates = [step.stmt]; delete step.stmt; step.driver.kind = 'none'; }
          step.reasons.push({ code: 'writeNotFound' });
        }
        step.trust = trustOf(step);
        return step;
      }
      // Only stimulus: the testbench (tracing stops here by default).
      if (!live.length) { return stimulusStep(step, cands, m, name, sig, t); }
      const multi = live.length > 1 ? { code: 'multiDriven', count: live.length } : null;
      if (multi) { step.reasons.push(multi); }
      // Each live driver is tried; the one whose prediction agrees with the dump is the active one.
      // With several that agree, which one made the value is not known (multiDriven, consistent > 1:
      // approximate). A driver predicting all z (a tri-state driver that is off) adds nothing to a
      // resolved net, so it doesn't count.
      let best = null, agree = 0;
      for (const c of live) {
        const r = await runDriver(c.m, c.d, c.name, sig, t, now, step.since, o);
        if (c.m !== m) { r.driver.writer = c.m.path; }
        if (rank(r) >= 3 && !/^z+$/.test(r.predicted || '')) { agree++; }
        if (!best || rank(r) > rank(best)) { best = r; }
        if (rank(r) >= 3 && !multi) { break; }
      }
      if (multi) { multi.consistent = agree; }
      // The instance's own drivers can't explain the value (inconsistent, or no write): another
      // instance's write into it can (a testbench's force or $deposit, a hierarchical write). Its
      // statement is shown, approximate ('force'), with the own driver's answer as a candidate.
      if (rank(best) <= 1 && cands.every((c) => c.m === m)) {
        const outs = await outsideDrivers(m, name);
        const outLive = outs.filter((c) => c.d.type !== 'proc' || !isStimulus(c.d.p));
        let out = null;
        for (const c of outLive) {
          const r = await runDriver(c.m, c.d, c.name, sig, t, now, step.since, o);
          r.driver.writer = c.m.path;
          if (rank(r) >= 2 && (!out || rank(r) > rank(out))) { out = r; }
        }
        const own = best.stmt ? [{ src: best.stmt.src, loc: best.stmt.loc }] : [];
        if (out) {
          Object.assign(step, out, { reasons: step.reasons.concat(out.reasons || [], [{ code: 'force' }]) });
          step.candidates = own;
          step.trust = trustOf(step);
          return step;
        }
        if (outs.length) {
          const r = stimulusStep(step, outs, m, name, sig, t);
          r.reasons.push({ code: 'force' });
          r.candidates = own.concat(r.candidates || []).slice(0, 32);
          return r;
        }
      }
      Object.assign(step, best, { reasons: step.reasons.concat(best.reasons || []) });
      // Its process held the value since the start and never wrote it (a flop whose enable never
      // came): the value is the one it started with, not the process's doing (the process is a
      // candidate).
      if (best.wrote === false && Number(step.since) === 0 && now !== undefined && await startValue(m, sig, now, 0)) {
        const held = step.stmt ? [{ src: step.stmt.src, loc: step.stmt.loc }] : [];
        delete step.activation; delete step.decisions; delete step.stmt;
        step.driver = { kind: sig.init ? 'initializer' : 'none' };
        if (sig.init) { step.stmt = { src: sig.init.src || `${name} = ${sig.init.text}`, loc: locOf(m, sig.init.loc) }; }
        step.candidates = held;
        step.reasons = step.reasons.filter((r) => r.code !== 'noWrite');
      }
      step.trust = trustOf(step);
      return step;
    }

    // A testbench's statements write the signal (only stimulus, or another instance's force or
    // $deposit): the write in effect at t, approximate.
    function stimulusStep(step, cands, m, name, sig, t) {
      const c = cands.find((x) => x.d.type === 'proc') || cands[0];
      const d = c.d, cm = c.m;
      step.driver = { kind: 'initial', procKind: d.p.kind, loc: locOf(cm, d.p.loc) };
      if (cm !== m) { step.driver.writer = cm.path; }
      const writes = [];
      collectWrites(d.p.body, c.name, writes);
      // The write in effect at t (its #delays summed), else the body's last write.
      const at = d.p.kind === 'Initial' ? writeAt(d.p.body, c.name, step.since, t) : null;
      const shownWrite = at || writes[writes.length - 1];
      step.stmt = shownWrite ? { src: shownWrite.src, loc: locOf(cm, shownWrite.loc) } : { src: d.p.body.src, loc: locOf(cm, d.p.loc) };
      // Unchanged since 0 and no write at 0: the declaration's initializer.
      if (!at && Number(step.since) === 0 && sig.init && d.p.kind === 'Initial') { step.stmt = { src: sig.init.src || `${name} = ${sig.init.text}`, loc: locOf(m, sig.init.loc) }; }
      step.candidates = writes.slice(0, 32).map((s) => ({ src: s.src, loc: locOf(cm, s.loc) }));
      step.root = 'testbench';
      step.trust = 'approximate';
      step.reasons.push({ code: 'testbench' });
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
      const approximate = step.reasons.some((r) => (r.code === 'multiDriven' && r.consistent > 1) || ['opaque', 'limits', 'evaluator', 'statement', 'delay', 'lvalue', 'budget', 'notDumped', 'testbench', 'xprop', 'race', 'targetNotDumped', 'noActivation', 'sinceUnknown', 'force', 'writeNotFound'].includes(r.code));
      if (approximate) { return 'approximate'; }
      return step.computed ? 'computed' : 'exact';
    }

    // An initial block's writes to `name` with their start times in delay units ({ s, at }); after a
    // delay that is not a plain number (a unit, an expression, an event), the times are unknown.
    function timedWrites(s, name, at, out) {
      if (!s) { return at; }
      switch (s.k) {
        case 'seq': for (const x of s.s) { at = timedWrites(x, name, at, out); } return at;
        case 'asgn': if (writesTo(s.lhs, name)) { out.push({ s, at }); } return at;
        case 'timed': {
          // The control is what precedes the statement's own text (the source may start with comments).
          const all = String(s.src || ''), own = String((s.stmt && s.stmt.src) || '');
          const head = own && all.endsWith(own) ? all.slice(0, all.length - own.length) : all;
          const m = /#\s*(\d+)\s*$/.exec(head);
          return timedWrites(s.stmt, name, m && at !== null ? at + Number(m[1]) : null, out);
        }
        case 'if': case 'case': {
          const inner = [];
          collectWrites(s, name, inner);
          inner.forEach((x) => out.push({ s: x, at }));
          return hasTimed(s) ? null : at;
        }
        default: return hasTimed(s) ? null : at;
      }
    }
    function hasTimed(s) {
      if (!s || typeof s !== 'object') { return false; }
      if (s.k === 'timed') { return true; }
      return ['s', 'stmt', 't', 'f', 'dflt'].some((k) => (Array.isArray(s[k]) ? s[k].some(hasTimed) : hasTimed(s[k])))
        || (Array.isArray(s.items) && s.items.some((it) => hasTimed(it.s)));
    }
    // The write in effect at t: the dump's time unit per delay unit is a power of ten that puts one
    // of the writes at `since` (the value's last change); the last write at or before t under it
    // (the largest such scale when several fit). Null when none fits.
    function writeAt(body, name, since, t) {
      if (since === null || since === undefined) { return null; }
      const list = [];
      timedWrites(body, name, 0, list);
      const known = list.filter((w) => w.at !== null);
      let pick = null;
      for (let scale = 1; scale <= 1e15; scale *= 10) {
        if (!known.some((w) => w.at * scale === Number(since))) { continue; }
        const before = known.filter((w) => w.at * scale <= Number(t));
        if (before.length) { pick = before[before.length - 1].s; }
      }
      return pick;
    }

    function collectWrites(s, name, out) {
      if (!s) { return; }
      switch (s.k) {
        case 'seq': s.s.forEach((x) => collectWrites(x, name, out)); return;
        case 'asgn': if (writesTo(s.lhs, name) || opaqueWrites(s, name)) { out.push(s); } return;
        case 'timed': collectWrites(s.stmt, name, out); return;
        case 'if': collectWrites(s.t, name, out); collectWrites(s.f, name, out); return;
        case 'case': s.items.forEach((it) => collectWrites(it.s, name, out)); collectWrites(s.dflt, name, out); return;
        default: if (opaqueWrites(s, name)) { out.push(s); }
      }
    }

    function driverSummary(m, d) {
      if (d.type === 'assign') { return { kind: 'assign', src: d.a.src, loc: locOf(m, d.a.loc) }; }
      if (d.type === 'proc') { return { kind: 'proc', procKind: d.p.kind, src: d.p.body.src, loc: locOf(m, d.p.loc) }; }
      // (an input port's connection is the parent's text, evaluated there: `from`)
      if (d.type === 'portIn') { return { kind: 'portIn', port: d.port.name, instance: m.path, from: m.parent, src: connText(d.port.conn), loc: locOf(m, d.port.loc) }; }
      return { kind: 'portOut', port: d.port.name, instance: d.child.path, src: connText(d.port.conn), loc: locOf(m, d.port.loc) };
    }

    // A connection's source text; implicit .name and .* connections have none: their leaves'.
    function leafText(e) { return String(e.text || '').replace(/_L(\d+)_/g, (all, i) => (e.leaves && e.leaves[Number(i)] !== undefined ? e.leaves[Number(i)] : all)); }
    function connText(e) { return e ? (e.src || leafText(e)) : ''; }

    // The bits of the target a write covers, compared with the dump: undefined when not comparable.
    function consistentWith(rec, now, sig) {
      if (!now || !rec || !rec.value) { return undefined; }
      if (rec.after && rec.after.length) {
        // The chosen write's bits with the later writes laid over them, against the dump's same bits.
        const lo = rec.lsb || 0, hi = Math.min(now.w, lo + (rec.width || now.w));
        if (lo >= hi) { return undefined; }
        let v = fit(rec.value, hi - lo);
        for (const a of rec.after) {
          if (!a.value) { return undefined; }
          const alo = a.lsb || 0, aw = a.width || now.w, from = Math.max(lo, alo), to = Math.min(hi, alo + aw);
          if (from < to) { v = insert(v, from - lo, slice(fit(a.value, aw), from - alo, to - from)); }
        }
        return same(v, slice(now, lo, hi - lo));
      }
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
        const delayed = !!d.a.delay;
        const rec = recFor(ctx, d.a.lhs, name, ev.value, w);
        r.stmt = { src: d.a.src, loc: locOf(m, d.a.loc), rhs: d.a.rhs.src || leafText(d.a.rhs), rhsLoc: locOf(m, d.a.rhs.loc) };
        r.sample = t;
        r.predicted = rec ? shown(rec.value) : null;
        r.bits = rec ? { lsb: rec.lsb, width: rec.width } : null;
        r.consistent = consistentWith(rec, now, sig);
        // A delayed assignment's value at t is its right side's at t - d: not comparable at t.
        if (delayed && r.consistent === false) { r.consistent = undefined; }
        r.fanin = faninOf(m, d.a.rhs, ev.reads, t, 'data', []);
        if (r.fanin.limited) { r.reasons.push({ code: 'limits', why: 'temps' }); }
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
        r.stmt = { src: d.type === 'portIn' ? `.${label}(${e.src || leafText(e)})` : `.${label}(${connText(d.port.conn)})`, loc: locOf(m, d.port.loc) };
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
        // An x value may have been written again (x to x is no change): the value in effect came
        // from the last edge that wrote it, which can have another cause than the first x (a CPU
        // core's ALU result: an idle cycle's 'bx, later a jump's x operand). That edge, when its
        // run writes the same value.
        if (now && hasX(now) && !xFromStart && since && ck.clock) {
          const tl = await dump.prevEdge(ck.clock.path, t, ck.clock.edge);
          if (tl !== null && tl > since) {
            const tv = await fetch([ck.clock.path], tl);
            const lc = await runProc(m, p, tl - 1, new Map([[ck.clock.path, tv.get(ck.clock.path)]]), options.xprop === 'on' ? 'xprop' : 'optimistic');
            const lw = pickWrite(lc, targetPath, s, now);
            if (lw && consistentWith(lw, now, sig) === true) { te = tl; trigger = ck.clock; }
          }
        }
        if (te !== null) {
          // The last edge (above).
        } else if (since !== null && since !== undefined && !xFromStart) {
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
      const mode = options.xprop === 'on' ? 'xprop' : 'optimistic';
      let ctx = await runProc(m, p, sample, extra, mode);
      let pick = pickWrite(ctx, targetPath, s, now);
      let consistent = pick ? consistentWith(pick, now, sig) : undefined;
      // A comb procedure's value in effect was made by its run when the value last changed; a later
      // run that took other branches can give the same value by another statement (the default,
      // once an override's condition fell). The statement that made it, when that run explains the
      // value. (An x value is left to the run at t: x again is no change, and its cause is now's.)
      if (!edge && pick && consistent === true && ctx.decisions.length && !hasX(now) && since !== null && since !== undefined && since < t) {
        const at = await runProc(m, p, since, extra, mode);
        const ap = pickWrite(at, targetPath, s, now);
        if (ap && ap.stmt !== pick.stmt && consistentWith(ap, now, sig) === true) { ctx = at; pick = ap; sample = since; r.sample = since; }
      }
      // X-propagation: an x condition on the path and a dump that disagrees: try merged branches.
      if (options.xprop === 'auto' && consistent === false && (ctx.decisions.some((d) => d.xCond) || ctx.sawXIndex)) {
        const merged = await runProc(m, p, sample, extra, 'xprop');
        const mp = pickWrite(merged, targetPath, s, now);
        if (mp && consistentWith(mp, now, sig) === true) {
          ctx = merged; pick = mp; consistent = true;
          r.reasons.push({ code: 'xprop' });
        }
      }
      // A same-time race: inputs changed at the edge itself; the post-edge values may explain it.
      if (edge && consistent === false && r.activation) {
        const late = await runProc(m, p, r.activation.time, extra, ctx.mode);
        const lp = pickWrite(late, targetPath, s, now);
        if (lp && consistentWith(lp, now, sig) === true) { r.reasons.push({ code: 'race', time: r.activation.time }); ctx = late; pick = lp; consistent = true; }
      }
      // A comb procedure that didn't write the target on its path holds it (a latch): the
      // activation is when it last changed.
      if (!pick && !edge && since !== null && since !== undefined && since !== t) {
        const held = await runProc(m, p, since, extra, ctx.mode);
        const hp = pickWrite(held, targetPath, s, now);
        if (hp) { r.reasons.push({ code: 'held', time: since }); ctx = held; pick = hp; consistent = consistentWith(hp, now, sig); r.sample = since; }
      }
      ctx.reasons.forEach((x) => r.reasons.push(x));
      r.decisions = decisionsOut(m, pick ? pick.decisions : ctx.decisions);
      r.fanin = [];
      if (r.activation && r.activation.trigger) {
        const tp = r.activation.trigger.path;
        r.fanin.push({ role: 'clock', path: tp, name: relOf(m, tp), value: shown(extra.get(tp)), time: r.activation.time, dumped: extra.get(tp) !== undefined });
      }
      // The conditions on the way to the write (or to nowhere: everything decided), and those of a
      // later if or case that could have written the signal again but didn't (y = 'bx, then a
      // case (1'b1) whose items all failed: the items are why y stayed x). A case's items count up
      // to the one taken (all of them when none was).
      const before = pick ? pick.decisions : ctx.decisions;
      const sgw = signalOf(m, name);
      const wname = sgw && sgw.element ? sgw.element.array : name;
      const sameRun = pick && before.every((d, i) => ctx.decisions[i] === d);
      const after = sameRun ? ctx.decisions.slice(before.length).filter((dd) => (dd.kind === 'if' || dd.kind === 'case') && stmtWrites(dd.stmt, wname)) : [];
      const condCtx = { m, vals: ctx.vals, locals: new Map(), blocking: new Map() };
      for (const dd of before.concat(after)) {
        if (dd.kind !== 'if' && dd.kind !== 'case') { continue; }
        const e = dd.kind === 'if' ? dd.stmt.c : dd.stmt.e;
        faninOf(m, e, readsOf(e, condCtx), r.sample, 'control', r.fanin);
        if (dd.kind === 'case') {
          const upto = typeof dd.taken === 'number' ? dd.taken + 1 : dd.stmt.items.length;
          dd.stmt.items.slice(0, upto).forEach((it) => (it.m || []).forEach((x) => faninOf(m, x, readsOf(x, condCtx), r.sample, 'control', r.fanin)));
        }
      }
      if (!pick) {
        // Written by a statement that isn't re-executed: that statement, its value unpredicted.
        const sg = signalOf(m, name);
        const base = sg && sg.element ? sg.element.array : name;
        const ow = ctx.opaque.find((o) => o.name === base || o.name === name);
        if (ow) {
          r.stmt = { src: ow.stmt.src, loc: locOf(m, ow.stmt.loc) };
          if (!r.reasons.some((x) => x.code === 'statement' || x.code === 'lvalue')) { r.reasons.push({ code: 'statement', why: ow.stmt.why, src: ow.stmt.src }); }
          notDumped(r, ctx);
          return r;
        }
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
        if (r.fanin.limited) { r.reasons.push({ code: 'limits', why: 'temps' }); }
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
    // The write that made the value in effect: the last one, unless the value has x bits that a
    // later partial write covered (s <= s0; s.chk <= f(s0.pkt) with s0.pkt x): then the write
    // that made the most of the x bits (the later one on a tie), with the later writes it was
    // overlaid by (`after`).
    function pickWrite(ctx, targetPath, s, now) {
      const recs = ctx.writes.get(targetPath);
      if (!recs || !recs.length) { return null; }
      const last = recs[recs.length - 1];
      if (!now || recs.length < 2 || !hasX(now)) { return last; }
      const bits = shown(now), w = bits.length;
      const isX = (k) => k >= 0 && k < w && /[xz]/.test(bits[w - 1 - k]);
      const covered = new Set();
      let best = -1, most = 0;
      for (let i = recs.length - 1; i >= 0; i--) {
        const r = recs[i], lo = r.lsb || 0, hi = Math.min(w, lo + (r.width || w));
        let n = 0;
        for (let k = lo; k < hi; k++) { if (!covered.has(k)) { if (isX(k)) { n++; } covered.add(k); } }
        if (n > most) { most = n; best = i; }
      }
      return best < 0 || best === recs.length - 1 ? last : Object.assign({}, recs[best], { after: recs.slice(best + 1) });
    }

    // ---- loads (load trace: who reads a signal) ----
    // Whether expression e (in m) reads the signal at `sig`: 'yes', 'maybe' (it reads the array
    // `sig` is an element of, at an index the model doesn't fix), or ''. An element select of an
    // unpacked array (`elems`: mem[i]) reads the array: 'yes' for the array, 'maybe' for an element.
    function readsSig(m, e, sig) {
      if (!e) { return ''; }
      let found = '';
      for (const l of e.leaves || []) {
        if (isLocal(l)) { continue; }
        const p = absOf(m.path, l);
        if (p === sig) { return 'yes'; }
        if (sig.startsWith(p + '[')) { found = 'maybe'; }
      }
      for (const el of e.elems || []) {
        if (el.array && !isLocal(el.array)) {
          const a = absOf(m.path, el.array);
          if (a === sig) { return 'yes'; }
          if (sig.startsWith(a + '[')) { found = 'maybe'; }
        }
        const r = readsSig(m, el.index, sig);
        if (r === 'yes') { return r; }
        if (r) { found = r; }
      }
      return found;
    }
    // The signals an lvalue writes (block locals as `$local:` names), and whether its index reads sig.
    function lvalNames(m, lhs, out) {
      if (!lhs) { return out; }
      if (lhs.concat) { lhs.concat.forEach((x) => lvalNames(m, x, out)); return out; }
      if (lhs.name) { out.push(isLocal(lhs.name) ? lhs.name : absOf(m.path, lhs.name)); }
      return out;
    }
    function lvalIndexReads(m, lhs, sig) {
      if (!lhs) { return ''; }
      if (lhs.concat) { return lhs.concat.map((x) => lvalIndexReads(m, x, sig)).find(Boolean) || ''; }
      return readsSig(m, lhs.elem, sig) || readsSig(m, lhs.off, sig);
    }
    // Everything a statement may write (its targets when a condition or an event reads the signal).
    function writtenBy(m, st, out) {
      if (!st) { return out; }
      if (Array.isArray(st.writes)) { st.writes.forEach((w) => { if (w && w.name) { out.add(isLocal(w.name) ? w.name : absOf(m.path, w.name)); } }); }
      switch (st.k) {
        case 'seq': st.s.forEach((x) => writtenBy(m, x, out)); break;
        case 'asgn': lvalNames(m, st.lhs, []).forEach((n) => out.add(n)); break;
        case 'timed': writtenBy(m, st.stmt, out); break;
        case 'if': writtenBy(m, st.t, out); writtenBy(m, st.f, out); break;
        case 'case': st.items.forEach((it) => writtenBy(m, it.s, out)); writtenBy(m, st.dflt, out); break;
        default:
      }
      return out;
    }
    const exprText = (e) => (e ? (e.src || leafText(e)) : '');
    // Whether source text (comments and strings dropped) names sig as an identifier of instance m
    // (sig is one of m's own signals: m.path + '.' + a plain name), other than as an assignment's
    // target (`sig[..] <=` / `sig =`; an index inside the target still counts).
    function namedIn(m, text, sig) {
      if (!text || !sig.startsWith(m.path + '.')) { return false; }
      const name = sig.slice(m.path.length + 1);
      if (!/^[A-Za-z_][A-Za-z0-9_$]*$/.test(name)) { return false; }
      const code = String(text).replace(/\/\/[^\n]*/g, ' ').replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/"(?:[^"\\]|\\.)*"/g, '""');
      const id = name.replace(/\$/g, '\\$');
      // An assignment's target: `x =` anywhere (not ==), `x <=` only where a statement starts (else it
      // is a comparison, a read: if (x <= 3)).
      const sel = '((\\s*\\[[^\\]]*\\])*)';
      const target = new RegExp('(^|[^A-Za-z0-9_$.\'])' + id + sel + '\\s*=(?!=)', 'g');
      const nonblocking = new RegExp('(^|[;):]|\\bbegin|\\belse|#\\s*[0-9][A-Za-z0-9_.\']*)(\\s*)' + id + sel + '\\s*<=(?!=)', 'g');
      const reads = code.replace(nonblocking, (all, pre, space, sel) => pre + space + ' ' + (sel || '')).replace(target, (all, pre, sel) => pre + ' ' + (sel || ''));
      return new RegExp('(^|[^A-Za-z0-9_$.\'])' + id + '(?![A-Za-z0-9_$])').test(reads);
    }
    const EDGE_WORD = { PosEdge: 'posedge ', NegEdge: 'negedge ', BothEdges: 'edge ' };
    // The readers of `sig` inside instance m: assigns, declaration initializers, statements (data,
    // condition, index), procedures' sensitivity, and the child input ports it connects. `opaque`
    // counts the statements slang could not elaborate (their reads unknown).
    // Each entry's place in the model, for loadsAt: { m, p (procedure), st (statement), e (the
    // expression read), a (assign) }.
    const loadRefs = new WeakMap();
    function loadsIn(m, sig, out, limits) {
      const entry = (o, l) => Object.assign({ instance: m.path, loc: locOf(m, l) }, o);
      let ref = {};
      const push = (o, l, how) => { const e = entry(o, l); if (how === 'maybe') { e.maybe = true; } loadRefs.set(e, Object.assign({ m }, ref)); out.push(e); };
      for (const a of m.assigns) {
        ref = { a, e: a.rhs };
        const r = readsSig(m, a.rhs, sig);
        if (r) { push({ kind: 'assign', role: 'data', src: a.src, targets: lvalNames(m, a.lhs, []) }, a.loc, r); }
        const ir = lvalIndexReads(m, a.lhs, sig);
        ref = { a, e: null };
        if (ir) { push({ kind: 'assign', role: 'index', src: a.src, targets: lvalNames(m, a.lhs, []) }, a.loc, ir); }
      }
      for (const [name, info] of Object.entries(m.signals)) {
        const r = info.init ? readsSig(m, info.init, sig) : '';
        ref = { init: name, e: info.init };
        if (r) { push({ kind: info.kind === 'net' ? 'assign' : 'initializer', role: 'data', src: `${name} = ${exprText(info.init)}`, targets: [absOf(m.path, name)] }, info.init.loc || info.loc, r); }
      }
      for (const p of m.procs) {
        const proc = { procKind: p.kind, procLoc: locOf(m, p.loc) };
        for (const ev of p.events || []) {
          ref = { p, ev, e: ev.expr };
          const r = ev.expr ? readsSig(m, ev.expr, sig) : '';
          if (r) { push(Object.assign({ kind: 'event', role: 'sensitivity', src: (EDGE_WORD[ev.edge] || '') + exprText(ev.expr), targets: [...writtenBy(m, p.body, new Set())] }, proc), p.loc, r); }
        }
        const visit = (st) => {
          if (!st) { return; }
          switch (st.k) {
            case 'seq': st.s.forEach(visit); return;
            case 'timed': visit(st.stmt); return;
            case 'decl': {
              ref = { p, st, e: st.init };
              const r = readsSig(m, st.init, sig);
              if (r) { push(Object.assign({ kind: 'stmt', role: 'data', src: `${st.name.replace(/^\$local:/, '')} = ${exprText(st.init)}`, targets: [st.name] }, proc), st.loc, r); }
              return;
            }
            case 'asgn': {
              ref = { p, st, e: st.rhs };
              const r = readsSig(m, st.rhs, sig);
              if (r) { push(Object.assign({ kind: 'stmt', role: 'data', src: st.src, targets: lvalNames(m, st.lhs, []) }, proc), st.loc, r); }
              const ir = lvalIndexReads(m, st.lhs, sig);
              if (ir) { push(Object.assign({ kind: 'stmt', role: 'index', src: st.src, targets: lvalNames(m, st.lhs, []) }, proc), st.loc, ir); }
              return;
            }
            case 'if': {
              ref = { p, st, e: st.c };
              const r = readsSig(m, st.c, sig);
              if (r) {
                const t = new Set(); writtenBy(m, st.t, t); writtenBy(m, st.f, t);
                push(Object.assign({ kind: 'stmt', role: 'condition', src: `if (${exprText(st.c)})`, targets: [...t] }, proc), st.c.loc, r);
              }
              visit(st.t); visit(st.f);
              return;
            }
            case 'case': {
              const t = writtenBy(m, st, new Set());
              const conds = [st.e].concat(...st.items.map((it) => it.m));
              for (const e of conds) {
                ref = { p, st, e };
                const r = readsSig(m, e, sig);
                if (r) { push(Object.assign({ kind: 'stmt', role: 'condition', src: e === st.e ? `case (${exprText(e)})` : exprText(e), targets: [...t] }, proc), e.loc, r); }
              }
              st.items.forEach((it) => visit(it.s)); visit(st.dflt);
              return;
            }
            case 'opaque': {
              // slang left it unelaborated (a loop, a call...): its reads are unknown. Named in its
              // text, the signal may be read there: listed as maybe (role 'opaque').
              limits.opaque++;
              ref = { p, st, e: null };
              // (slang's text can carry the trivia before it, on one line: a one-line statement's
              // text is its last endCol - startCol characters)
              let text = String(st.src || '');
              const one = Array.isArray(st.loc) && st.loc[1] === st.loc[3] && st.loc[4] > st.loc[2];
              if (one && !text.includes('\n') && text.length > st.loc[4] - st.loc[2]) { text = text.slice(-(st.loc[4] - st.loc[2])); }
              if (namedIn(m, text, sig)) {
                const t = new Set(); writtenBy(m, st, t);
                // (a text starting with comment lines: the place is its first code line)
                const trivia = (text.match(/^(?:\s|\/\/[^\n]*\n|\/\*[\s\S]*?\*\/)*/) || [''])[0];
                const lead = trivia.split('\n').length - 1;
                const src = text.slice(trivia.length);
                const l = lead && Array.isArray(st.loc) ? [st.loc[0], st.loc[1] + lead, 1].concat(st.loc.slice(3)) : st.loc;
                push(Object.assign({ kind: 'stmt', role: 'opaque', src, targets: [...t] }, proc), l, 'maybe');
              }
              return;
            }
            default:
          }
        };
        visit(p.body);
      }
      for (const child of m.children) {
        for (const port of child.ports) {
          if (port.dir !== 'In' && port.dir !== 'InOut') { continue; }
          const r = readsSig(m, port.conn, sig);
          ref = { child, port, e: port.conn };
          if (r) { push({ kind: 'portIn', role: 'connection', src: `.${port.name}(${connText(port.conn) || port.name})`, port: port.name, targets: [child.path + '.' + port.internal] }, port.loc, r); }
        }
      }
    }
    const locKey = (e) => [e.instance, e.loc ? e.loc.file || '' : '', e.loc ? e.loc.line : 0, e.loc ? e.loc.col : 0];
    function byPlace(x, y) {
      const a = locKey(x), b = locKey(y);
      for (let i = 0; i < a.length; i++) { if (a[i] < b[i]) { return -1; } if (a[i] > b[i]) { return 1; } }
      return 0;
    }
    // Load trace: the static readers of the signal at `path` (design path), in instance path then
    // source order, one page at a time ({ offset, limit }, limit at most 512, 64 by default).
    // { signal, total, entries, next (the next page's offset, or null), limits }. An entry: { kind
    // ('assign' | 'initializer' | 'stmt' | 'event' | 'portIn' | 'portOut' | 'modport'), role ('data' |
    // 'condition' | 'index' | 'sensitivity' | 'connection' | 'opaque'), instance, src, loc, targets
    // (the paths it writes: the next hop; block locals as `$local:` names), procKind?, procLoc?,
    // port?, maybe? (it reads the whole array the signal is an element of, or names it in a
    // statement slang could not elaborate), via? ('interface': a read through an interface port) }.
    // Not seen: reads from other instances through hierarchical references (limits.hierarchical;
    // an interface's are walked: limits.interfaceWalk), and what statements slang could not
    // elaborate read without naming the signal (limits.opaque counts them).
    async function loads(path, opts) {
      const all = await collectLoads(path);
      if (all.error) { return all; }
      const { entries, total, next } = pageOf(all.entries, opts);
      return { signal: path, total, instances: all.instances, entries, next, limits: all.limits };
    }
    function pageOf(list, opts) {
      const o = opts || {};
      const limit = Math.max(1, Math.min(512, Number(o.limit) || 64));
      const offset = Math.max(0, Number(o.offset) || 0);
      return { total: list.length, entries: list.slice(offset, offset + limit), next: offset + limit < list.length ? offset + limit : null };
    }
    // An interface's signal: each modport taking it as an input (kind 'modport', a connection),
    // and its reads (`via: 'interface'`) in the interface's parent and in the instances its interface
    // ports are bound to (the model's `connections`, at any depth: its real fanout), up to
    // INTERFACE_WALK instances (limits.interfaceWalk: { instances, of, capped }). A model without
    // `connections` (an older sidecar): the parent and every instance under it, breadth first.
    const INTERFACE_WALK = 512;
    async function interfaceLoads(m, path, base, out, limits) {
      for (const mp of m.modports || []) {
        for (const pt of mp.ports || []) {
          if ((pt.internal || pt.name) !== base || !['In', 'InOut', 'Ref'].includes(pt.dir)) { continue; }
          const e = { kind: 'modport', role: 'connection', instance: m.path, src: `modport ${mp.name} (${pt.dir === 'In' ? 'input' : pt.dir === 'Ref' ? 'ref' : 'inout'} ${pt.name})`,
            port: mp.name + '.' + pt.name, loc: locOf(m, pt.loc || mp.loc), targets: [m.path + '.' + mp.name + '.' + pt.name] };
          loadRefs.set(e, { m, modport: mp });
          out.push(e);
        }
      }
      if (!m.parent) { return; }
      // (the parent too: it can read the interface instance's members itself)
      const visit = (x) => {
        const found = [];
        loadsIn(x, path, found, limits);
        found.forEach((e) => { e.via = 'interface'; out.push(e); });
      };
      if (Array.isArray(m.connections)) {
        const paths = [...new Set([m.parent].concat(m.connections.map((c) => c.instance)))].filter((p) => p && p !== m.path);
        let walked = 0;
        for (const p of paths) {
          if (walked >= INTERFACE_WALK) { limits.interfaceWalk = { instances: walked, of: paths.length, capped: true }; return; }
          const x = await model(p);
          if (!x) { continue; }
          walked++;
          visit(x);
        }
        limits.interfaceWalk = { instances: walked, of: paths.length, capped: false };
        return;
      }
      const pm = await model(m.parent);
      const todo = pm ? [pm] : [];
      let seen = 0;
      while (todo.length) {
        const x = todo.shift();
        if (++seen > INTERFACE_WALK) { limits.interfaceWalk = { instances: INTERFACE_WALK, capped: true }; return; }
        visit(x);
        for (const c of x.children || []) {
          if (c.path === m.path) { continue; }
          const cm = await model(c.path);
          if (cm) { todo.push(cm); }
        }
      }
      limits.interfaceWalk = { instances: seen, capped: false };
    }
    async function collectLoads(path) {
      const where = await models.lookup(path);
      if (!where || !where.instance) { return { signal: path, error: 'notInDesign' }; }
      const m = await model(where.instance);
      if (!m) { return { signal: path, error: 'notInDesign' }; }
      const name = where.name;
      const out = [];
      const limits = { opaque: 0, hierarchical: true };
      loadsIn(m, path, out, limits);
      // An output port: the parent's signals connected to it (where its value goes next).
      const s = signalOf(m, name);
      const base = s && s.element ? s.element.array : name;
      if (m.parent) {
        const outs = m.ports.filter((pt) => (pt.dir === 'Out' || pt.dir === 'InOut') && pt.internal === base);
        if (outs.length) {
          const pm = await model(m.parent);
          const me = pm && pm.children.find((c) => c.path === m.path);
          for (const pt of outs) {
            const cp = me && me.ports.find((q) => q.name === pt.name);
            if (!cp) { continue; }
            const targets = cp.connLval ? lvalNames(pm, cp.connLval, []) : [...leafPaths(pm, cp.conn, new Set())];
            const pe = { kind: 'portOut', role: 'connection', instance: pm.path, src: `.${cp.name}(${connText(cp.conn) || cp.name})`, port: cp.name, loc: locOf(pm, cp.loc), targets, maybe: s && s.element ? true : undefined };
            loadRefs.set(pe, { m: pm, out: true });
            out.push(pe);
          }
        }
      }
      if (m.interface) { await interfaceLoads(m, path, base, out, limits); }
      out.sort(byPlace);
      return { entries: out, limits, instances: new Set(out.map((e) => e.instance)).size };
    }

    // Load trace at a time: loads' page, each entry with `active`, judged at the reader's last
    // activation at or before t (the dump is searched backward, as driver tracing does): { status,
    // time (the activation), trust, reasons, taken? (a condition's branch), follow? ({ path, time }:
    // the change the read caused, where following the entry goes) }. Status: 'propagated' (the
    // target changed with this read), 'noChange', 'notRun' (the statement was not on the path),
    // 'read' (into a block local or an index: nothing dumped to follow), 'taken' / 'untaken' (a
    // condition), 'triggered' / 'notTriggered' (a sensitivity), 'pending' (an edge procedure whose
    // last edge came before the signal's change: it is sampled at a later one), 'stimulus' (a
    // testbench process), 'start' (an initializer), 'notEvaluated' (budget, or a construct not
    // re-executed). opts: as loads, plus budgetMs (per entry, 2000).
    async function loadsAt(path, time, opts) {
      const all = await collectLoads(path);
      if (all.error) { return all; }
      const t = Number(time);
      const page = pageOf(all.entries, opts);
      const since = await dump.lastChange(path, t);
      const budget = Math.max(1, Number((opts || {}).budgetMs) || 2000);
      const entries = [];
      for (const e of page.entries) {
        const out = Object.assign({}, e);
        // The budget needs a timer (a page has one; a bare JS context may not: no budget there).
        let h = null;
        const timer = typeof setTimeout === 'function'
          ? new Promise((resolve) => { h = setTimeout(() => resolve({ status: 'notEvaluated', reasons: [{ code: 'budget' }] }), budget); })
          : null;
        try {
          out.active = await (timer ? Promise.race([activeLoad(e, path, t, since), timer]) : activeLoad(e, path, t, since));
          if (h !== null && typeof clearTimeout === 'function') { clearTimeout(h); }
        } catch (error) {
          out.active = { status: 'notEvaluated', reasons: [{ code: 'error', message: String(error && error.message || error) }] };
        }
        if (!out.active.trust) { out.active.trust = out.active.status === 'notEvaluated' ? 'approximate' : 'exact'; }
        if (e.maybe && out.active.trust === 'exact') { out.active.trust = 'approximate'; out.active.reasons = (out.active.reasons || []).concat([{ code: 'maybe' }]); }
        entries.push(out);
      }
      return { signal: path, time: t, since, total: page.total, instances: all.instances, entries, next: page.next, limits: all.limits };
    }
    // Whether target changed at exactly `at` (with the read), and the follow for it.
    async function changedAt(target, at) {
      if (!target || isLocal(target)) { return null; }
      const tc = await dump.lastChange(target, at);
      return tc === at ? { path: target, time: at } : false;
    }
    async function activeLoad(e, sigPath, t, since) {
      const ref = loadRefs.get(e) || {};
      const m = ref.m;
      const reasons = [];
      const target = (e.targets || [])[0];
      // Continuous: assigns, net declarations, port connections. The target changes with the signal.
      if (e.kind === 'assign' || e.kind === 'portIn' || e.kind === 'portOut') {
        if (since === null || since === undefined) { return { status: 'notEvaluated', reasons: [{ code: 'notDumped' }] }; }
        if (e.role === 'index') { return { status: 'read', time: since, reasons }; }
        const f = await changedAt(target, since);
        if (f === null) { return { status: 'read', time: since, reasons }; }
        return f ? { status: 'propagated', time: since, follow: f, reasons } : { status: 'noChange', time: since, reasons };
      }
      if (e.kind === 'modport') {
        if (since === null || since === undefined) { return { status: 'notEvaluated', reasons: [{ code: 'notDumped' }] }; }
        return { status: 'read', time: since, reasons };
      }
      if (e.kind === 'initializer') { return { status: 'start', time: 0, reasons }; }
      const p = ref.p;
      if (!p) { return { status: 'notEvaluated', reasons: [{ code: 'unknown' }] }; }
      if (isStimulus(p)) { return { status: 'stimulus', reasons }; }
      if (e.role === 'opaque') { return { status: 'notEvaluated', reasons: [{ code: 'opaque', what: e.src }], trust: 'approximate' }; }
      const edge = isEdgeProc(p);
      if (e.kind === 'event') {
        if (!edge || !ref.ev || !ref.ev.edge) { return { status: 'notEvaluated', reasons: [{ code: 'evaluator' }] }; }
        const te = await dump.prevEdge(sigPath, t, ref.ev.edge);
        return te !== null && te === since ? { status: 'triggered', time: te, reasons } : { status: 'notTriggered', time: te, reasons };
      }
      // A statement in a procedure: the run that sampled the signal's value in effect.
      let sample = t, extra = new Map(), at = t;
      if (edge) {
        const ck = clocking(m, p);
        if (!ck.clock) { return { status: 'notEvaluated', reasons: [{ code: 'noClock' }] }; }
        const te = await dump.prevEdge(ck.clock.path, t, ck.clock.edge);
        if (te === null) { return { status: 'pending', reasons: [{ code: 'noEdge' }] }; }
        sample = te > 0 ? te - 1 : 0;
        at = te;
        if (since !== null && since !== undefined && since > sample) { return { status: 'pending', time: te, reasons }; }
        const tv = await fetch([ck.clock.path], te);
        extra.set(ck.clock.path, tv.get(ck.clock.path));
      } else if (since !== null && since !== undefined) {
        at = since;
      }
      const ctx = await runProc(m, p, sample, extra, options.xprop === 'on' ? 'xprop' : 'optimistic');
      ctx.reasons.forEach((x) => reasons.push(x));
      const approx = reasons.some((r) => ['budget', 'statement', 'delay', 'opaque'].includes(r.code));
      const trust = approx ? 'approximate' : undefined;
      const st = ref.st;
      if (!ctx.ran.has(st)) { return { status: 'notRun', time: at, reasons, trust }; }
      if (e.role === 'condition') {
        const d = ctx.decisions.find((x) => x.stmt === st);
        if (!d) { return { status: 'notEvaluated', time: at, reasons, trust: 'approximate' }; }
        const out = { time: at, reasons, trust, taken: d.taken };
        if (st.k === 'if') { out.status = d.taken === 'then' ? 'taken' : d.taken === 'else' ? 'untaken' : 'merged'; }
        else {
          // A case item reading the signal: taken when its item matched; the selector: taken.
          const item = st.items.findIndex((it) => it.m.includes(ref.e));
          out.status = item < 0 ? 'taken' : d.taken === item ? 'taken' : d.taken === 'merge' ? 'merged' : 'untaken';
        }
        if (out.status === 'merged') { out.trust = 'approximate'; }
        return out;
      }
      if (e.role === 'index') { return { status: 'read', time: at, reasons, trust }; }
      const f = await changedAt(target, at);
      if (f === null) { return { status: 'read', time: at, reasons, trust }; }
      if (!f) { return { status: 'noChange', time: at, reasons, trust }; }
      // The run's write explains the target's new value: exact.
      const w = await models.lookup(target);
      const tm = w && w.instance === m.path ? m : null;
      const tsig = tm ? signalOf(tm, w.name) : null;
      let consistent;
      if (tsig) {
        const now = (await fetch([target], at)).get(target);
        const pick = pickWrite(ctx, target, tsig, now);
        consistent = pick ? consistentWith(pick, now, tsig) : undefined;
      }
      return { status: 'propagated', time: at, follow: f, reasons, trust: consistent === false ? 'inconsistent' : consistent === true && !approx ? 'exact' : 'approximate' };
    }

    // Follow forward: where a load entry's target goes next, its first change at or after t
    // ({ path, time | null, direction: 'forward' }), when the dump can search forward; null when it
    // can't or the entry has no dumped target (the caller keeps the entry's backward follow).
    async function nextOf(e, t) {
      if (!e || e.kind === 'modport' || typeof dump.nextChange !== 'function') { return null; }
      const target = (e.targets || []).find((x) => x && !isLocal(x));
      if (!target) { return null; }
      const at = await dump.nextChange(target, t);
      return { path: target, time: at === null || at === undefined ? null : Number(at), direction: 'forward' };
    }
    return { active, model, loads, loadsAt, nextOf, driversOf: async (path) => { const w = await models.lookup(path); const m = await model(w.instance); return driversOf(m, w.name).map((d) => driverSummary(m, d)); } };
  }

  // ---- Trace X to Root ----
  // From a value with x or z bits, the fan-in that brought the x, step by step, to where it was
  // made. Each step follows the fan-in with x or z (data, condition or index; never the clock, a
  // blocking temporary (the engine's fan-in has already gone through it to what it read) or an
  // undumped signal) whose own x arrived earliest (the smallest `since`). It stops at:
  //   noXInput   no input has x: the statement makes it ('bx, a default, an x index...)
  //   uninit     never written since the start, or nothing but a declaration drives it
  //   testbench  the testbench's stimulus sets it          input   a top-level input
  //   force      a force or deposit from outside the instance
  //   loop       the x would go round to a signal already in the chain
  //   budget     maxSteps steps (no root)                  failed  a step could not be traced
  //   cancelled  cancelled() said so (no root)             noX     the start has no x or z
  //
  //   xChain({ path, time }, { step(path, time) -> Promise<step>, probe?(path, time) -> Promise<step>,
  //            onStep?(entry, index), cancelled?() -> bool, maxSteps?, maxProbes? })
  //     -> { steps: [{ step, signal, time, value, since, trust, why }], end: { code, signal? },
  //          root (index, -1 without one), approximate }
  // `step` traces a step of the chain (the page confirms it with Verdi), `probe` a candidate
  // (default: step). `why` says why a step follows the one before: start, only (the only input
  // with x) or earliest (of `count` inputs with x); `limited` when more than maxProbes had x.
  const X_CHAIN_STEPS = 30;
  const X_CHAIN_PROBES = 16;
  const xBits = (v) => v !== null && v !== undefined && /[xz]/i.test(String(v));
  function xStop(st) {
    const reasons = st.reasons || [];
    const kind = st.driver ? st.driver.kind : 'none';
    if (reasons.some((r) => r.code === 'force')) { return 'force'; }
    if (st.root === 'testbench') { return 'testbench'; }
    if (kind === 'topInput') { return 'input'; }
    if (kind === 'none' || kind === 'undriven' || kind === 'initializer') { return 'uninit'; }
    if (Number(st.since) === 0 && reasons.some((r) => r.code === 'noWrite' || r.code === 'initialValue')) { return 'uninit'; }
    return null;
  }
  async function xChain(start, config) {
    const c = config || {};
    const step = c.step, probe = c.probe || c.step;
    const cancelled = c.cancelled || (() => false);
    const maxSteps = Number(c.maxSteps) >= 1 ? Math.floor(Number(c.maxSteps)) : X_CHAIN_STEPS;
    const maxProbes = Number(c.maxProbes) >= 1 ? Math.floor(Number(c.maxProbes)) : X_CHAIN_PROBES;
    const out = { steps: [], end: null, root: -1, approximate: false };
    const finish = (code, extra) => {
      out.end = Object.assign({ code }, extra || {});
      if (!['budget', 'failed', 'cancelled', 'noX'].includes(code) && out.steps.length) { out.root = out.steps.length - 1; }
      out.approximate = out.steps.some((e) => e.trust === 'approximate' || e.trust === 'inconsistent');
      return out;
    };
    const add = (st, why) => {
      const e = { step: st, signal: st.signal, time: st.time, value: st.value, since: st.since, trust: st.trust, why };
      out.steps.push(e);
      if (c.onStep) { c.onStep(e, out.steps.length - 1); }
    };
    let cur;
    try { cur = await step(start.path, start.time); } catch (error) { cur = null; }
    if (cancelled()) { return finish('cancelled'); }
    if (!cur || cur.error) { if (cur) { add(cur, { code: 'start' }); } return finish('failed'); }
    add(cur, { code: 'start' });
    if (!xBits(cur.value)) { return finish('noX'); }
    const seen = new Set([cur.signal]);
    for (;;) {
      const stop = xStop(cur);
      if (stop) { return finish(stop); }
      if (out.steps.length >= maxSteps) { return finish('budget'); }
      const cands = (cur.fanin || []).filter((f) => typeof f.path === 'string' && f.path && f.role !== 'clock' && f.dumped !== false && !f.blocking && !f.local && xBits(f.value));
      if (!cands.length) { return finish('noXInput'); }
      const probed = [];
      for (const f of cands.slice(0, maxProbes)) {
        let st;
        try { st = await probe(f.path, f.time); } catch (error) { st = null; }
        if (cancelled()) { return finish('cancelled'); }
        if (!st || st.error) { continue; }
        const since = st.since === null || st.since === undefined ? Infinity : Number(st.since);
        probed.push({ f, st, since });
      }
      // Earliest x first; on a tie a signal not yet on the chain first, then the fan-in's order (a stable sort).
      probed.sort((p, q) => (p.since - q.since) || (seen.has(p.f.path) - seen.has(q.f.path)));
      if (!probed.length) { return finish('failed'); }
      let best = null, next = null;
      for (const cand of probed) {
        if (seen.has(cand.f.path)) {
          // Back to a signal of the chain. x since the start all the way round (an unreset
          // cnt <= cnt + 1) is uninitialised storage; otherwise the x goes round a loop.
          const from = out.steps.findIndex((e) => e.signal === cand.f.path);
          if (from >= 0 && out.steps.slice(from).every((e) => Number(e.since) === 0)) { return finish('uninit', { signal: cand.f.path }); }
          return finish('loop', { signal: cand.f.path });
        }
        let st = cand.st;
        if (probe !== step) {
          try { st = await step(cand.f.path, cand.f.time); } catch (error) { st = null; }
          if (cancelled()) { return finish('cancelled'); }
          if (!st || st.error) { return finish('failed'); }
        }
        // The step can disagree with its probe (Verdi's answer, an edge off by one): a value with
        // no x is not where the x came from; try the next candidate.
        if (!xBits(st.value)) { continue; }
        best = cand;
        next = st;
        break;
      }
      if (!best) { return finish('failed'); }
      const why = cands.length === 1 ? { code: 'only', role: best.f.role } : { code: 'earliest', role: best.f.role, count: cands.length };
      if (cands.length > maxProbes) { why.limited = true; }
      seen.add(next.signal);
      add(next, why);
      cur = next;
    }
  }

  root.cmuxTrace = Object.freeze({ createEngine, xChain, MODEL_VERSION });
})(typeof window !== 'undefined' ? window : globalThis);
