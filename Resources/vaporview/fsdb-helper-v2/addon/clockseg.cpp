// Part of cmux's FSDB helper v2. GPL-3.0, as VaporView (see ../../LICENSE).
// clockseg: one segment of a clock descriptor's verify (helper.js "clock descriptors"), as its own
// short-lived native process. On a rebuilt row the reader keeps about 9 B per change read for the
// life of its process (not freed by unload or a reopen), so a whole-history verify is split into
// segments, each a fresh process; a native one, since the reader's open of a 10 GB dump alone is
// ~185 MB and a Node.js worker adds ~66 MB more.
//
//   clockseg <fsdb> <id> <P> <H> <R0> <maxRecords> <a> <b> [<a> <b> ...]
//
// One JSON line per range [a, b), in order, then exits. The row's normalized changes (the last
// change per time wins, repeats dropped, all x before the first change) at times in [a, b) are
// checked against the grid: rises at R0 + kP, falls H later.
//   {vBefore, changes, edges, intervals: [[s, e | -1, [[t, v], ...]], ...], rssMB, openMB}
// (rssMB: the process's RSS now; openMB: right after the open, before any load)
// vBefore is the value in effect just before a. Where the row leaves the grid (a change off it, a
// wrong value such as x or z, or a grid edge that never comes) an interval [s, e) opens and holds
// its changes verbatim, until a change lands back on the grid with the grid's value (e). Before
// R0 everything is verbatim; an interval still open at b has e = -1. More than maxRecords
// verbatim changes in all the ranges stops: {over: true, changes, records}. Values are the
// reader's own: "0" "1" "x" "z".
// P = 0 fits instead, over the first range: {period, high, firstRise, rises, changes} from the
// first 65 rises (the most common rise-to-rise and rise-to-fall distances; period 0: fewer
// than 3 rises). Errors: {error}.
#include "ffrAPI.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <utility>
#include <vector>
#include <unistd.h>

static long rssMB() { std::ifstream f("/proc/self/statm"); long a = 0, b = 0; f >> a >> b; return b * sysconf(_SC_PAGESIZE) / 1048576; }
static uint64_t tg(const fsdbTag64 &t) { return ((uint64_t)t.H << 32) | t.L; }
static void setTag(fsdbTag64 &t, uint64_t v) { t.H = (uint_T)(v >> 32); t.L = (uint_T)(v & 0xffffffff); }
static void setWin(ffrObject *o, uint64_t a, uint64_t b) {
  fsdbTag64 x, y; setTag(x, a); setTag(y, b);
  if (o->ffrIsViewWindowSet()) o->ffrResetViewWindow((fsdbXTag *)&x, (fsdbXTag *)&y);
  else o->ffrSetViewWindow((fsdbXTag *)&x, (fsdbXTag *)&y);
}
static FILE *J = stdout;  // the JSON lines (the reader prints its banner to stdout: that goes to stderr)
static const char CH[4] = {'0', '1', 'x', 'z'};
static void fail(const char *m) { fprintf(J, "{\"error\":\"%s\"}\n", m); fflush(J); }

int main(int argc, char **argv) {
  if (argc < 9 || (argc - 7) % 2) { fprintf(stderr, "usage: clockseg <fsdb> <id> <P> <H> <R0> <maxRecords> <a> <b> [<a> <b> ...]\n"); return 2; }
  const fsdbVarIdcode id = (fsdbVarIdcode)atoll(argv[2]);
  const uint64_t P = strtoull(argv[3], 0, 10), H = strtoull(argv[4], 0, 10), R0 = strtoull(argv[5], 0, 10);
  const double maxRec = atof(argv[6]);
  if (P && (H == 0 || H >= P)) { fail("bad grid"); return 1; }
  { const int fd = dup(1); if (fd >= 0 && dup2(2, 1) >= 0) { FILE *f = fdopen(fd, "w"); if (f) J = f; } }
  ffrObject *o = ffrObject::ffrOpen3(argv[1]);
  if (!o) { fail("open failed"); return 1; }
  o->ffrReadScopeVarTree();  // (a rebuilt row needs it)
  const long openMB = rssMB();  // (the baseline: the open alone, before any load)
  fsdbTag64 mx; o->ffrGetMaxFsdbTag64(&mx);
  const uint64_t fileEnd = tg(mx);
  double records = 0;
  for (int r = 7; r + 1 < argc; r += 2) {
    const uint64_t a = strtoull(argv[r], 0, 10), b = strtoull(argv[r + 1], 0, 10);
    if (b <= a) { fail("empty range"); return 1; }
    setWin(o, a > 0 ? a - 1 : 0, std::min(b, fileEnd));
    o->ffrAddToSignalList(id); o->ffrLoadSignals(); o->ffrResetSignalList();
    ffrVCTrvsHdl h = o->ffrCreateVCTrvsHdl(id);
    if (!h) { fail("no traverse handle"); return 1; }
    if (h->ffrGetBytesPerBit() != FSDB_BYTES_PER_BIT_1B || h->ffrGetBitSize() != 1) { fail("clock: a 1-bit signal only"); return 1; }
    int vBefore = 2;
    // The normalized stream: f(t, v) for each change at t in [a, b); vBefore from those before a.
    auto walk = [&](auto &&f) {
      if (!h->ffrHasIncoreVC()) return;
      fsdbTag64 tag, at;
      h->ffrGetMinXTag((void *)&tag); h->ffrGotoXTag((void *)&tag);
      int prev = 2, cur = -1; uint64_t ct = 0; bool have = false, more = true;
      auto flush = [&]() {
        if (!have || cur == prev) return true;
        if (ct < a) { prev = cur; vBefore = cur; return true; }
        if (ct >= b) return false;
        prev = cur;
        return f(ct, cur);
      };
      while (more) {
        h->ffrGetXTag(&at);
        const uint64_t tt = tg(at);
        if (have && tt != ct) { if (!flush()) { have = false; break; } }
        byte_T *vc; h->ffrGetVC(&vc);
        cur = vc[0] & 3; ct = tt; have = true;
        more = FSDB_RC_SUCCESS == h->ffrGotoNextVC();
      }
      if (have) flush();
    };
    double changes = 0;
    if (!P) {
      std::vector<uint64_t> rs, fs;
      int last = -1;
      walk([&](uint64_t t, int v) {
        changes++;
        if (v == 1 && last == 0) rs.push_back(t);
        if (v == 0 && last == 1 && !rs.empty()) fs.push_back(t);
        last = v;
        return rs.size() < 65;
      });
      h->ffrFree(); o->ffrUnloadSignals(id);
      std::map<uint64_t, int> pc, hc;
      for (size_t k = 1; k < rs.size(); k++) pc[rs[k] - rs[k - 1]]++;
      uint64_t per = 0, hi = 0; int best = 0;
      for (auto &e : pc) if (e.second > best) { best = e.second; per = e.first; }
      size_t j = 0;
      for (auto x : rs) { while (j < fs.size() && fs[j] <= x) j++; if (j < fs.size() && per && fs[j] - x < per) hc[fs[j] - x]++; }
      best = 0; for (auto &e : hc) if (e.second > best) { best = e.second; hi = e.first; }
      uint64_t first = 0;  // the first rise from which the next one is a period later
      for (size_t k = 0; k + 1 < rs.size(); k++) if (rs[k + 1] - rs[k] == per) { first = rs[k]; break; }
      fprintf(J, "{\"period\":%llu,\"high\":%llu,\"firstRise\":%llu,\"rises\":%zu,\"changes\":%.0f,\"rssMB\":%ld,\"openMB\":%ld}\n",
             (unsigned long long)(rs.size() >= 3 ? per : 0), (unsigned long long)hi, (unsigned long long)first, rs.size(), changes, rssMB(), openMB);
      fflush(J);
      continue;
    }
    auto g = [&](uint64_t t) -> int { return t < R0 ? 0 : ((t - R0) % P) < H ? 1 : 0; };  // the grid's value at t
    auto nextEdge = [&](uint64_t t) -> uint64_t {  // the first grid edge after t
      if (t < R0) return R0;
      const uint64_t base = t - (t - R0) % P;
      return t - base < H ? base + H : base + P;
    };
    auto onEdge = [&](uint64_t t) { return t >= R0 && ((t - R0) % P == 0 || (t - R0) % P == H); };
    std::string ivs;
    double edges = 0;
    bool inSync = false, over = false, started = false;
    uint64_t expE = 0, ivS = 0;
    std::vector<std::pair<uint64_t, int>> rec;
    auto open = [&](uint64_t s0) { inSync = false; ivS = s0; rec.clear(); };
    auto close = [&](long long e) {
      char buf[64];
      snprintf(buf, sizeof buf, "%s[%llu,%lld,[", ivs.empty() ? "" : ",", (unsigned long long)ivS, e);
      ivs += buf;
      for (size_t k = 0; k < rec.size(); k++) {
        snprintf(buf, sizeof buf, "%s[%llu,\"%c\"]", k ? "," : "", (unsigned long long)rec[k].first, CH[rec[k].second]);
        ivs += buf;
      }
      ivs += "]]";
      rec.clear();
    };
    auto begin = [&]() {  // (the state at a, from the value in effect before it)
      started = true;
      const int gb = a == 0 || a - 1 < R0 ? 0 : g(a - 1);
      if (a >= R0 && vBefore == gb) { inSync = true; expE = nextEdge(a - 1); } else open(a);
    };
    walk([&](uint64_t t, int v) {
      if (!started) begin();
      changes++;
      if (inSync) {
        if (t == expE && v == g(t)) { edges++; expE = nextEdge(t); return true; }
        open(std::min(t, expE));
      }
      if (onEdge(t) && v == g(t)) { close((long long)t); inSync = true; edges++; expE = nextEdge(t); return true; }
      rec.push_back({t, v});
      if (++records > maxRec) { over = true; return false; }
      return true;
    });
    h->ffrFree(); o->ffrUnloadSignals(id);
    if (!started) begin();  // (no change in [a, b))
    if (over) { fprintf(J, "{\"over\":true,\"changes\":%.0f,\"records\":%.0f,\"rssMB\":%ld,\"openMB\":%ld}\n", changes, records, rssMB(), openMB); fflush(J); return 0; }
    if (inSync && expE < b) open(expE);  // (grid edges that never came, up to b)
    if (!inSync) close(-1);
    fprintf(J, "{\"vBefore\":\"%c\",\"changes\":%.0f,\"edges\":%.0f,\"intervals\":[%s],\"rssMB\":%ld,\"openMB\":%ld}\n", CH[vBefore], changes, edges, ivs.c_str(), rssMB(), openMB);
    fflush(J);
  }
  o->ffrClose();
  return 0;
}
