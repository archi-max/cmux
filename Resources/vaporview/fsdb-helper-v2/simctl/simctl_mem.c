/* SPDX-License-Identifier: MIT
 * simctl loadmem: a memory image written into the running design. Included by simctl_vpi.c (one unit).
 *
 * `M id <memory path> <packed file>` (served when idle): the worker has parsed the agent's $readmemh/$readmemb
 * image into `<index> <hex value>` lines. All lines are checked first (every index inside the memory, every value
 * within its word width), then the words are written with vpi_put_value one time unit later (a writable region;
 * from $simctl_serve at once) and the reply is {id, t, words}. Nothing is written if a line is bad. A build
 * without write access to the memory makes vpi_put_value fail: the reply's error says so (after the words
 * before it were written: the simulator reports the failure only on the write).
 * Only documented VPI: vpi_handle_by_name, vpi_handle_by_index, vpiSize, vpi_put_value(vpiHexStrVal),
 * vpi_chk_error. */

typedef struct { int idx; char *hex; } mword_t;
static mword_t *mw; static int nmw, capmw;
static vpiHandle mem_h; static long mem_id = -1; static int mem_width;

static void mem_clear(void) { for (int i = 0; i < nmw; i++) free(mw[i].hex); nmw = 0; mem_h = NULL; mem_id = -1; }
static int is_array(vpiHandle h) {
  int ty = vpi_get(vpiType, h);
  return ty == vpiMemory || ty == vpiRegArray
#ifdef vpiArrayVar
    || ty == vpiArrayVar
#endif
    ;
}
/* significant bits of a hex string (x/z digits count as 4) */
static int hex_bits(const char *s) {
  while (*s == '0' && s[1]) s++;
  int n = (int)strlen(s);
  if (n == 0) return 0;
  int c = tolower((unsigned char)s[0]), top = 4;
  if (c >= '0' && c <= '9') { int v = c - '0'; top = v >= 8 ? 4 : v >= 4 ? 3 : v >= 2 ? 2 : v ? 1 : 0; }
  else if (c >= 'a' && c <= 'f') top = 4;
  return (n - 1) * 4 + top;
}
static void mem_apply(void) {
  s_vpi_value v; v.format = vpiHexStrVal;
  s_vpi_error_info e; int bad = -1;
  for (int i = 0; i < nmw; i++) {
    vpiHandle w = vpi_handle_by_index(mem_h, mw[i].idx);
    v.value.str = mw[i].hex;
    vpi_put_value(w, &v, NULL, vpiNoDelay);
    int failed = vpi_chk_error(&e) && e.level >= vpiError;
    vpi_release_handle(w);
    if (failed) { bad = i; break; }
  }
  if (bad >= 0) {
    char m[300]; snprintf(m, sizeof m, "loadmem: the simulator refused the write at index %d (%d of %d written): the build needs write access to this memory", mw[bad].idx, bad, nmw);
    reply_err(mem_id, m);
  } else {
    bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"words\":%d}", mem_id, (unsigned long long)now(), nmw); send_ob();
  }
  mem_clear();
}
static PLI_INT32 mem_rtn(p_cb_data d) {
  (void)d; if (fs_child) return 0;
  mem_apply();
  snprintf(serve_reason, sizeof serve_reason, "write");
  need_serve = 1; sched_ro();
  return 0;
}
/* 1: scheduled (the caller returns to the simulation), 0: answered here */
static int loadmem(long id, const char *path, const char *file, int ctx) {
  mem_clear();
  vpiHandle h = vpi_handle_by_name((PLI_BYTE8 *)path, NULL);
  if (!h) { reply_err(id, "loadmem: no such memory"); return 0; }
  if (!is_array(h)) { reply_err(id, "loadmem: not a memory (an unpacked array of words)"); return 0; }
  int words = vpi_get(vpiSize, h);
  FILE *f = fopen(file, "r");
  if (!f) { reply_err(id, "loadmem: cannot open the packed image"); return 0; }
  char line[70000]; int ln = 0; const char *err = NULL; static char em[300];
  while (!err && fgets(line, sizeof line, f)) {
    ln++;
    char *p = line; while (*p == ' ') p++;
    if (*p == '#' || *p == '\n' || !*p) continue;
    char *e1; long idx = strtol(p, &e1, 10);
    char *hx = e1; while (*hx == ' ') hx++;
    char *end = hx; while (*end && *end != '\n' && *end != ' ') end++; *end = 0;
    if (e1 == p || !*hx) { snprintf(em, sizeof em, "loadmem: packed line %d is malformed", ln); err = em; break; }
    vpiHandle w = vpi_handle_by_index(h, (PLI_INT32)idx);
    if (!w) { snprintf(em, sizeof em, "loadmem: index %ld is outside the memory (%d words)", idx, words); err = em; break; }
    mem_width = vpi_get(vpiSize, w); vpi_release_handle(w);
    if (hex_bits(hx) > mem_width) { snprintf(em, sizeof em, "loadmem: the value at index %ld is wider than the %d-bit word", idx, mem_width); err = em; break; }
    if (nmw == capmw) { capmw = capmw ? capmw * 2 : 1024; mw = realloc(mw, capmw * sizeof *mw); }
    mw[nmw].idx = (int)idx; mw[nmw].hex = strdup(hx); nmw++;
  }
  fclose(f);
  if (err) { mem_clear(); reply_err(id, err); return 0; }
  mem_h = h; mem_id = id;
  if (ctx == CTX_SYSTF) { mem_apply(); return 0; }
  vpiHandle cb = after(1, mem_rtn); if (cb) vpi_release_handle(cb);
  return 1;
}
