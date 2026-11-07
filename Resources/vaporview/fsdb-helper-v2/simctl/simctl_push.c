/* SPDX-License-Identifier: MIT
 * simctl push (included by simctl_vpi.c): transactions streamed over the pipe to a simctl_port, held here in a
 * queue per port name until the port's driver pulls them with $simctl_next (simctl_tb.sv). The queues are
 * the library's memory, so a checkpoint keeps them and a restore brings them back with the simulation; a
 * forksave image carries them too, and a run restored from it (simv -r) still pulls them.
 *
 * B id port n how1 n1 hex1 ... how_n n_n hex_n     queue n transactions (the packed format of tb.js)
 * $simctl_next(NAME, how, n, v, ok)                pop the next one for port NAME: ok = 1 and how/n/v set, or
 *                                                  ok = 0 when that port's queue is empty */
typedef struct { int how; unsigned long long n; char *hex; } push_t;
typedef struct { char *port; push_t *q; int head, len, cap; long long popped; } pushq_t;
static pushq_t *pqs; static int npq;

static pushq_t *pq_get(const char *port, int create) {
  for (int i = 0; i < npq; i++) if (!strcmp(pqs[i].port, port)) return &pqs[i];
  if (!create) return NULL;
  pqs = realloc(pqs, (npq + 1) * sizeof *pqs);
  pushq_t *q = &pqs[npq++]; memset(q, 0, sizeof *q); q->port = strdup(port);
  return q;
}
static int is_hex(const char *s) { if (!*s) return 0; for (; *s; s++) if (!isxdigit((unsigned char)*s)) return 0; return 1; }
static void push_req(long id, char **tok, int nt) {
  if (nt < 4) { reply_err(id, "push: malformed request"); return; }
  long n = strtol(tok[3], NULL, 10);
  if (n < 0 || nt != 4 + 3 * n) { reply_err(id, "push: malformed request"); return; }
  for (long i = 0; i < n; i++) {
    char **t = tok + 4 + 3 * i;
    if ((strcmp(t[0], "0") && strcmp(t[0], "1")) || !is_hex(t[2])) { reply_err(id, "push: malformed transaction"); return; }
  }
  pushq_t *q = pq_get(tok[2], 1);
  if (q->head > 0 && q->head == q->len) { q->head = q->len = 0; }
  if (q->len + n > q->cap) { q->cap = (q->len + n) * 2 + 16; q->q = realloc(q->q, q->cap * sizeof *q->q); }
  for (long i = 0; i < n; i++) {
    char **t = tok + 4 + 3 * i;
    push_t *p = &q->q[q->len++];
    p->how = atoi(t[0]); p->n = strtoull(t[1], NULL, 10); p->hex = strdup(t[2]);
  }
  bfmt(&ob, "{\"id\":%ld,\"t\":%llu,\"port\":", id, (unsigned long long)now()); bjson(&ob, tok[2]);
  bfmt(&ob, ",\"queued\":%d,\"pulled\":%lld}", q->len - q->head, q->popped); send_ob();
}
static void put_int(vpiHandle h, int v) { s_vpi_value x; x.format = vpiIntVal; x.value.integer = v; vpi_put_value(h, &x, NULL, vpiNoDelay); }
static void put_hex(vpiHandle h, const char *hx) { s_vpi_value x; x.format = vpiHexStrVal; x.value.str = (PLI_BYTE8 *)hx; vpi_put_value(h, &x, NULL, vpiNoDelay); }
/* Served everywhere, also in a save child and in a run restored from a forksave (whose library is otherwise inert):
 * it only reads the queues in this process's memory and sets the caller's arguments, so the child's step and a
 * restored run drive exactly what the parent would (re-review 3, M-p2). */
PLI_INT32 simctl_next_calltf(PLI_BYTE8 *ud) { (void)ud;
  vpiHandle call = vpi_handle(vpiSysTfCall, NULL), it = call ? vpi_iterate(vpiArgument, call) : NULL, a[5] = { 0 };
  int k = 0;
  if (it) { while (k < 5 && (a[k] = vpi_scan(it))) k++; if (k == 5) vpi_release_handle(it); }
  if (k < 5) return 0;
  s_vpi_value nm; nm.format = vpiStringVal; vpi_get_value(a[0], &nm);
  pushq_t *q = nm.value.str ? pq_get(nm.value.str, 0) : NULL;
  if (!q || q->head == q->len) { put_int(a[4], 0); return 0; }
  push_t *p = &q->q[q->head++]; q->popped++;
  char nb[24]; snprintf(nb, sizeof nb, "%llx", p->n);
  put_int(a[1], p->how); put_hex(a[2], nb); put_hex(a[3], p->hex); put_int(a[4], 1);
  free(p->hex); p->hex = NULL;
  return 0;
}
