/* SPDX-License-Identifier: MIT
 * simctl describe: what a build lets an agent drive without a rebuild. Included by simctl_vpi.c (one unit).
 *
 * `H id` (served when idle): walks the design's instances (modules and generate scopes) and reports every
 * simctl_cfg and simctl_port of simctl_tb.sv with its parameters:
 *   {id, t, cfg: [{path, scenarios}], ports: [{path, name, kind, width, fields}], memories: [{path, words, width}],
 *    memoriesTruncated}
 * memories: the unpacked arrays of words (vpiMemory / vpiRegArray) in module scopes, at most DESCRIBE_MEMS; the
 * ones loadmem can write (if the build gives write access).
 * The walk stops at a simctl_* instance (they have no simctl_* inside). Only documented VPI: vpiInternalScope
 * iteration, vpiDefName, vpiParameter values. */

static vpiHandle param_of(vpiHandle inst, const char *name) {
  vpiHandle it = vpi_iterate(vpiParameter, inst), p, found = NULL;
  while (it && (p = vpi_scan(it))) {
    const char *n = vpi_get_str(vpiName, p);
    if (!found && n && !strcmp(n, name)) found = p; else vpi_release_handle(p);
  }
  return found;   /* vpi_scan released the iterator at its end */
}
static void param_str(vpiHandle inst, const char *name) {
  vpiHandle p = param_of(inst, name);
  if (!p) { bstr(&ob, "null"); return; }
  s_vpi_value v; v.format = vpiStringVal; vpi_get_value(p, &v);
  bjson(&ob, v.value.str ? v.value.str : ""); vpi_release_handle(p);
}
static void param_int(vpiHandle inst, const char *name) {
  vpiHandle p = param_of(inst, name);
  if (!p) { bstr(&ob, "null"); return; }
  s_vpi_value v; v.format = vpiIntVal; vpi_get_value(p, &v);
  bfmt(&ob, "%d", (int)v.value.integer); vpi_release_handle(p);
}

static buf_t d_cfg, d_ports, d_mems; static int n_cfg, n_ports, n_mems, mems_trunc;
#define DESCRIBE_MEMS 500
/* an unpacked array of words: vpiMemory (Verilog), vpiRegArray, or SV's array variable */
static int is_mem(vpiHandle h) {
  int ty = vpi_get(vpiType, h);
  return ty == vpiMemory || ty == vpiRegArray
#ifdef vpiArrayVar
    || ty == vpiArrayVar
#endif
    ;
}
static int word_width(vpiHandle m) {
  int width = 0;
  vpiHandle l = vpi_handle(vpiLeftRange, m);
  if (l) {
    s_vpi_value v; v.format = vpiIntVal; vpi_get_value(l, &v); vpi_release_handle(l);
    vpiHandle w = vpi_handle_by_index(m, v.value.integer);
    if (w) { width = vpi_get(vpiSize, w); vpi_release_handle(w); }
  }
  return width;
}
static void describe_mems(vpiHandle scope) {
  static const int types[] = { vpiVariables, vpiMemory, vpiRegArray };
  for (int k = 0; k < 3; k++) {
    vpiHandle it = vpi_iterate(types[k], scope), m;
    while (it && (m = vpi_scan(it))) {
      if (!is_mem(m)) { vpi_release_handle(m); continue; }
      const char *name = vpi_get_str(vpiFullName, m);
      char key[1200]; snprintf(key, sizeof key, "{\"path\":\"%s\",", name ? name : "");
      int seen = 0;   /* the same array from two iterations */
      if (d_mems.n) { bput(&d_mems, "", 1); seen = strstr(d_mems.p, key) != NULL; d_mems.n--; }
      if (seen) { vpi_release_handle(m); continue; }
      if (n_mems >= DESCRIBE_MEMS) { mems_trunc = 1; vpi_release_handle(m); continue; }
      int words = vpi_get(vpiSize, m), width = word_width(m);
      buf_t save = ob; ob = d_mems;
      bstr(&ob, n_mems++ ? "," : ""); bstr(&ob, "{\"path\":"); bjson(&ob, name ? name : "");
      bfmt(&ob, ",\"words\":%d,\"width\":%d}", words, width);
      d_mems = ob; ob = save;
      vpi_release_handle(m);
    }
  }
}
static void describe_walk(vpiHandle scope) {
  vpiHandle it = vpi_iterate(vpiInternalScope, scope), h;
  while (it && (h = vpi_scan(it))) {
    int ty = vpi_get(vpiType, h);
    const char *def = ty == vpiModule ? vpi_get_str(vpiDefName, h) : NULL;
    if (def && !strcmp(def, "simctl_cfg")) {
      buf_t save = ob; ob = d_cfg;
      bstr(&ob, n_cfg++ ? ",{\"path\":" : "{\"path\":"); bjson(&ob, vpi_get_str(vpiFullName, h));
      bstr(&ob, ",\"scenarios\":"); param_str(h, "SCENARIOS"); bstr(&ob, "}");
      d_cfg = ob; ob = save;
    } else if (def && !strcmp(def, "simctl_port")) {
      buf_t save = ob; ob = d_ports;
      bstr(&ob, n_ports++ ? ",{\"path\":" : "{\"path\":"); bjson(&ob, vpi_get_str(vpiFullName, h));
      bstr(&ob, ",\"name\":"); param_str(h, "NAME");
      bstr(&ob, ",\"kind\":"); param_str(h, "KIND");
      bstr(&ob, ",\"width\":"); param_int(h, "W");
      bstr(&ob, ",\"fields\":"); param_str(h, "FIELDS"); bstr(&ob, "}");
      d_ports = ob; ob = save;
    } else if (ty == vpiModule || ty == vpiGenScope) {
      if (ty == vpiModule) describe_mems(h);
      describe_walk(h);
    }
    vpi_release_handle(h);
  }
}
static void describe(long id, uint64_t t) {
  d_cfg.n = 0; d_ports.n = 0; d_mems.n = 0; n_cfg = n_ports = n_mems = mems_trunc = 0;
  vpiHandle it = vpi_iterate(vpiModule, NULL), top;
  while (it && (top = vpi_scan(it))) {
    const char *def = vpi_get_str(vpiDefName, top);
    if (def && strncmp(def, "simctl_", 7)) { describe_mems(top); describe_walk(top); }   /* simctl_saver: nothing inside */
    vpi_release_handle(top);
  }
  bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"cfg\":[", id, (unsigned long long)t);
  if (d_cfg.n) bput(&ob, d_cfg.p, d_cfg.n);
  bstr(&ob, "],\"ports\":[");
  if (d_ports.n) bput(&ob, d_ports.p, d_ports.n);
  bstr(&ob, "],\"memories\":[");
  if (d_mems.n) bput(&ob, d_mems.p, d_mems.n);
  bfmt(&ob, "],\"memoriesTruncated\":%s}", mems_trunc ? "true" : "false");
  send_ob();
}
