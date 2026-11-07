/* SPDX-License-Identifier: MIT
 * simctl VPI library: lets a controller drive a running simulation over two pipes.
 * Public IEEE 1364/1800 VPI only. Build against the simulator's own vpi_user.h (not shipped here).
 *
 * The controller (worker.js) passes two file descriptors in the environment:
 *   SIMCTL_IN_FD   commands, one per line:  <op> <id> args...
 *   SIMCTL_OUT_FD  replies: one JSON line each; a {"ev":"chg","n":N,"bin":B} line is followed by B bytes
 *                  of N records [u64 LE time][u32 LE watch id][width chars of 0/1/x/z, MSB first].
 *
 * The library serves commands only while the simulation is parked inside one of its cbReadOnlySynch callbacks
 * (values settled for that time step). The $simctl_serve system task serves too, but only when called from HDL:
 * the simulator's command line (`call`) can't reach a VPI-registered task.
 *
 * ops: R id dt              run dt time units (simulation precision)
 *      U id dtmax expr      run until expr is true at a time step where one of its signals changed
 *                           (expr: sig == lit | sig != lit, joined by && and ||, && binds tighter)
 *      S id                 stop a run (polled while running)
 *      T id                 current time
 *      G id sig...          read values
 *      F id sig lit | D id sig lit | L id sig    force, deposit, release. Queued until the next Y; issued while
 *                           parked in the read-only region they are applied 1 time unit later, all of one group
 *                           at the same time, and each reply carries that time
 *      Y id                 end of a write group: apply the queued writes (no reply of its own)
 *      W id sig...          watch (value-change callbacks; changes are recorded once per time step,
 *                           after the step settles, and only when the value differs)
 *      X id wid...          unwatch
 *      E id                 emit every active watch's current value as a record now
 *      I id                 list active watches
 *      N id scope limit     list nets/variables under a scope (recursive)
 *      O id poll dt         set the stop-poll interval while running
 *      P id                 park in the simulator's command line (vpi_control(vpiStop)) for checkpoint/restore;
 *                           the controller writes `K` and then `run` there, and serving resumes at the next time
 *                           step + 1 time unit (the stop takes effect only once the simulation moves on)
 *      K id                 resume token (see P)
 *      V id file            fork-save: a file save in a forked copy; the simulation goes on (simctl_forksave.c)
 *      H id                 describe: the build's simctl_cfg/simctl_port instances (simctl_describe.c)
 *      M id mem packedfile  loadmem: write a memory image (index hex per line) one time unit later (simctl_mem.c)
 *      A id at sym arg ...  apply: call an already-loaded native routine at a writable point, reply once settled
 *                           (simctl_apply.c; the TB holds at simctl_hold.sv)
 *      Q id                 finish
 *
 * Tokens are separated by single spaces and lines by \n; the controller never sends a token with whitespace or
 * control characters (it refuses such names and values), so a token can't carry another command.
 *
 * If the controller goes away (its command pipe reaches EOF), the library ends the whole process group: the
 * controller starts the simulator in a session of its own (and says so with SIMCTL_OWN_GROUP), and checkpoint children and the simulator's command-line
 * process are in that group too, so nothing of the simulation outlives its controller.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <dirent.h>
#include <pwd.h>
#include <sys/types.h>
#include "vpi_user.h"
#if defined(__has_include)
#if __has_include("sv_vpi_user.h")
#include "sv_vpi_user.h"   /* the SystemVerilog object types (strings, chandles, classes) */
#endif
#endif

#ifndef vpiInternalScope
#define vpiInternalScope 92
#endif

static int in_fd = -1, out_fd = -1;
static int fs_child, fs_alive;     /* fork-save (simctl_forksave.c): in a save child; saves out */
static void fs_reap(void);
static pid_t own_group = 0;           /* the simulator's process group, when it was started as its leader */

/* The controller is gone: end every process of the simulation's group (the parked original after a restore,
 * checkpoint children, the command-line process), then this one. A forked reaper makes sure of it a moment
 * later even if one of them ignores SIGTERM. */
/* The simulator leaves /tmp/vcs_{attachable,dve_general}.<user>.<pid> behind when it is killed (or ends on
 * SIGTERM): the reaper removes those of the group's processes, collected before anything is signalled. */
static int group_pids(pid_t pgid, pid_t *pids, int max) {
  int n = 0;
  DIR *d = opendir("/proc"); struct dirent *e;
  while (d && (e = readdir(d)) && n < max) {
    if (!isdigit((unsigned char)e->d_name[0])) continue;
    char path[300], st[512]; snprintf(path, sizeof path, "/proc/%s/stat", e->d_name);
    int fd = open(path, O_RDONLY); if (fd < 0) continue;
    ssize_t k = read(fd, st, sizeof st - 1); close(fd); if (k <= 0) continue; st[k] = 0;
    char *rp = strrchr(st, ')'); int ppid, pg; char state;
    if (rp && sscanf(rp + 2, "%c %d %d", &state, &ppid, &pg) == 3 && pg == pgid) pids[n++] = (pid_t)atoi(e->d_name);
  }
  if (d) closedir(d);
  return n;
}
static void lost_controller(void) {
  if (fs_child) return;               /* a save child has no controller: it only saves and _exit()s */
  if (own_group > 0) {
    static pid_t pids[256]; int n = group_pids(own_group, pids, 256);
    /* SIGTERM blocked across the fork: the group's SIGTERM below must not kill the reaper before its setsid. */
    sigset_t term, old; sigemptyset(&term); sigaddset(&term, SIGTERM); sigprocmask(SIG_BLOCK, &term, &old);
    pid_t r = fork();
    if (r == 0) {
      setsid();                       /* outside the group: it outlives the kill to clean up */
      signal(SIGTERM, SIG_IGN); sigprocmask(SIG_SETMASK, &old, 0);
      usleep(700 * 1000);
      kill(-own_group, SIGKILL);
      usleep(100 * 1000);
      struct passwd *pw = getpwuid(getuid());
      for (int i = 0; pw && i < n; i++) {
        char f[512];
        snprintf(f, sizeof f, "/tmp/vcs_attachable.%s.%d", pw->pw_name, (int)pids[i]); unlink(f);
        snprintf(f, sizeof f, "/tmp/vcs_dve_general.%s.%d", pw->pw_name, (int)pids[i]); unlink(f);
      }
      _exit(0);
    }
    signal(SIGTERM, SIG_IGN);
    sigprocmask(SIG_SETMASK, &old, 0);
    kill(-own_group, SIGTERM);
  }
  vpi_control(vpiFinish, 0);
}

/* ---------------------------------------------------------------- output */
typedef struct { char *p; size_t n, cap; } buf_t;
static void bgrow(buf_t *b, size_t add) {
  if (b->n + add <= b->cap) return;
  size_t c = b->cap ? b->cap : 4096;
  while (c < b->n + add) c *= 2;
  b->p = realloc(b->p, c);
  if (!b->p) _exit(4);
  b->cap = c;
}
static void bput(buf_t *b, const void *p, size_t n) { bgrow(b, n); memcpy(b->p + b->n, p, n); b->n += n; }
static void bstr(buf_t *b, const char *s) { bput(b, s, strlen(s)); }
static void bfmt(buf_t *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
#include <stdarg.h>
static void bfmt(buf_t *b, const char *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  char tmp[256]; int k = vsnprintf(tmp, sizeof tmp, fmt, ap); va_end(ap);
  if (k < (int)sizeof tmp) { bput(b, tmp, k); return; }
  bgrow(b, k + 1); va_start(ap, fmt); vsnprintf(b->p + b->n, k + 1, fmt, ap); va_end(ap); b->n += k;
}
static void bjson(buf_t *b, const char *s) {
  bput(b, "\"", 1);
  for (; *s; s++) {
    unsigned char c = *s;
    if (c == '"' || c == '\\') { bput(b, "\\", 1); bput(b, s, 1); }
    else if (c < 0x20) bfmt(b, "\\u%04x", c);
    else bput(b, s, 1);
  }
  bput(b, "\"", 1);
}
static void wr(const void *p, size_t n) {
  if (fs_child) return;               /* a save child's copy of the channel is closed: it says nothing */
  const char *c = p;
  while (n) {
    ssize_t k = write(out_fd, c, n);
    if (k < 0) { if (errno == EINTR) continue; _exit(3); }
    c += k; n -= (size_t)k;
  }
}
static buf_t ob;                      /* one reply being built */
static void send_ob(void) { bput(&ob, "\n", 1); wr(ob.p, ob.n); ob.n = 0; }

static uint64_t now(void) {
  s_vpi_time t; t.type = vpiSimTime; vpi_get_time(NULL, &t);
  return ((uint64_t)(uint32_t)t.high << 32) | (uint32_t)t.low;
}
static double wall_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6; }

/* ---------------------------------------------------------------- signals (handle cache) */
typedef struct { char *name; vpiHandle h; int width; } simsig_t;
static simsig_t *sigs; static int nsigs, capsigs;
static int *htab; static int hcap;     /* open addressing, values are index+1 */
static uint64_t hstr(const char *s) { uint64_t h = 1469598103934665603ull; for (; *s; s++) h = (h ^ (unsigned char)*s) * 1099511628211ull; return h; }
static void hput(int idx) {
  uint64_t h = hstr(sigs[idx].name);
  for (int i = (int)(h & (hcap - 1));; i = (i + 1) & (hcap - 1)) if (!htab[i]) { htab[i] = idx + 1; return; }
}
/* Objects whose value is not a vector of bits are not signals here: reals, strings, events, handles and classes
 * (and scopes, arrays and anything else that has no binary-string value; that is checked by reading one). */
static int value_type(int ty) {
  switch (ty) {
  case vpiRealVar: case vpiNamedEvent: case vpiModule: case vpiTask: case vpiFunction:
#ifdef vpiRealNet
  case vpiRealNet:
#endif
#ifdef vpiShortRealVar
  case vpiShortRealVar:
#endif
#ifdef vpiStringVar
  case vpiStringVar:
#endif
#ifdef vpiChandleVar
  case vpiChandleVar:
#endif
#ifdef vpiClassVar
  case vpiClassVar:
#endif
#ifdef vpiNamedEventArray
  case vpiNamedEventArray:
#endif
    return 0;
  default: return 1;
  }
}
/* index of the signal, or -1 if the name doesn't resolve to something with a value */
static int sig_get(const char *name) {
  if (hcap) {
    uint64_t h = hstr(name);
    for (int i = (int)(h & (hcap - 1)); htab[i]; i = (i + 1) & (hcap - 1))
      if (!strcmp(sigs[htab[i] - 1].name, name)) return sigs[htab[i] - 1].h ? htab[i] - 1 : -1;
  }
  if ((nsigs + 1) * 2 > hcap) {
    int nc = hcap ? hcap * 2 : 1024;
    free(htab); htab = calloc(nc, sizeof *htab); hcap = nc;
    for (int i = 0; i < nsigs; i++) hput(i);
  }
  if (nsigs == capsigs) { capsigs = capsigs ? capsigs * 2 : 256; sigs = realloc(sigs, capsigs * sizeof *sigs); }
  simsig_t *s = &sigs[nsigs];
  s->name = strdup(name);
  s->h = vpi_handle_by_name(s->name, NULL);
  s->width = 0;
  if (s->h && !value_type(vpi_get(vpiType, s->h))) s->h = NULL;
  if (s->h) {
    s->width = vpi_get(vpiSize, s->h);
    /* only objects that give a binary string value are signals here (not scopes, arrays, reals, strings) */
    s_vpi_value v; v.format = vpiBinStrVal; v.value.str = NULL;
    if (s->width > 0) vpi_get_value(s->h, &v);
    s_vpi_error_info e;
    if (s->width <= 0 || vpi_chk_error(&e) || !v.value.str) { s->h = NULL; s->width = 0; }
  }
  hput(nsigs);
  nsigs++;
  return s->h ? nsigs - 1 : -1;
}
/* width chars of 0/1/x/z, MSB first */
static void getbin(const simsig_t *s, char *dst) {
  s_vpi_value v; v.format = vpiBinStrVal; v.value.str = NULL; vpi_get_value(s->h, &v);
  const char *p = v.format == vpiBinStrVal && v.value.str ? v.value.str : "";
  size_t L = strlen(p), w = (size_t)s->width;
  if (L >= w) memcpy(dst, p + L - w, w);
  else {
    char pad = (L && (p[0] == 'x' || p[0] == 'X' || p[0] == 'z' || p[0] == 'Z')) ? p[0] : '0';
    memset(dst, pad, w - L); memcpy(dst + (w - L), p, L);
  }
  for (size_t i = 0; i < w; i++) dst[i] = (char)tolower((unsigned char)dst[i]);
}

/* literal -> width chars. 'b1x0, 'hff, 'd12, 12, 8'h3f, 0x3f, 1_000, 'dx. Wider than the signal: the low bits
 * (as Verilog truncates). Returns 0 on success. */
static int lit2bin(const char *lit, int width, char *dst) {
  const char *q = strchr(lit, '\'');
  int base = 10; const char *d = lit;
  if (q) {
    char b = (char)tolower((unsigned char)q[1]);
    if (b == 's') b = (char)tolower((unsigned char)q[2]), q++;
    base = b == 'b' ? 2 : b == 'h' ? 16 : b == 'o' ? 8 : b == 'd' ? 10 : 0;
    if (!base) return -1;
    d = q + 2;
  } else if (lit[0] == '0' && (lit[1] == 'x' || lit[1] == 'X')) { base = 16; d = lit + 2; }
  else if (lit[0] == '0' && (lit[1] == 'b' || lit[1] == 'B')) { base = 2; d = lit + 2; }
  char tmp[8192]; size_t n = 0;
  if (base == 10) {
    /* any number of digits (no saturation at 64 bits), '_' between them; 'dx / 'dz: all bits x / z */
    char dig[2600]; size_t nd = 0;
    char lc = (char)tolower((unsigned char)d[0]);
    if ((lc == 'x' || lc == 'z' || lc == '?') && !d[1]) { tmp[n++] = lc == '?' ? 'x' : lc; goto fit; }
    for (const char *c = d; *c; c++) {
      if (*c == '_' && c != d) continue;
      if (!isdigit((unsigned char)*c) || nd + 1 >= sizeof dig) return -1;
      if (nd || *c != '0') dig[nd++] = (char)(*c - '0');
    }
    if (d[0] == 0 || d[0] == '_') return -1;
    char bits[8192]; size_t nb = 0;   /* LSB first: repeated division by 2 */
    while (nd) {
      int rem = 0; size_t k = 0;
      for (size_t i = 0; i < nd; i++) { int cur = rem * 10 + dig[i]; dig[i] = (char)(cur / 2); rem = cur % 2; }
      while (k < nd && !dig[k]) k++;
      memmove(dig, dig + k, nd - k); nd -= k;
      if (nb >= sizeof bits) return -1;
      bits[nb++] = (char)('0' + rem);
    }
    if (!nb) bits[nb++] = '0';
    while (nb) tmp[n++] = bits[--nb];
  } else {
    int bits = base == 2 ? 1 : base == 8 ? 3 : 4;
    for (; *d; d++) {
      char c = (char)tolower((unsigned char)*d);
      if (c == '_') continue;
      if (n + 4 >= sizeof tmp) return -1;
      if (c == 'x' || c == 'z' || c == '?') { for (int i = 0; i < bits; i++) tmp[n++] = c == '?' ? 'x' : c; continue; }
      int v = isdigit((unsigned char)c) ? c - '0' : (c >= 'a' && c <= 'f') ? c - 'a' + 10 : 99;
      if (v >= base) return -1;
      for (int i = bits - 1; i >= 0; i--) tmp[n++] = (char)('0' + ((v >> i) & 1));
    }
    if (!n) return -1;
  }
fit:
  if ((int)n >= width) memcpy(dst, tmp + n - width, width);
  else { char pad = (tmp[0] == 'x' || tmp[0] == 'z') ? tmp[0] : '0'; memset(dst, pad, width - n); memcpy(dst + width - n, tmp, n); }
  return 0;
}

/* ---------------------------------------------------------------- watches and records */
typedef struct { int sig; vpiHandle cb; char *last; int dirty, active; } watch_t;
static watch_t *watches; static int nwatch, capwatch;
static int *dirty; static int ndirty, capdirty;
static buf_t recs; static int nrecs; static double last_flush;
static int ro_pending, need_serve, cond_dirty, in_ro, quick_pending;
static char serve_reason[16];
/* apply + settle state (simctl_apply.c) */
static vpiHandle hold_st, hold_rel, hold_pulse; static int held, serving_hold, discarded; static long long released_at;
static void hold_wake(int st); static void hold_put(vpiHandle h, int v, int scalar); static void hold_later(int st);
static void settle_reply(void);
static long settle_id;
static long long hold_since = -1, held_units = -1;   /* when the TB's current hold began; a release's span */

static void send_recs(void) {
  if (!nrecs) return;
  char hdr[96]; int k = snprintf(hdr, sizeof hdr, "{\"ev\":\"chg\",\"n\":%d,\"bin\":%zu}\n", nrecs, recs.n);
  wr(hdr, k); wr(recs.p, recs.n);
  recs.n = 0; nrecs = 0; last_flush = wall_ms();
}
static void add_rec(uint64_t t, int wid, const char *val, int width) {
  uint32_t w = (uint32_t)wid;
  bput(&recs, &t, 8); bput(&recs, &w, 4); bput(&recs, val, width); nrecs++;
}
static char *scratch; static size_t scratch_cap;
static char *tmpval(int width) {
  if ((size_t)width + 1 > scratch_cap) { scratch_cap = width + 1024; scratch = realloc(scratch, scratch_cap); }
  return scratch;
}
static void flush_dirty(void) {
  if (!ndirty) return;
  uint64_t t = now();
  for (int i = 0; i < ndirty; i++) {
    watch_t *w = &watches[dirty[i]];
    w->dirty = 0;
    if (!w->active) continue;
    simsig_t *s = &sigs[w->sig];
    char *v = tmpval(s->width);
    getbin(s, v);
    if (memcmp(v, w->last, s->width)) { memcpy(w->last, v, s->width); add_rec(t, dirty[i], v, s->width); }
  }
  ndirty = 0;
  if (recs.n > (1u << 18)) send_recs();
}

static PLI_INT32 ro_rtn(p_cb_data d);
static void sched_ro(void) {
  if (ro_pending || in_ro) return;
  s_cb_data cb; memset(&cb, 0, sizeof cb);
  s_vpi_time t; t.type = vpiSimTime; t.high = 0; t.low = 0;
  cb.reason = cbReadOnlySynch; cb.cb_rtn = ro_rtn; cb.time = &t;
  vpiHandle h = vpi_register_cb(&cb);
  if (h) vpi_release_handle(h);
  ro_pending = 1;
}
static PLI_INT32 vc_rtn(p_cb_data d) { if (fs_child) return 0;
  int id = (int)(intptr_t)d->user_data;
  if (!watches[id].dirty) {
    watches[id].dirty = 1;
    if (ndirty == capdirty) { capdirty = capdirty ? capdirty * 2 : 256; dirty = realloc(dirty, capdirty * sizeof *dirty); }
    dirty[ndirty++] = id;
  }
  sched_ro();
  return 0;
}
static vpiHandle vc_register(vpiHandle obj, PLI_INT32 (*rtn)(p_cb_data), void *ud) {
  static s_vpi_time t; static s_vpi_value v;
  t.type = vpiSuppressTime; v.format = vpiSuppressVal;
  s_cb_data cb; memset(&cb, 0, sizeof cb);
  cb.reason = cbValueChange; cb.cb_rtn = rtn; cb.obj = obj; cb.time = &t; cb.value = &v; cb.user_data = ud;
  return vpi_register_cb(&cb);
}

/* ---------------------------------------------------------------- run control */
typedef struct { int sig; int ne; char *val; } cond_t;
static cond_t *conds; static int nconds; static int *cond_or; /* cond_or[i]=1: an || precedes cond i */
static vpiHandle *cond_cbs;
static vpiHandle end_cb, poll_cb;
static uint64_t poll_dt = 1000000;
static int running; static long run_id = -1, stop_id = -1;
static int finished;

static PLI_INT32 cond_rtn(p_cb_data d) { (void)d; if (fs_child) return 0; cond_dirty = 1; sched_ro(); return 0; }
static void clear_conds(void) {
  for (int i = 0; i < nconds; i++) { if (cond_cbs[i]) vpi_remove_cb(cond_cbs[i]); free(conds[i].val); }
  free(conds); free(cond_or); free(cond_cbs); conds = NULL; cond_or = NULL; cond_cbs = NULL; nconds = 0; cond_dirty = 0;
}
static int eval_conds(void) {
  int any = 0, group = 1;
  for (int i = 0; i < nconds; i++) {
    if (i && cond_or[i]) { any |= group; group = 1; }
    simsig_t *s = &sigs[conds[i].sig];
    char *v = tmpval(s->width); getbin(s, v);
    int eq = !memcmp(v, conds[i].val, s->width);
    group &= conds[i].ne ? !eq : eq;
  }
  return any | group;
}
static void stop_run(const char *why) {
  if (end_cb) { vpi_remove_cb(end_cb); end_cb = NULL; }
  if (poll_cb) { vpi_remove_cb(poll_cb); poll_cb = NULL; }
  clear_conds();
  running = 0;
  snprintf(serve_reason, sizeof serve_reason, "%s", why);
  need_serve = 1;
  sched_ro();
}
static PLI_INT32 end_rtn(p_cb_data d) { if (fs_child) return 0; (void)d; if (end_cb) vpi_release_handle(end_cb); end_cb = NULL; stop_run("done"); return 0; }

/* input buffer shared by the serve loop and the poll callback */
static char *inb; static size_t inlen, incap;
static int fill(int block) {
  if (fs_child) return -1;
  if (!block) { struct pollfd p = { in_fd, POLLIN, 0 }; if (poll(&p, 1, 0) <= 0) return 0; }
  else while (fs_alive) {   /* waiting for a request while saves are out: report their ends meanwhile */
    struct pollfd p = { in_fd, POLLIN, 0 };
    if (poll(&p, 1, 200) != 0) break;
    fs_reap();
  }
  if (incap - inlen < 65536) { incap = incap ? incap * 2 : 1 << 20; inb = realloc(inb, incap); }
  ssize_t k;
  do k = read(in_fd, inb + inlen, incap - inlen); while (k < 0 && errno == EINTR);
  if (k <= 0) return -1;
  inlen += (size_t)k;
  return 1;
}
static vpiHandle after(uint64_t dt, PLI_INT32 (*rtn)(p_cb_data)) {
  s_cb_data cb; memset(&cb, 0, sizeof cb);
  s_vpi_time t; t.type = vpiSimTime; t.high = (PLI_UINT32)(dt >> 32); t.low = (PLI_UINT32)dt;
  cb.reason = cbAfterDelay; cb.cb_rtn = rtn; cb.time = &t;
  return vpi_register_cb(&cb);
}
static int is_quick(char op);
static PLI_INT32 poll_rtn(p_cb_data d) { if (fs_child) return 0; if (fs_alive) fs_reap();
  (void)d;
  if (poll_cb) { vpi_release_handle(poll_cb); poll_cb = NULL; }   /* fired: its handle is ours to free */
  if (!running) return 0;
  if (fill(0) < 0) { stop_run("eof"); lost_controller(); return 0; }
  /* a stop line anywhere in the buffer ends the run; other lines wait for the serve loop */
  char *p = inb, *e = inb + inlen;
  while (p < e) {
    char *nl = memchr(p, '\n', e - p);
    if (!nl) break;
    if (p[0] == 'S' && (p[1] == ' ' || p[1] == '\n')) {
      stop_id = strtol(p + 1, NULL, 10);
      memmove(p, nl + 1, e - nl - 1); inlen -= (nl + 1 - p);
      stop_run("stop");
      return 0;
    }
    p = nl + 1;
  }
  /* the first waiting line only looks or changes the watches: serve it (and those after it) at this time's
   * ReadOnlySynch, while the run goes on; anything else waits for the run's end, and so do the lines after it */
  if (inlen && is_quick(inb[0]) && memchr(inb, '\n', inlen)) { quick_pending = 1; sched_ro(); }
  if (nrecs && wall_ms() - last_flush > 30) send_recs();
  poll_cb = after(poll_dt, poll_rtn);
  return 0;
}

/* ---------------------------------------------------------------- writes
 * A value written in the read-only region has no effect, so writes asked for while parked in a cbReadOnlySynch
 * are applied one time unit later (cbAfterDelay(1), a writable region), then the loop serves again at that time's
 * ReadOnlySynch and replies with the settled values. From $simctl_serve they are applied at once.
 * Known race: one time unit is the simulation's precision. When the design's own delays are that small (e.g.
 * 1ns/1ns with #1 clocks), t+1 can be a time the design also acts at, and the order of the write against that
 * activity is the simulator's; the reply's value is what settled. */
typedef struct { char op; int sig; long id; char *val; } wr_t;
static wr_t *wq; static int nwq, capwq;
static long *wdone; static int nwdone, capwdone;
static void apply_write(wr_t *w) {
  simsig_t *s = &sigs[w->sig];
  s_vpi_value val; val.format = vpiBinStrVal; val.value.str = w->val;
  if (w->op == 'L') { getbin(s, w->val); w->val[s->width] = 0; vpi_put_value(s->h, &val, NULL, vpiReleaseFlag); }
  else vpi_put_value(s->h, &val, NULL, w->op == 'F' ? vpiForceFlag : vpiNoDelay);
}
static void reply_write(long id, int si) {
  simsig_t *s = &sigs[si];
  bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"value\":\"", id, (unsigned long long)now());
  bgrow(&ob, s->width); getbin(s, ob.p + ob.n); ob.n += s->width; bstr(&ob, "\"}"); send_ob();
}
static PLI_INT32 write_rtn(p_cb_data d) { if (fs_child) return 0;
  (void)d;
  for (int i = 0; i < nwq; i++) {
    apply_write(&wq[i]); free(wq[i].val);
    if (nwdone + 2 > capwdone) { capwdone = capwdone ? capwdone * 2 : 64; wdone = realloc(wdone, capwdone * sizeof *wdone); }
    wdone[nwdone++] = wq[i].id; wdone[nwdone++] = wq[i].sig;
  }
  nwq = 0;
  snprintf(serve_reason, sizeof serve_reason, "write");
  need_serve = 1; sched_ro();
  return 0;
}

/* After P, vpi_control(vpiStop) takes effect only after the sim has moved on, so this callback can fire before the
 * simulator's command line has had its turn. It serves only once the controller has written a `K` line (sent after
 * its command-line work); until then it re-arms itself one time unit later without blocking.
 * Why a delay of 1 and not cbNextSimTime: next-sim-time callbacks fire only when there is a next event, so with
 * no scheduled activity left (a quiet design while parked) they would never fire and the library would never
 * serve again. The 1-unit steps last only from P until the controller's K, a short window. */
static PLI_INT32 resume_rtn(p_cb_data d) { if (fs_child) return 0;
  (void)d;
  if (fill(0) < 0) { lost_controller(); return 0; }
  char *p = inb, *e = inb + inlen;
  while (p < e) {
    char *nl = memchr(p, '\n', e - p);
    if (!nl) break;
    if (p[0] == 'K' && (p[1] == ' ' || p[1] == '\n')) {
      memmove(p, nl + 1, e - nl - 1); inlen -= (nl + 1 - p);
      if (held) { hold_wake(2); return 0; }   /* parked from a held TB: serve again inside its $simctl_serve */
      snprintf(serve_reason, sizeof serve_reason, "resume"); need_serve = 1; sched_ro();
      return 0;
    }
    p = nl + 1;
  }
  /* only here, while a park's stop is pending (P until K): the held TB makes no activity of its own, and the
   * stop takes effect only at some. Each step is one time unit (the reply's t shows it). Never otherwise. */
  if (held && hold_pulse) {
    s_vpi_value v; v.format = vpiScalarVal; vpi_get_value(hold_pulse, &v);
    v.value.scalar = v.value.scalar == vpi1 ? vpi0 : vpi1; vpi_put_value(hold_pulse, &v, NULL, vpiNoDelay);
  }
  vpiHandle h = after(1, resume_rtn); if (h) vpi_release_handle(h);
  return 0;
}

/* ---------------------------------------------------------------- serve loop */
enum { CTX_RO, CTX_SYSTF };
static char *nextline(void) {
  for (;;) {
    char *nl = inlen ? memchr(inb, '\n', inlen) : NULL;
    if (nl) {
      static char *line; static size_t lcap;
      size_t n = nl - inb;
      if (n + 1 > lcap) { lcap = n + 4096; line = realloc(line, lcap); }
      memcpy(line, inb, n); line[n] = 0;
      memmove(inb, nl + 1, inlen - n - 1); inlen -= n + 1;
      return line;
    }
    if (fill(1) < 0) return NULL;
  }
}
/* Tokens of a line; -1 when it has more than max (refused, never truncated). */
#define MAXTOK (1 << 16)
static int split(char *s, char **tok, int max) {
  int n = 0;
  for (;;) {
    while (*s == ' ') s++;
    if (!*s) break;
    if (n == max) return -1;
    tok[n++] = s;
    while (*s && *s != ' ') s++;
    if (*s) *s++ = 0;
  }
  return n;
}
static void reply_err(long id, const char *msg);
static void too_long(const char *line) { reply_err(strtol(line + 1, NULL, 10), "too many names in one request (limit 65534)"); }
static void reply_err(long id, const char *msg) { bfmt(&ob, "{\"id\":%ld,\"error\":", id); bjson(&ob, msg); bstr(&ob, "}"); send_ob(); }

static void list_scope(vpiHandle scope, int limit, int *count, int *trunc) {
  /* nets, then regs, then SV variables; a name seen earlier in this scope is skipped */
  static const int kinds[] = { vpiNet, vpiReg, vpiVariables };
  char **seen = NULL; int nseen = 0, capseen = 0;
  for (int k = 0; k < 3 && !*trunc; k++) {
    vpiHandle it = vpi_iterate(kinds[k], scope), o;
    if (!it) continue;
    while ((o = vpi_scan(it))) {
      int ty = vpi_get(vpiType, o);
      if (ty == vpiMemory || ty == 114 /* vpiNetArray */ || ty == 116 /* vpiRegArray / vpiArrayVar */) continue;
      char *nm = vpi_get_str(vpiFullName, o);
      int w = vpi_get(vpiSize, o);
      if (!nm || w <= 0) continue;
      int dup = 0;
      for (int i = 0; i < nseen && !dup; i++) dup = !strcmp(seen[i], nm);
      if (dup) continue;
      if (*count >= limit) { *trunc = 1; vpi_release_handle(it); break; }
      if (nseen == capseen) { capseen = capseen ? capseen * 2 : 64; seen = realloc(seen, capseen * sizeof *seen); }
      seen[nseen++] = strdup(nm);
      bstr(&ob, *count ? ",{\"name\":" : "{\"name\":"); bjson(&ob, nm); bfmt(&ob, ",\"width\":%d,\"type\":%d}", w, ty);
      (*count)++;
    }
  }
  for (int i = 0; i < nseen; i++) free(seen[i]);
  free(seen);
  vpiHandle it = vpi_iterate(vpiInternalScope, scope), o;
  if (!it) return;
  while ((o = vpi_scan(it))) {
    if (*trunc) continue;
    list_scope(o, limit, count, trunc);
  }
}

static void emit_all(void) {
  uint64_t t = now();
  for (int i = 0; i < nwatch; i++) {
    watch_t *w = &watches[i]; if (!w->active) continue;
    simsig_t *s = &sigs[w->sig]; getbin(s, w->last); add_rec(t, i, w->last, s->width);
  }
  send_recs();
}

/* Requests that only look (time, read, list, watches) or change what is watched: served by the loop, and also
 * during a run at its poll points (see poll_rtn), at that time's ReadOnlySynch, without ending the run. A read's
 * reply carries the time it observed; a new watch's first record (its value then) is where its coverage starts. */
#include "simctl_forksave.c"
#include "simctl_describe.c"
#include "simctl_mem.c"
#include "simctl_apply.c"
static int is_quick(char op) { return op == 'T' || op == 'G' || op == 'W' || op == 'X' || op == 'I' || op == 'N' || op == 'V'; }
static void quick_op(char op, long id, char **tok, int nt, uint64_t t) {
  switch (op) {
    case 'V': forksave(id, nt >= 3 ? tok[2] : NULL, t); break;
    case 'T': bfmt(&ob, "{\"id\":%ld,\"t\":%llu%s}", id, (unsigned long long)t, discarded ? ",\"tainted\":true" : ""); send_ob(); break;
    case 'G': {
      bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"values\":[", id, (unsigned long long)t);
      for (int i = 2; i < nt; i++) {
        if (i > 2) bput(&ob, ",", 1);
        int si = sig_get(tok[i]);
        if (si < 0) { bstr(&ob, "null"); continue; }
        bgrow(&ob, sigs[si].width + 2);
        ob.p[ob.n++] = '"'; getbin(&sigs[si], ob.p + ob.n); ob.n += sigs[si].width; ob.p[ob.n++] = '"';
      }
      bstr(&ob, discarded ? "],\"tainted\":true}" : "]}"); send_ob(); break;
    }
    case 'W': {
      bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"watch\":[", id, (unsigned long long)t);
      int first_new = nwatch;
      for (int i = 2; i < nt; i++) {
        if (i > 2) bput(&ob, ",", 1);
        int si = sig_get(tok[i]);
        if (si < 0) { bstr(&ob, "null"); continue; }
        if (nwatch == capwatch) { capwatch = capwatch ? capwatch * 2 : 256; watches = realloc(watches, capwatch * sizeof *watches); }
        watch_t *w = &watches[nwatch];
        w->sig = si; w->dirty = 0; w->active = 1; w->last = malloc(sigs[si].width);
        getbin(&sigs[si], w->last);
        w->cb = vc_register(sigs[si].h, vc_rtn, (void *)(intptr_t)nwatch);
        if (!w->cb) { w->active = 0; bstr(&ob, "null"); nwatch++; continue; }
        bfmt(&ob, "{\"wid\":%d,\"width\":%d}", nwatch, sigs[si].width);
        nwatch++;
      }
      bstr(&ob, "]}"); send_ob();
      for (int i = first_new; i < nwatch; i++) if (watches[i].active) add_rec(t, i, watches[i].last, sigs[watches[i].sig].width);
      send_recs();
      break;
    }
    case 'X': {
      int n = 0;
      for (int i = 2; i < nt; i++) {
        int wid = atoi(tok[i]);
        if (wid < 0 || wid >= nwatch || !watches[wid].active) continue;
        vpi_remove_cb(watches[wid].cb); watches[wid].active = 0; free(watches[wid].last); watches[wid].last = NULL; n++;
      }
      bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"unwatched\":%d}", id, (unsigned long long)t, n); send_ob();
      break;
    }
    case 'I': {
      bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"watches\":[", id, (unsigned long long)t);
      int k = 0;
      for (int i = 0; i < nwatch; i++) if (watches[i].active) {
        bstr(&ob, k++ ? ",{\"wid\":" : "{\"wid\":"); bfmt(&ob, "%d,\"name\":", i); bjson(&ob, sigs[watches[i].sig].name);
        bfmt(&ob, ",\"width\":%d}", sigs[watches[i].sig].width);
      }
      bstr(&ob, "]}"); send_ob(); break;
    }
    case 'N': {
      vpiHandle sc = nt >= 3 ? vpi_handle_by_name(tok[2], NULL) : NULL;
      if (!sc) { reply_err(id, "unknown scope"); break; }
      int limit = nt >= 4 ? atoi(tok[3]) : 10000, count = 0, trunc = 0;
      bfmt(&ob, "{\"id\":%ld,\"vars\":[", id);
      list_scope(sc, limit, &count, &trunc);
      bfmt(&ob, "],\"truncated\":%s}", trunc ? "true" : "false"); send_ob(); break;
    }
  }
}

/* During a run: serve the waiting lines from the front while they are quick ones (whole lines only). */
static void serve_quick(void) {
  static char *qtok[MAXTOK];
  uint64_t t = now();
  for (;;) {
    char *nl = inlen ? memchr(inb, '\n', inlen) : NULL;
    if (!nl || !is_quick(inb[0])) break;
    char *line = nextline();
    char head[32]; snprintf(head, sizeof head, "%s", line);
    int nt = split(line, qtok, MAXTOK);
    if (nt < 0) { too_long(head); continue; }
    if (nt < 2) continue;
    quick_op(qtok[0][0], strtol(qtok[1], NULL, 10), qtok, nt, t);
    if (fs_child) return;   /* a forksave child: back to the simulation, to its save; no more lines */
  }
  send_recs();
}

static void serve(int ctx) {
  if (need_serve) need_serve = 0;
  flush_dirty(); send_recs();
  if (ctx == CTX_RO) settle_reply();   /* settled means after this time step's propagation: only at ReadOnlySynch */
  if (run_id >= 0) {
    bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"stopped\":\"%s\"", run_id, (unsigned long long)now(), serve_reason);
    if (released_at >= 0) bfmt(&ob, ",\"released\":%lld,\"heldUnits\":%lld", released_at, held_units);
    bstr(&ob, "}"); send_ob();
    run_id = -1; released_at = -1;
  }
  for (int i = 0; i < nwdone; i += 2) reply_write(wdone[i], (int)wdone[i + 1]);
  nwdone = 0;
  if (stop_id >= 0) { bfmt(&ob, "{\"id\":%ld,\"t\":%llu}", stop_id, (unsigned long long)now()); send_ob(); stop_id = -1; }
  static char *tok[MAXTOK];
  for (;;) {
    if (fs_child) return;   /* a forksave child (V just forked it): back to the simulation, to its save */
    char *line = nextline();
    if (!line) { lost_controller(); return; }
    char head[32]; snprintf(head, sizeof head, "%s", line);
    int nt = split(line, tok, MAXTOK);
    if (nt < 0) { too_long(head); continue; }
    if (nt < 2) continue;
    char op = tok[0][0]; long id = strtol(tok[1], NULL, 10);
    uint64_t t = now();
    if (discarded && strchr("RUAFDLM", op)) { reply_err(id, "this branch is discarded (an apply returned -2): restore a checkpoint from before it"); continue; }
    switch (op) {
    case 'T': case 'G': case 'W': case 'X': case 'I': case 'N': case 'V': quick_op(op, id, tok, nt, t); break;
    case 'A': if (apply_req(id, tok, nt, ctx)) return; break;
    case 'K': break;   /* a resume token that arrived while serving: nothing to do */
    case 'H': describe(id, t); break;
    case 'M':
      if (nt < 4) { reply_err(id, "loadmem: expected memory and file"); break; }
      if (loadmem(id, tok[2], tok[3], ctx)) return;   /* written one time unit later; serving resumes after */
      break;
    case 'S': bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"idle\":true}", id, (unsigned long long)t); send_ob(); break;
    case 'R': case 'U': {
      if (nt < 3) { reply_err(id, "missing time"); break; }
      uint64_t dt = strtoull(tok[2], NULL, 10);
      if (op == 'U') {
        /* parse: sig op lit [&&|| sig op lit]... */
        int n = (nt - 3 + 1) / 4;
        if (n < 1 || (nt - 3) != n * 4 - 1) { reply_err(id, "expected: sig == value [&& | || ...]"); break; }
        conds = calloc(n, sizeof *conds); cond_or = calloc(n, sizeof *cond_or); cond_cbs = calloc(n, sizeof *cond_cbs);
        const char *err = NULL;
        for (int i = 0; i < n && !err; i++) {
          char **c = tok + 3 + i * 4;
          if (i) { if (!strcmp(c[-1], "||")) cond_or[i] = 1; else if (strcmp(c[-1], "&&")) err = "join conditions with && or ||"; }
          int si = sig_get(c[0]);
          if (si < 0) { err = "unknown signal in expression"; break; }
          if (strcmp(c[1], "==") && strcmp(c[1], "!=")) { err = "operator must be == or !="; break; }
          conds[i].sig = si; conds[i].ne = c[1][0] == '!';
          conds[i].val = malloc(sigs[si].width);
          nconds = i + 1;
          if (lit2bin(c[2], sigs[si].width, conds[i].val)) { err = "bad value literal"; break; }
          cond_cbs[i] = vc_register(sigs[si].h, cond_rtn, NULL);
        }
        if (err) { clear_conds(); reply_err(id, err); break; }
      }
      if (dt == 0) {
        if (op == 'U') clear_conds();
        bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"stopped\":\"done\"}", id, (unsigned long long)t); send_ob(); break;
      }
      run_id = id; running = 1;
      if (ctx == CTX_SYSTF && hold_st) { hold_put(hold_st, 0, 0); held = 0; released_at = (long long)t; held_units = released_at - hold_since; hold_since = -1; }   /* the TB goes on from here, now */
      else if (ctx == CTX_RO && held) { hold_later(0); released_at = (long long)t + 1; held_units = released_at - hold_since; hold_since = -1; }   /* t+1: writable */
      end_cb = after(dt, end_rtn);
      poll_cb = after(poll_dt < dt ? poll_dt : dt, poll_rtn);
      last_flush = wall_ms();
      return;
    }
    case 'F': case 'D': case 'L': {
      int si = nt >= 3 ? sig_get(tok[2]) : -1;
      if (si < 0) { reply_err(id, "unknown signal"); break; }
      simsig_t *s = &sigs[si];
      wr_t w = { op, si, id, malloc(s->width + 1) };
      if (op != 'L') {
        if (nt < 4 || lit2bin(tok[3], s->width, w.val)) { free(w.val); reply_err(id, "bad value literal"); break; }
        w.val[s->width] = 0;
      }
      if (nwq == capwq) { capwq = capwq ? capwq * 2 : 16; wq = realloc(wq, capwq * sizeof *wq); }
      wq[nwq++] = w;
      break;   /* applied at the group's Y */
    }
    case 'Y': {
      if (!nwq) break;               /* every write of the group failed (each has its error reply) */
      if (ctx == CTX_SYSTF) {
        for (int i = 0; i < nwq; i++) { apply_write(&wq[i]); free(wq[i].val); }
        flush_dirty(); send_recs();
        for (int i = 0; i < nwq; i++) reply_write(wq[i].id, wq[i].sig);
        nwq = 0; break;
      }
      vpiHandle h = after(1, write_rtn); if (h) vpi_release_handle(h);
      return;
    }
    case 'E': emit_all(); bfmt(&ob, "{\"id\":%ld,\"t\":%llu}", id, (unsigned long long)t); send_ob(); break;
    case 'O':
      if (nt >= 4 && !strcmp(tok[2], "poll")) poll_dt = strtoull(tok[3], NULL, 10);
      if (!poll_dt) poll_dt = 1;
      bfmt(&ob, "{\"id\":%ld,\"poll\":%llu}", id, (unsigned long long)poll_dt); send_ob(); break;
    case 'P':
      if (ctx == CTX_SYSTF && !hold_st) { bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"parked\":true}", id, (unsigned long long)t); send_ob(); return; }
      if (ctx == CTX_SYSTF) { hold_put(hold_st, 1, 0); held = 1; }   /* the TB waits; resume_rtn wakes it back in */
      {
        /* UCLI `call` can't reach a VPI-registered task, so come back by ourselves: one time unit after the
         * simulator's command line says `run` again (a checkpoint taken while parked keeps this callback too) */
        vpiHandle h = after(1, resume_rtn); if (h) vpi_release_handle(h);
      }
      vpi_control(vpiStop, 0);
      bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"parked\":true}", id, (unsigned long long)t); send_ob();
      return;
    case 'Q':
      bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"quit\":true}", id, (unsigned long long)t); send_ob();
      vpi_control(vpiFinish, 0);
      return;
    default: reply_err(id, "unknown op");
    }
  }
}

static PLI_INT32 ro_rtn(p_cb_data d) { if (fs_child) return 0; if (fs_alive) fs_reap();
  (void)d;
  ro_pending = 0; in_ro = 1;
  flush_dirty();
  if (running && cond_dirty && nconds) { cond_dirty = 0; if (eval_conds()) stop_run("until"); }
  if (quick_pending) { quick_pending = 0; if (running && !finished) serve_quick(); }
  if (need_serve && !finished) serve(CTX_RO);
  in_ro = 0;
  return 0;
}
/* $simctl_serve [(st, rel)]: the TB hands the controller its procedural context here (simctl_hold.sv) */
static vpiHandle arg_by_name(vpiHandle a) {
  char *nm = a ? vpi_get_str(vpiFullName, a) : NULL;
  vpiHandle h = nm ? vpi_handle_by_name(nm, NULL) : NULL;
  return h ? h : a;
}
PLI_INT32 simctl_serve_calltf(PLI_BYTE8 *ud) { (void)ud; if (fs_child) return 0;
  /* an apply's settle is pending (this time step's propagation is still running): any other entry now, e.g. a
   * process woken by the hook's own write, goes on at once; it neither serves nor replaces the held TB's handles */
  if (settle_id >= 0) return 0;
  vpiHandle call = vpi_handle(vpiSysTfCall, NULL), it = call ? vpi_iterate(vpiArgument, call) : NULL, a1 = NULL, a2 = NULL;
  if (it) { a1 = vpi_scan(it); if (a1) a2 = vpi_scan(it); if (a2) vpi_release_handle(it); }
  hold_st = a2 ? arg_by_name(a1) : NULL; hold_rel = a2 ? arg_by_name(a2) : NULL;
  vpiHandle sc = hold_rel ? vpi_handle(vpiScope, hold_rel) : NULL;
  hold_pulse = sc ? vpi_handle_by_name("pulse", sc) : NULL;
  held = 0;   /* serving, not waiting */
  need_serve = 0;
  if (running) {   /* the TB reached its serve point during a run: the run ends here */
    if (end_cb) { vpi_remove_cb(end_cb); end_cb = NULL; }
    if (poll_cb) { vpi_remove_cb(poll_cb); poll_cb = NULL; }
    clear_conds(); running = 0;
    snprintf(serve_reason, sizeof serve_reason, "serve");
  } else snprintf(serve_reason, sizeof serve_reason, "resume");
  serving_hold = hold_st != NULL;
  if (hold_st && hold_since < 0) hold_since = (long long)now();
  if (!(ap.armed && ap.serve && hold_st && apply_at_serve())) serve(CTX_SYSTF);   /* woken for an apply at serve: that first */
  serving_hold = 0;
  return 0;
}
static PLI_INT32 start_rtn(p_cb_data d) { if (fs_child) return 0;
  (void)d;
  snprintf(serve_reason, sizeof serve_reason, "start");
  need_serve = 1; sched_ro();
  bfmt(&ob, "{\"ev\":\"ready\",\"t\":%llu,\"precision\":%d}", (unsigned long long)now(), vpi_get(vpiTimePrecision, NULL)); send_ob();
  return 0;
}
static PLI_INT32 end_sim_rtn(p_cb_data d) { if (fs_child) return 0;
  (void)d;
  finished = 1;
  fs_end_all();   /* saves still out end with the simulation: each reported once, simExited */
  flush_dirty(); send_recs();
  if (run_id >= 0) { bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"stopped\":\"finish\"}", run_id, (unsigned long long)now()); send_ob(); run_id = -1; }
  bfmt(&ob, "{\"ev\":\"finish\",\"t\":%llu}", (unsigned long long)now()); send_ob();
  return 0;
}

void simctl_entry2(int stub_serves) {
  static int done; if (done) return; done = 1;
  if (getenv("SIMCTL_DEBUG")) { FILE *f = fopen(getenv("SIMCTL_DEBUG"), "a"); if (f) { fprintf(f, "simctl_register called\n"); fclose(f); } }
  const char *a = getenv("SIMCTL_IN_FD"), *b = getenv("SIMCTL_OUT_FD");
  if (!a || !b) return;                         /* not launched by the controller: do nothing */
  in_fd = atoi(a); out_fd = atoi(b);
  /* The controller starts the simulator in a new session (its process group = the session); a simulator run
   * from a shell's job control is not a session's group, so it is never killed this way. */
  if (getenv("SIMCTL_OWN_GROUP") && getpgrp() == getsid(0)) own_group = getpgrp();
  if (getenv("SIMCTL_DEBUG")) {
    FILE *f = fopen(getenv("SIMCTL_DEBUG"), "a");
    if (f) { fprintf(f, "register pid %d in %d(%d) out %d(%d)\n", (int)getpid(), in_fd, fcntl(in_fd, F_GETFD), out_fd, fcntl(out_fd, F_GETFD)); fclose(f); }
  }
  /* nothing the simulation starts ($system, its own tools) inherits the channel */
  unsetenv("SIMCTL_IN_FD"); unsetenv("SIMCTL_OUT_FD"); unsetenv("SIMCTL_LIB"); unsetenv("SIMCTL_OWN_GROUP");
  if (!stub_serves) {   /* the stub registers $simctl_serve itself (also at elaboration) and forwards it here */
    s_vpi_systf_data tf; memset(&tf, 0, sizeof tf);
    tf.type = vpiSysTask; tf.tfname = "$simctl_serve"; tf.calltf = simctl_serve_calltf;
    vpi_register_systf(&tf);
  }
  s_cb_data cb; memset(&cb, 0, sizeof cb);
  cb.reason = cbStartOfSimulation; cb.cb_rtn = start_rtn;
  vpiHandle h = vpi_register_cb(&cb); if (h) vpi_release_handle(h);
  memset(&cb, 0, sizeof cb);
  cb.reason = cbEndOfSimulation; cb.cb_rtn = end_sim_rtn;
  h = vpi_register_cb(&cb); if (h) vpi_release_handle(h);
}

/* debug: shows whether the simulator mapped the library at all */
__attribute__((constructor)) static void simctl_loaded(void) {
  const char *d = getenv("SIMCTL_DEBUG");
  if (!d) return;
  FILE *f = fopen(d, "a");
  if (f) { fprintf(f, "loaded pid %d\n", (int)getpid()); fclose(f); }
}

void simctl_entry(void) { simctl_entry2(0); }
/* direct use: a build that names this library itself with -load <lib>.so:simctl_register */
void simctl_register(void) { simctl_entry(); }
