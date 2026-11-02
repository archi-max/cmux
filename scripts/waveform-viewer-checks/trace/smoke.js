// The replay oracle on one real design (run.sh trace-smoke <model.json> <dump.vcd>): every change of
// every dumped design signal is traced at its change time and the steps are tallied by trust.
// A step is "unexplained" when it is inconsistent with only a plain mismatch to show for it.
// The run passes when nothing throws and no more than TRACE_SMOKE_MAX_UNEXPLAINED (default 0) steps
// are unexplained; it prints the first ones, and per-step timing.
/* global cmuxTrace, traceVcd, traceFiles */
/* exported runTraceChecks */
function runTraceChecks() {
  const out = [];
  const all = JSON.parse(Object.values(traceFiles.models)[0]);
  const vcd = traceVcd(Object.values(traceFiles.dumps)[0]);
  const models = {
    instance: async (p) => all.instances[p],
    lookup: async (p) => {
      let best = null;
      for (const k of Object.keys(all.instances)) { if ((p === k || p.startsWith(k + '.')) && (!best || k.length > best.length)) { best = k; } }
      return best ? { instance: best, name: p.slice(best.length + 1) } : null;
    },
  };
  const engine = cmuxTrace.createEngine({ models, dump: vcd.provider });
  const maxChanges = Number(globalThis.TRACE_SMOKE_MAX_CHANGES || 400);
  async function run() {
    const tally = { steps: 0, exact: 0, computed: 0, approximate: 0, inconsistent: 0, unexplained: 0, errors: 0 };
    const reasons = {};
    const kinds = {};
    let slowest = 0, total = 0;
    for (const [inst, m] of Object.entries(all.instances)) {
      for (const name of Object.keys(m.signals)) {
        const p = inst + '.' + name;
        const s = vcd.sig.get(p);
        if (!s) { continue; }
        for (const [t] of s.changes.slice(0, maxChanges)) {
          const t0 = Date.now();
          let step;
          try { step = await engine.active(p, t); } catch (error) { tally.errors++; if (tally.errors <= 5) { out.push(`FAIL ${p} @${t}: ${error && error.stack || error}`); } continue; }
          const ms = Date.now() - t0;
          total += ms; slowest = Math.max(slowest, ms);
          tally.steps++;
          tally[step.trust] = (tally[step.trust] || 0) + 1;
          const k = step.driver ? step.driver.kind : 'none';
          kinds[k] = (kinds[k] || 0) + 1;
          for (const r of step.reasons || []) { reasons[r.code] = (reasons[r.code] || 0) + 1; }
          if (step.trust === 'inconsistent' && (step.reasons || []).some((r) => r.code === 'mismatch')) {
            tally.unexplained++;
            if (tally.unexplained <= 12) { out.push(`UNEXPLAINED ${p} @${t}: predicted ${step.predicted}, dump ${step.value} (${step.stmt && step.stmt.src})`); }
          }
        }
      }
    }
    out.push(`smoke: ${tally.steps} steps, exact ${tally.exact}, computed ${tally.computed}, approximate ${tally.approximate}, inconsistent ${tally.inconsistent}, unexplained ${tally.unexplained}, errors ${tally.errors}`);
    out.push(`drivers: ${JSON.stringify(kinds)}`);
    out.push(`reasons: ${JSON.stringify(reasons)}`);
    out.push(`time: ${total} ms total, ${(total / Math.max(tally.steps, 1)).toFixed(2)} ms per step, slowest ${slowest} ms`);
    const allowed = Number(globalThis.TRACE_SMOKE_MAX_UNEXPLAINED || 0);
    if (tally.unexplained > allowed) { out.push(`FAIL ${tally.unexplained} unexplained steps (allowed ${allowed})`); }
    return out;
  }
  return run().then((lines) => { globalThis.__traceDone = { lines }; }, (error) => { globalThis.__traceDone = { lines: out.concat(['FAIL ' + (error && error.stack || error)]) }; });
}
