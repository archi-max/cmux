/* SPDX-License-Identifier: MIT
 * simctl apply + settle (included by simctl_vpi.c). Calls a native routine that is ALREADY loaded in the
 * simulation (found with dlsym; nothing is ever loaded here), never from a read-only region:
 *   at serve: inside the testbench's $simctl_serve(st, rel) (simctl_hold.sv), in procedural context, at this
 *             time; from a ReadOnlySynch park with the TB held there, simctl first wakes the TB back into
 *             $simctl_serve one time unit later and calls it there
 *   at next:  from a cbAfterDelay(1) callback, one time unit later (a writable point)
 * rc 0 (applied) or 1 (no plan, unchanged): the reply waits for that time step's ReadOnlySynch, after the
 * native propagation the routine queued has run (settled:true). rc -1/-2: the reply comes at once
 * (settled:false). rc -2 discards the branch: run/until/apply/writes/loadmem are refused until a restore brings
 * back a state from before it, and reads carry tainted:true.
 *
 * A AID at sym arg lib versym want errsym     (arg: x + hex of the bytes; lib, versym, errsym: - for none)
 *   int sym(const char *arg); unsigned versym(void) must == want; const char *errsym(void) for lastError */
#include <dlfcn.h>

static vpiHandle hold_st, hold_rel;   /* the arguments of the TB's latest $simctl_serve(st, rel) */
static vpiHandle hold_pulse;          /* simctl_hold's pulse, if there: HDL activity while a park waits for its stop */
static int held;                      /* the TB waits in simctl_hold.point() for rel */
static int serving_hold;              /* inside a $simctl_serve(st, rel): the TB is held there too */
static int discarded;                 /* an apply returned -2 in this branch */
static long long released_at = -1;    /* the time a run released the held TB (in the run's reply) */
static struct { int armed, serve; long id; int (*fn)(const char *); const char *(*ef)(void); char *arg; } ap;
static long settle_id = -1; static int settle_rc; static uint64_t settle_t; static char *settle_err;

static void hold_put(vpiHandle h, int v, int scalar) {
  s_vpi_value val;
  if (scalar) { val.format = vpiScalarVal; val.value.scalar = v ? vpi1 : vpi0; }
  else { val.format = vpiIntVal; val.value.integer = v; }
  vpi_put_value(h, &val, NULL, vpiNoDelay);
}
/* wake the held TB: st first (what to do), then a change of rel ends its @(rel) */
static void hold_wake(int st) {
  hold_put(hold_st, st, 0);
  s_vpi_value cur; cur.format = vpiScalarVal; vpi_get_value(hold_rel, &cur);
  hold_put(hold_rel, cur.value.scalar != vpi1, 1);
  if (st == 0) held = 0;
}
static PLI_INT32 reenter_rtn(p_cb_data d) { (void)d; if (fs_child) return 0; hold_wake(2); return 0; }
static PLI_INT32 release_rtn(p_cb_data d) { (void)d; if (fs_child) return 0; hold_wake(0); return 0; }
/* one time unit later, at a writable point: wake the held TB into $simctl_serve (2) or release it (0) */
static void hold_later(int st) { vpiHandle h = after(1, st ? reenter_rtn : release_rtn); if (h) vpi_release_handle(h); }

static void reply_apply(long id, uint64_t t, int rc, const char *e, int settled) {
  bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"rc\":%d,\"lastError\":", id, (unsigned long long)t, rc);
  bjson(&ob, e ? e : "");
  bfmt(&ob, ",\"settled\":%s,\"held\":%s%s}", settled ? "true" : "false", held || serving_hold ? "true" : "false", discarded ? ",\"tainted\":true" : "");
  send_ob();
}
/* the call itself; 1: settled reply pending (at this time's ReadOnlySynch), 0: answered */
static int apply_call(void) {
  ap.armed = 0;
  if (in_ro) { reply_err(ap.id, "apply: internal: refused in a read-only region"); free(ap.arg); return 0; }
  int rc = ap.fn(ap.arg);
  const char *e = ap.ef ? ap.ef() : "";
  free(ap.arg); ap.arg = NULL;
  if (rc == -2) discarded = 1;
  if (rc == 0 || rc == 1) {
    free(settle_err); settle_err = strdup(e ? e : "");
    settle_id = ap.id; settle_rc = rc; settle_t = now();
    return 1;
  }
  reply_apply(ap.id, now(), rc, e, 0);
  return 0;
}
/* serve() calls this first: the settled reply of an apply made earlier in this time step */
static void settle_reply(void) {
  if (settle_id < 0) return;
  uint64_t t = now();
  if (t != settle_t) { char m[160]; snprintf(m, sizeof m, "apply: internal: settled at %llu, not at the call's time %llu", (unsigned long long)t, (unsigned long long)settle_t); reply_err(settle_id, m); }
  else reply_apply(settle_id, t, settle_rc, settle_err, 1);
  settle_id = -1;
}
static PLI_INT32 apply_rtn(p_cb_data d) { (void)d; if (fs_child) return 0;
  apply_call();
  snprintf(serve_reason, sizeof serve_reason, "apply"); need_serve = 1; sched_ro();
  return 0;
}
/* inside $simctl_serve with an apply at serve armed (by apply_req or after reentry): call it; 1: return to the
 * TB, held (the settle reply comes at this time's ReadOnlySynch), 0: go on serving */
static int apply_at_serve(void) {
  if (!apply_call()) return 0;
  hold_put(hold_st, 1, 0); held = 1;
  snprintf(serve_reason, sizeof serve_reason, "settle"); need_serve = 1; sched_ro();
  return 1;
}

static int unhex(const char *s, char **out) {
  if (s[0] != 'x') return -1;
  size_t n = strlen(s + 1);
  if (n % 2) return -1;
  char *o = malloc(n / 2 + 1);
  for (size_t i = 0; i < n / 2; i++) {
    unsigned v; if (sscanf(s + 1 + 2 * i, "%2x", &v) != 1) { free(o); return -1; }
    o[i] = (char)v;
  }
  o[n / 2] = 0; *out = o;
  return 0;
}
/* 1: the caller returns to the simulation; 0: answered here, keep serving */
static int apply_req(long id, char **tok, int nt, int ctx) {
  if (nt != 9) { reply_err(id, "apply: malformed request"); return 0; }
  if (discarded) { reply_err(id, "apply: this branch is discarded (an apply returned -2): restore a checkpoint from before it"); return 0; }
  if (ap.armed) { reply_err(id, "apply: another apply is pending"); return 0; }
  int serve = !strcmp(tok[2], "serve");
  if (!serve && strcmp(tok[2], "next")) { reply_err(id, "apply: at must be serve or next"); return 0; }
  void *lh = RTLD_DEFAULT;
  if (strcmp(tok[5], "-")) {
    lh = dlopen(tok[5], RTLD_NOW | RTLD_NOLOAD);
    if (!lh) { reply_err(id, "apply: lib is not loaded in the simulation (simctl never loads one)"); return 0; }
  }
  char m[400];
  int (*fn)(const char *) = (int (*)(const char *))dlsym(lh, tok[3]);
  if (!fn) { snprintf(m, sizeof m, "apply: no symbol %.200s in the simulation", tok[3]); reply_err(id, m); return 0; }
  if (strcmp(tok[6], "-")) {
    unsigned want = (unsigned)strtoul(tok[7], NULL, 10);
    unsigned (*vf)(void) = (unsigned (*)(void))dlsym(lh, tok[6]);
    if (!vf || vf() != want) {
      if (vf) bfmt(&ob, "{\"id\":%ld,\"error\":\"abi\",\"have\":%u,\"want\":%u,\"needsRebuild\":true,\"symbol\":", id, vf(), want);
      else bfmt(&ob, "{\"id\":%ld,\"error\":\"abi\",\"have\":null,\"want\":%u,\"needsRebuild\":true,\"symbol\":", id, want);
      bjson(&ob, tok[6]); bstr(&ob, "}"); send_ob();
      return 0;
    }
  }
  const char *(*ef)(void) = NULL;
  if (strcmp(tok[8], "-") && !(ef = (const char *(*)(void))dlsym(lh, tok[8]))) {
    snprintf(m, sizeof m, "apply: no symbol %.200s (lastErrorSymbol) in the simulation", tok[8]); reply_err(id, m); return 0;
  }
  char *arg;
  if (unhex(tok[4], &arg)) { reply_err(id, "apply: malformed arg"); return 0; }
  if (serve && hold_st && hold_nw) { free(arg); reply_err(id, "apply: " HOLD_NW_MSG); return 0; }
  if (ctx == CTX_SYSTF && !hold_st) { free(arg); reply_err(id, "apply: the testbench's $simctl_serve has no (st, rel) arguments, so it can't be held: call it through simctl_hold.sv"); return 0; }
  if (serve && ctx == CTX_RO && !held) {
    free(arg);
    reply_err(id, "apply: at:serve needs the testbench held at its serve point (simctl_hold.sv point()); this is a ReadOnlySynch park: use at:next");
    return 0;
  }
  ap.armed = 1; ap.serve = serve; ap.id = id; ap.fn = fn; ap.ef = ef; ap.arg = arg;
  if (serve && ctx == CTX_SYSTF) return apply_at_serve();
  if (serve) { hold_later(2); return 1; }            /* RO park, TB held: wake it into $simctl_serve at t+1 */
  /* next: from a callback one time unit later; the TB (if serving) stays held meanwhile */
  if (ctx == CTX_SYSTF && !hold_nw) { hold_put(hold_st, 1, 0); held = 1; }   /* an unwritable hold: the TB goes on, not held */
  vpiHandle h = after(1, apply_rtn); if (h) vpi_release_handle(h);
  return 1;
}
