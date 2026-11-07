// Part of cmux's FSDB helper v2, written for cmux. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), whose addon it extends; see ../../LICENSE.
// ---- cmux additions (helper v2): per-signal compact store + window queries ----
#include <unistd.h>
#include <cstdint>
//
// After one walk through the reader a signal lives here as sorted u64 times
// plus bit-packed values: a value plane (bit = vc & 1) and, only when some
// change holds x or z, an x/z plane (bit = vc >> 1). With FSDB_BT_VCD_0..Z =
// 0..3 the pair (val, xz) is 0=(0,0) 1=(1,0) x=(0,1) z=(1,1). Bit i of a change
// is character i of the value string the old exports return.
//
// Ranges (agreed with the viewer): the value in effect at t is the last change
// with time <= t. A window is half-open [t0, t1): `count` and the bucket counts
// include changes exactly at t0, but those are folded into the initial t0
// record rather than sent as records. A change at time t is in bucket
// floor((t - t0) * B / (t1 - t0)).

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstring>
#include <unordered_map>
#include <unordered_set>
#include <csignal>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdint>
#include <zlib.h>

// Value kinds. Bit vectors (1 byte per bit in the reader) are the planes above. The other
// kinds hold one fixed-size key per change in `val` and are answered as text, the way
// VaporView shows a VCD's string and real variables (wellen): kReal is the IEEE double
// (stride 8; a 4-byte float is widened and remembered in f32 so it prints as a float),
// kString is a u32 index into `strs` (stride 4), interned per store, so equal strings
// have equal keys and normalization, distinct values and edges work on the keys.
enum : uint8_t { kBits = 0, kReal = 1, kString = 2 };

struct SigStore {
  uint32_t bits = 0;
  uint32_t stride = 0;  // bytes per change in each plane
  uint8_t kind = kBits;
  bool f32 = false;      // kReal read from a 4-byte float
  bool repeats = false;  // events: a change to the same value is still a change
  std::vector<uint64_t> times;
  std::vector<uint8_t> val;
  std::vector<uint8_t> xz;  // empty unless some change holds x or z
  std::vector<std::string> strs;  // kString: the distinct strings
  size_t strBytes = 0;            // their characters plus per-string overhead (in bytes())
  double rmin = 0, rmax = 0;      // kReal: as wellen's (min/max of 0 and every finite value)
  double textMean = 0;            // kString: mean bytes per change of the text as windows send it
  uint64_t lastUsed = 0;
  // searchText: each change's index into the signal's distinct values (built on first
  // use, accounted in bytes(); dgen names this table, so JS memos keyed on it go stale
  // when the store is rebuilt). dfirst[d] = the first change holding distinct value d.
  std::vector<uint32_t> vidx, dfirst;
  uint64_t dgen = 0;
  size_t bytes() const { return times.capacity() * 8 + val.capacity() + xz.capacity() + (vidx.capacity() + dfirst.capacity()) * 4 + strBytes + strs.capacity() * sizeof(std::string) + sizeof(SigStore); }
};
static const char *kindName(uint8_t k) { return k == kReal ? "real" : k == kString ? "string" : "bits"; }

static std::unordered_map<int64_t, SigStore *> g_store;
static uint64_t g_clock = 0;
static size_t g_bytes = 0;
static size_t g_limit = (size_t)1 << 30;

static inline int64_t argI64(const Napi::Value &v) { return v.As<Napi::Number>().Int64Value(); }

// ---- background work that yields ----
// Background tasks (searchAll chunks, index warm-up) run between bgBegin()
// and bgEnd(). The coordinator sends SIGUSR2 when interactive work arrives
// for a busy worker; walks and scans check the flag every 4096 changes and
// between signals, stop, and report what they didn't finish as yielded.
// (Node leaves SIGUSR2 alone unless JS listens for it; SIGUSR1 is its debugger.)
static volatile sig_atomic_t g_yield = 0;
static bool g_bg = false;
static double g_bgDeadline = 0;  // steady-clock ms; 0 = none
static void onYieldSignal(int) { g_yield = 1; }
static double nowMs() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static inline bool bgStop() { return g_bg && (g_yield || (g_bgDeadline > 0 && nowMs() > g_bgDeadline)); }

// bgBegin(deadlineInMs = 0, keepYield = false): enter background mode. Resets the yield
// flag unless keepYield (a stoppable task that cleared it with bgEnd() at its start keeps a
// SIGUSR2 that arrived during its load).
Napi::Value bgBegin(const Napi::CallbackInfo &info) {
  static bool installed = false;
  if (!installed) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = onYieldSignal;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGUSR2, &sa, nullptr);
    installed = true;
  }
  if (!(info.Length() > 1 && info[1].ToBoolean().Value())) g_yield = 0;
  g_bg = true;
  const double in = info.Length() > 0 && info[0].IsNumber() ? info[0].As<Napi::Number>().DoubleValue() : 0;
  g_bgDeadline = in > 0 ? nowMs() + in : 0;
  return info.Env().Undefined();
}
// bgEnd() -> true if the task was asked to yield (or ran out of time).
Napi::Value bgEnd(const Napi::CallbackInfo &info) {
  const bool stopped = bgStop();
  g_bg = false;
  g_yield = 0;
  g_bgDeadline = 0;
  return Napi::Boolean::New(info.Env(), stopped);
}

// bgPoll() -> true if the running task was asked to stop (SIGUSR2) or ran out of time;
// for stoppable interactive work (searchText rounds) that polls between values.
Napi::Value bgPoll(const Napi::CallbackInfo &info) { return Napi::Boolean::New(info.Env(), bgStop()); }

// ---- store files (split-walk slices, derived operands) ----
// Handed between this helper's own workers through a private 0700 directory.
// Layout: "VVS2", u32 bits, u64 n, u8 hasXz, n u64 times, n*stride value bytes,
// then n*stride x/z bytes if hasXz. Created O_EXCL 0600; a reader accepts only
// a regular file owned by this user whose size matches its header and whose
// times are sorted, and deletes it.
static const char kStoreMagic[4] = {'V', 'V', 'S', '2'};
static const uint32_t kMaxBits = 1u << 20;

static bool writeFull(int fd, const void *p, size_t len) {
  const uint8_t *b = (const uint8_t *)p;
  while (len) {
    const ssize_t w = ::write(fd, b, len);
    if (w < 0) { if (errno == EINTR) continue; return false; }
    b += w; len -= (size_t)w;
  }
  return true;
}
static bool readFull(int fd, void *p, size_t len) {
  uint8_t *b = (uint8_t *)p;
  while (len) {
    const ssize_t r = ::read(fd, b, len);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) return false;
    b += r; len -= (size_t)r;
  }
  return true;
}

static bool writeStoreFile(const SigStore *s, const std::string &p) {
  const int fd = ::open(p.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) return false;
  const uint64_t n = s->times.size();
  const uint8_t hasXz = !s->xz.empty();
  bool ok = writeFull(fd, kStoreMagic, 4) && writeFull(fd, &s->bits, 4) && writeFull(fd, &n, 8) && writeFull(fd, &hasXz, 1)
         && writeFull(fd, s->times.data(), n * 8) && writeFull(fd, s->val.data(), s->val.size())
         && (!hasXz || writeFull(fd, s->xz.data(), s->xz.size()));
  ok = (::close(fd) == 0) && ok;
  if (!ok) ::unlink(p.c_str());
  return ok;
}

static SigStore *readStoreFile(const std::string &p, std::string &err, bool consume = true) {
  const int fd = ::open(p.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) { err = "cannot read " + p; return nullptr; }
  struct stat st;
  char magic[4];
  uint32_t bits = 0;
  uint64_t n = 0;
  uint8_t hasXz = 0;
  bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == geteuid() && st.st_nlink == 1
         && readFull(fd, magic, 4) && memcmp(magic, kStoreMagic, 4) == 0
         && readFull(fd, &bits, 4) && readFull(fd, &n, 8) && readFull(fd, &hasXz, 1)
         && bits >= 1 && bits <= kMaxBits && hasXz <= 1;
  const uint64_t size = ok ? (uint64_t)st.st_size : 0;
  const uint64_t stride = (bits + 7) / 8;
  const uint64_t perChange = 8 + stride * (hasXz ? 2 : 1);
  ok = ok && size >= 17 && n <= (size - 17) / perChange && 17 + n * perChange == size;
  SigStore *s = nullptr;
  if (ok) {
    s = new SigStore();
    s->bits = bits;
    s->stride = (uint32_t)stride;
    s->times.resize(n);
    s->val.resize(n * stride);
    ok = readFull(fd, s->times.data(), n * 8) && readFull(fd, s->val.data(), s->val.size());
    if (ok && hasXz) { s->xz.resize(n * stride); ok = readFull(fd, s->xz.data(), s->xz.size()); }
    for (uint64_t k = 1; ok && k < n; k++) ok = s->times[k - 1] <= s->times[k];
  }
  ::close(fd);
  if (consume) ::unlink(p.c_str());  // hand-off files are read once; index files stay
  if (!ok) { delete s; err = "bad store file " + p; return nullptr; }
  return s;
}

// Search-index files (warm-up), "VVZ1": u32 bits, u64 n, u8 hasXz, u64 raw
// length, u64 compressed length, then deflate (level 1) of n u64 time deltas,
// the value plane and the x/z plane. Written and read in 256 KB pieces, so no
// extra copy of the signal is made; read with the same checks as store files
// (ours, one link, exact size, sorted times) plus deflate's own integrity.
static const char kIndexMagic[4] = {'V', 'V', 'Z', '1'};
static const size_t kZChunk = 256 << 10;

// With yieldable, a background task's yield (bgStop) abandons the write between
// 256 KB chunks (*yielded set, the file removed): spike_rvfi's ~240 ms write
// never holds up interactive work by more than a chunk.
static bool writeIndexFile(const SigStore *s, const std::string &p, uint64_t &fileBytes, bool *yielded = nullptr) {
  const int fd = ::open(p.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) return false;
  const uint64_t n = s->times.size();
  const uint8_t hasXz = !s->xz.empty();
  const uint64_t raw = n * 8 + s->val.size() + s->xz.size();
  uint64_t zlen = 0;
  bool ok = writeFull(fd, kIndexMagic, 4) && writeFull(fd, &s->bits, 4) && writeFull(fd, &n, 8) && writeFull(fd, &hasXz, 1)
         && writeFull(fd, &raw, 8) && writeFull(fd, &zlen, 8);
  z_stream z;
  memset(&z, 0, sizeof z);
  ok = ok && deflateInit(&z, 1) == Z_OK;
  std::vector<uint8_t> out(kZChunk);
  std::vector<uint64_t> deltas;
  auto pump = [&](const uint8_t *in, size_t len, int flush) {
    z.next_in = (Bytef *)in;
    z.avail_in = (uInt)len;
    do {
      z.next_out = out.data();
      z.avail_out = (uInt)out.size();
      const int rc = deflate(&z, flush);
      if (rc == Z_STREAM_ERROR) return false;
      const size_t got = out.size() - z.avail_out;
      if (got && !writeFull(fd, out.data(), got)) return false;
      zlen += got;
    } while (z.avail_out == 0 || z.avail_in > 0);
    if (yielded && bgStop()) { *yielded = true; return false; }
    return true;
  };
  uint64_t prev = 0;
  for (uint64_t k = 0; ok && k < n; k += kZChunk / 8) {
    const uint64_t m = std::min<uint64_t>(n - k, kZChunk / 8);
    deltas.resize(m);
    for (uint64_t j = 0; j < m; j++) { deltas[j] = s->times[k + j] - prev; prev = s->times[k + j]; }
    ok = pump((const uint8_t *)deltas.data(), m * 8, Z_NO_FLUSH);
  }
  for (size_t k = 0; ok && k < s->val.size(); k += kZChunk) ok = pump(&s->val[k], std::min(kZChunk, s->val.size() - k), Z_NO_FLUSH);
  for (size_t k = 0; ok && k < s->xz.size(); k += kZChunk) ok = pump(&s->xz[k], std::min(kZChunk, s->xz.size() - k), Z_NO_FLUSH);
  ok = ok && pump(nullptr, 0, Z_FINISH);
  deflateEnd(&z);
  ok = ok && ::pwrite(fd, &zlen, 8, 25) == 8;
  ok = (::close(fd) == 0) && ok;
  if (!ok) ::unlink(p.c_str());
  fileBytes = 33 + zlen;
  return ok;
}

// With cap > 0 a file whose store would be larger is refused from its header,
// before anything is allocated (*tooLarge set; the file is fine, just too big here).
// Errors starting "bad index file" mean the file is corrupt.
static SigStore *readIndexFile(const std::string &p, std::string &err, size_t cap = 0, bool *tooLarge = nullptr) {
  const int fd = ::open(p.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) { err = "cannot read " + p; return nullptr; }
  struct stat st;
  char magic[4];
  uint32_t bits = 0;
  uint64_t n = 0, raw = 0, zlen = 0;
  uint8_t hasXz = 0;
  bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == geteuid() && st.st_nlink == 1
         && readFull(fd, magic, 4) && memcmp(magic, kIndexMagic, 4) == 0
         && readFull(fd, &bits, 4) && readFull(fd, &n, 8) && readFull(fd, &hasXz, 1)
         && readFull(fd, &raw, 8) && readFull(fd, &zlen, 8)
         && bits >= 1 && bits <= kMaxBits && hasXz <= 1 && (uint64_t)st.st_size == 33 + zlen;
  const uint64_t stride = (bits + 7) / 8;
  const uint64_t perChange = 8 + stride * (hasXz ? 2 : 1);
  // deflate expands at most ~1032:1, so a header claiming more is corrupt (and
  // would make us allocate it).
  ok = ok && n <= raw / perChange && raw == n * perChange && raw <= 1032 * zlen + 1024;
  if (ok && cap && n * perChange > cap) {
    ::close(fd);
    if (tooLarge) *tooLarge = true;
    err = "signal larger than " + std::to_string(cap >> 20) + " MB (worker store limit)";
    return nullptr;
  }
  SigStore *s = nullptr;
  z_stream z;
  memset(&z, 0, sizeof z);
  bool zinit = false;
  if (ok) {
    s = new SigStore();
    s->bits = bits;
    s->stride = (uint32_t)stride;
    s->times.resize(n);
    s->val.resize(n * stride);
    if (hasXz) s->xz.resize(n * stride);
    ok = zinit = inflateInit(&z) == Z_OK;
    std::vector<uint8_t> in(kZChunk);
    uint64_t left = zlen;
    int rc = Z_OK;
    std::pair<uint8_t *, size_t> parts[3] = {{(uint8_t *)s->times.data(), n * 8}, {s->val.data(), s->val.size()}, {s->xz.data(), s->xz.size()}};
    for (auto &part : parts) {
      z.next_out = part.first;
      z.avail_out = (uInt)0;
      size_t outLeft = part.second;
      while (ok && outLeft > 0) {
        if (z.avail_in == 0 && left > 0) {
          const size_t m = (size_t)std::min<uint64_t>(left, in.size());
          ok = readFull(fd, in.data(), m);
          left -= m;
          z.next_in = in.data();
          z.avail_in = (uInt)m;
        }
        const uInt give = (uInt)std::min<size_t>(outLeft, 1u << 30);
        z.avail_out = give;
        rc = inflate(&z, Z_NO_FLUSH);
        outLeft -= give - z.avail_out;
        if (rc == Z_STREAM_END ? outLeft > 0 : rc != Z_OK && !(rc == Z_BUF_ERROR && (z.avail_in > 0 || left > 0))) ok = false;
      }
    }
    // Everything must have been used, and the stream must end exactly here.
    if (ok && rc != Z_STREAM_END) {
      uint8_t extra;
      z.next_out = &extra;
      z.avail_out = 1;
      if (z.avail_in == 0 && left > 0) { const size_t m = (size_t)std::min<uint64_t>(left, in.size()); ok = readFull(fd, in.data(), m); left -= m; z.next_in = in.data(); z.avail_in = (uInt)m; }
      rc = ok ? inflate(&z, Z_FINISH) : rc;
      ok = ok && rc == Z_STREAM_END && z.avail_out == 1;
    }
    ok = ok && z.avail_in == 0 && left == 0;
    uint64_t t = 0;
    for (uint64_t k = 0; ok && k < n; k++) { const uint64_t d = s->times[k]; ok = t + d >= t; t += d; s->times[k] = t; }
  }
  if (zinit) inflateEnd(&z);
  ::close(fd);
  if (!ok) { delete s; err = "bad index file " + p; return nullptr; }
  return s;
}

static inline uint64_t argTime(const Napi::Value &v) {
  const double d = v.As<Napi::Number>().DoubleValue();
  if (!(d > 0)) return 0;  // also NaN
  if (d >= 18446744073709551615.0) return UINT64_MAX;
  return (uint64_t)d;
}

static void storeFree(int64_t id) {
  auto it = g_store.find(id);
  if (it == g_store.end()) return;
  g_bytes -= it->second->bytes();
  delete it->second;
  g_store.erase(it);
}

// Evict least recently used signals until under the limit, keeping `keep`.
// Real signals go first: one is re-walked in ~0.3 s, while a derived result
// (id >= 1e9) costs its operands' walks plus the merge to rebuild.
static void storeEvict(const std::vector<int64_t> &keep) {
  while (g_bytes > g_limit) {
    int64_t victim = 0;
    uint64_t oldest = UINT64_MAX;
    bool found = false, foundReal = false;
    for (auto &kv : g_store) {
      if (std::find(keep.begin(), keep.end(), kv.first) != keep.end()) continue;
      const bool real = kv.first < 1000000000;
      if ((real && !foundReal) || (real == foundReal && kv.second->lastUsed < oldest)) {
        oldest = kv.second->lastUsed; victim = kv.first; found = true; foundReal = real;
      }
    }
    if (!found) return;
    storeFree(victim);
  }
}

static SigStore *storeGet(const Napi::Env &env, const Napi::Value &v) {
  auto it = g_store.find(argI64(v));
  if (it == g_store.end()) {
    Napi::Error::New(env, "signal not loaded").ThrowAsJavaScriptException();
    return nullptr;
  }
  it->second->lastUsed = ++g_clock;
  return it->second;
}

// Bit 0 of each of 8 little-endian bytes -> one byte (byte i -> bit i).
static inline uint8_t packLow(uint64_t w) {
  return (uint8_t)(((w & 0x0101010101010101ull) * 0x0102040810204080ull) >> 56);
}

// The normalized change stream every answer uses: changes at one time collapse to the last one, a change to
// the value already in effect is dropped, and with initialX the value before
// the first change is all x (so a first change to all x is dropped too). Events (repeats)
// keep a change to the same value: each one is an occurrence.
// In place; also drops the x/z plane if nothing left in it is x or z.
static void normalizeStore(SigStore *s, bool initialX) {
  const size_t n = s->times.size(), st = s->stride;
  if (n == 0 || st == 0) return;
  const bool hasXz = !s->xz.empty();
  std::vector<uint8_t> allX(st, 0);
  for (uint32_t i = 0; i < s->bits; i++) allX[i >> 3] |= (uint8_t)(1 << (i & 7));
  auto same = [&](size_t a, size_t b) {  // b == SIZE_MAX: the initial all-x value
    if (b == SIZE_MAX) {
      if (!hasXz) return false;
      for (size_t j = 0; j < st; j++) if (s->val[a * st + j] || s->xz[a * st + j] != allX[j]) return false;
      return true;
    }
    return !memcmp(&s->val[a * st], &s->val[b * st], st) && (!hasXz || !memcmp(&s->xz[a * st], &s->xz[b * st], st));
  };
  size_t kept = 0;
  for (size_t i = 0; i < n; i++) {
    if (i + 1 < n && s->times[i + 1] == s->times[i]) continue;  // not the last at its time
    if (kept ? !s->repeats && same(i, kept - 1) : (initialX && same(i, SIZE_MAX))) continue;
    if (i != kept) {
      s->times[kept] = s->times[i];
      memmove(&s->val[kept * st], &s->val[i * st], st);
      if (hasXz) memmove(&s->xz[kept * st], &s->xz[i * st], st);
    }
    kept++;
  }
  s->times.resize(kept);
  s->val.resize(kept * st);
  if (hasXz) {
    s->xz.resize(kept * st);
    bool any = false;
    for (uint8_t b : s->xz) if (b) { any = true; break; }
    if (!any) s->xz.clear();
  }
}

// ---- reader view windows (time-ranged loads) ----
// ffrSetViewWindow/ffrResetViewWindow make ffrLoadSignals load only the changes
// in [s, e], plus one synthetic change at s holding the value in effect there.
// Measured on the course dump: a quarter of spike_rvfi loads in ~105 ms instead
// of 351 ms, a 1% range in 26 ms, and [t, t] (one value) in 2-18 ms. The first
// window must be set with Set, later ones with Reset (Set is ignored once a
// window exists). Invariant: every function that narrows the window widens it
// back to the whole file before it returns, so other loads see everything.
static bool g_winNarrow = false;
static inline void setTag(fsdbTag64 &g, uint64_t t) { g.H = (uint_T)(t >> 32); g.L = (uint_T)(t & 0xFFFFFFFF); }
// The reader's max tag is the end of the current view window (after a load over a narrowed
// one, that window's end), so a warm reader, which never widens again, keeps the file's own
// end from before its first load (readerNavOnce).
static uint64_t g_hotEnd = 0;
static uint64_t fileEnd() {  // time of the file's last change (a window past it loads nothing)
  if (g_hotEnd) return g_hotEnd;
  fsdbTag64 m;
  return FSDB_RC_SUCCESS == fsdb_obj->ffrGetMaxFsdbTag64(&m) ? combineTime(m.H, m.L) : UINT64_MAX;
}
static void readerWindow(uint64_t s, uint64_t e) {
  const uint64_t end = fileEnd();
  if (s > end) s = end;  // the value in effect after the end is the one at the end
  if (e > end) e = end;
  fsdbTag64 a, b;
  setTag(a, s);
  setTag(b, std::max(s, e));
  if (fsdb_obj->ffrIsViewWindowSet()) fsdb_obj->ffrResetViewWindow((fsdbXTag *)&a, (fsdbXTag *)&b);
  else fsdb_obj->ffrSetViewWindow((fsdbXTag *)&a, (fsdbXTag *)&b);
  g_winNarrow = true;
}
static void readerWindowAll() {
  if (!g_winNarrow) return;
  fsdbTag64 a, b;
  setTag(a, 0);
  setTag(b, UINT64_MAX >> 1);
  fsdb_obj->ffrResetViewWindow((fsdbXTag *)&a, (fsdbXTag *)&b);
  g_winNarrow = false;
}

// Every function that narrows the view window or loads signals holds one of
// these: whatever path it leaves by (return, throw, bad_alloc), the signals it
// loaded are unloaded and the window is widened again, so a later whole load
// is never clipped.
struct ReaderScope {
  std::vector<fsdbVarIdcode> loaded;
  bool widen = true;  // false: the caller's own scope widens (forBatches' per-batch scopes)
  ReaderScope() = default;
  ReaderScope(const ReaderScope &) = delete;
  ReaderScope &operator=(const ReaderScope &) = delete;
  void unload(fsdbVarIdcode id) {
    auto it = std::remove(loaded.begin(), loaded.end(), id);  // every entry: ids may repeat
    if (it != loaded.end()) { fsdb_obj->ffrUnloadSignals(id); loaded.erase(it, loaded.end()); }
  }
  ~ReaderScope() {
    for (auto id : loaded) fsdb_obj->ffrUnloadSignals(id);
    fsdb_obj->ffrResetSignalList();
    if (widen) readerWindowAll();
  }
};

// ---- hard memory bounds (review M2) ----
// One signal's store may not grow past g_signalCap (checked while walking,
// before the vectors grow, and when slices are joined), and a reader load
// that leaves the process over g_rssHard is undone before anything is walked.
// Both are set from JS (cacheSetBounds); 0 = no bound.
static size_t g_signalCap = 0;
static size_t g_rssHard = 0;
static size_t processRss() {
  FILE *f = fopen("/proc/self/statm", "r");
  if (!f) return 0;
  unsigned long size = 0, res = 0;
  const int n = fscanf(f, "%lu %lu", &size, &res);
  fclose(f);
  return n == 2 ? (size_t)res * (size_t)sysconf(_SC_PAGESIZE) : 0;
}
static std::string capError(size_t cap) { return "signal larger than " + std::to_string(cap >> 20) + " MB (worker store limit)"; }

// ---- value kinds from the reader ----
// What a traverse handle's values are (probed on VCS and writer-made dumps): 1 byte per bit
// is a bit vector (one FSDB_BT_VCD_* per bit); a string variable (FSDB_VT_STRING) has 4 bytes
// per bit, 1 bit, and its value is a NUL-terminated byte string; a real is an 8-byte
// double, or a 4-byte float for a 4-byte FSDB_VT_VCD_REAL. Anything else (2 bytes per bit,
// memory-range indices, other 4-byte values) can't be shown, and never will be from this
// file: such errors say "unsupported", which the coordinator and viewer treat as permanent.
static const size_t kMaxText = 1u << 20;  // one string value
// Windows carry at most kWinText bytes of each text (cut at a UTF-8 character boundary and
// marked with an ellipsis): the store keeps each distinct string once, but a window repeats
// it per record. valueAt and searchText keep the whole text. A window also has a text budget
// (the coordinator's share of its per-reply budget, kTextBudget by default): the cut shrinks
// to budget / records (down to kMinText), so a bucket-bounded window always fits; one that
// doesn't fit even at kMinText is refused (retryable; a narrower one fits).
static const size_t kWinText = 4096;
static const size_t kMinText = 256;
static const size_t kTextBudget = 16u << 20;
static size_t shownLen(const std::string &v, size_t lim = kWinText) {
  if (v.size() <= lim) return v.size();
  size_t cut = lim;
  while (cut > 0 && ((uint8_t)v[cut] & 0xC0) == 0x80) cut--;
  return cut + 3;
}
static int valueKind(ffrVCTrvsHdl h, bool &f32, std::string &err) {
  const fsdbBytesPerBit b = h->ffrGetBytesPerBit();
  const fsdbVarType vt = h->ffrGetVarType();
  f32 = false;
  if (b == FSDB_BYTES_PER_BIT_1B) {
    if (h->ffrGetBitSize() == 0) { err = "reader reports 0 bits (alias?)"; return -1; }
    return kBits;
  }
  const bool depth = vt == FSDB_VT_VCD_MEMORY_DEPTH || vt == FSDB_VT_VHDL_MEMORY_DEPTH;
  if (b == FSDB_BYTES_PER_BIT_4B && vt == FSDB_VT_STRING) return kString;
  if (b == FSDB_BYTES_PER_BIT_8B && !depth) return kReal;
  if (b == FSDB_BYTES_PER_BIT_4B && vt == FSDB_VT_VCD_REAL) { f32 = true; return kReal; }
  const int bytes = b == FSDB_BYTES_PER_BIT_2B ? 2 : b == FSDB_BYTES_PER_BIT_4B ? 4 : b == FSDB_BYTES_PER_BIT_8B ? 8 : 0;
  err = "unsupported encoding (" + (bytes ? std::to_string(bytes) + " bytes per bit" : std::string("unknown bytes per bit")) +
        ", var type " + std::to_string((int)vt) + ")";
  return -1;
}

// A real as wellen (Rust's f64 Display) prints it, which is what the viewer shows for a VCD's
// reals: the shortest digits that read back as the same number, never an exponent
// (1e300 is 1 followed by 300 zeros, 1e-7 is 0.0000001), -0 for negative zero, NaN, inf.
// A float (f32) gets the shortest digits that read back as the same float.
static std::string realText(double d, bool f32) {
  if (std::isnan(d)) return "NaN";
  const bool neg = std::signbit(d);
  if (std::isinf(d)) return neg ? "-inf" : "inf";
  if (d == 0) return neg ? "-0" : "0";
  char buf[64];
  int p = 1;
  for (; p < 17; p++) {
    snprintf(buf, sizeof buf, "%.*e", p - 1, d);
    if (f32 ? strtof(buf, nullptr) == (float)d : strtod(buf, nullptr) == d) break;
  }
  if (p == 17) snprintf(buf, sizeof buf, "%.16e", d);
  // buf = [-]D.DDDDe[+-]XX -> digits and the decimal exponent of the first digit
  std::string digits;
  const char *c = buf + (neg ? 1 : 0);
  for (; *c && *c != 'e'; c++) if (*c >= '0' && *c <= '9') digits += *c;
  const int e10 = *c == 'e' ? atoi(c + 1) : 0;
  while (digits.size() > 1 && digits.back() == '0') digits.pop_back();
  const int n = (int)digits.size(), point = e10 + 1;  // digits before the decimal point
  std::string out = neg ? "-" : "";
  if (point <= 0) out += "0." + std::string(-point, '0') + digits;
  else if (point >= n) out += digits + std::string(point - n, '0');
  else out += digits.substr(0, point) + "." + digits.substr(point);
  return out;
}

// One reader value of a non-bit kind -> its key bytes (kReal: the double) or string.
static inline double vcReal(const byte_T *vc, bool f32) {
  if (f32) { float f; memcpy(&f, vc, 4); return (double)f; }
  double d; memcpy(&d, vc, 8); return d;
}
static inline size_t vcStrLen(const byte_T *vc) { return strnlen((const char *)vc, kMaxText + 1); }
static std::string vcText(const byte_T *vc, int kind, bool f32) {
  if (kind == kReal) return realText(vcReal(vc, f32), f32);
  return std::string((const char *)vc, std::min(vcStrLen(vc), kMaxText));
}

// Walk a string or real signal (kind from valueKind) into a new store; as walkSignal.
static SigStore *walkText(ffrVCTrvsHdl h, int kind, bool f32, std::string &err, bool ranged, uint64_t s0, uint64_t e0) {
  SigStore *s = new SigStore();
  s->kind = (uint8_t)kind;
  s->f32 = f32;
  s->stride = kind == kString ? 4 : 8;
  s->bits = s->stride * 8;
  const size_t per = 8 + s->stride;
  std::unordered_map<std::string, uint32_t> intern;
  const size_t internPer = 64;  // map node, hash bucket and the key copy's overhead (transient)
  auto over = [&]() { return g_signalCap && s->times.size() * per + s->strBytes * 2 + intern.size() * internPer > g_signalCap; };
  if (h->ffrHasIncoreVC()) {
    fsdbTag64 time;
    h->ffrGetMinXTag((void *)&time);
    bool any = true;
    if (ranged && s0 > combineTime(time.H, time.L)) {
      fsdbTag64 at;
      setTag(at, s0);
      if (FSDB_RC_SUCCESS == h->ffrGotoXTag((void *)&at)) {
        for (;;) {
          h->ffrGetXTag(&at);
          if (combineTime(at.H, at.L) < s0 || FSDB_RC_SUCCESS != h->ffrGotoPrevVC()) break;
        }
      } else {
        any = false;
      }
    } else {
      h->ffrGotoXTag((void *)&time);
    }
    size_t k = 0;
    if (any) do {
      byte_T *vc;
      h->ffrGetXTag(&time);
      const uint64_t tnow = combineTime(time.H, time.L);
      if (tnow < s0) continue;
      if (tnow >= e0) break;
      h->ffrGetVC(&vc);
      s->times.push_back(tnow);
      s->val.resize((k + 1) * s->stride);
      if (kind == kReal) {
        const double d = vcReal(vc, f32);
        memcpy(&s->val[k * 8], &d, 8);
      } else {
        const size_t len = vcStrLen(vc);
        if (len > kMaxText) { delete s; err = "unsupported encoding (a string value over 1 MB)"; return nullptr; }
        auto ins = intern.emplace(std::string((const char *)vc, len), (uint32_t)s->strs.size());
        if (ins.second) { s->strs.push_back(ins.first->first); s->strBytes += len + 1; }
        const uint32_t idx = ins.first->second;
        memcpy(&s->val[k * 4], &idx, 4);
      }
      k++;
      if (over()) { delete s; err = capError(g_signalCap); return nullptr; }
      if ((k & 4095) == 0 && bgStop()) { delete s; err = "yielded"; return nullptr; }
    } while (FSDB_RC_SUCCESS == h->ffrGotoNextVC());
    normalizeStore(s, false);
    s->times.shrink_to_fit();
    s->val.shrink_to_fit();
    s->strs.shrink_to_fit();
  }
  if (kind == kReal) {
    for (size_t k = 0; k < s->times.size(); k++) {
      double d;
      memcpy(&d, &s->val[k * 8], 8);
      if (std::isfinite(d)) { s->rmin = std::min(s->rmin, d); s->rmax = std::max(s->rmax, d); }
    }
  } else if (!s->times.empty()) {
    std::vector<uint32_t> shown(s->strs.size());
    for (size_t d = 0; d < s->strs.size(); d++) shown[d] = (uint32_t)shownLen(s->strs[d]);
    double sum = 0;
    for (size_t k = 0; k < s->times.size(); k++) { uint32_t idx; memcpy(&idx, &s->val[k * 4], 4); sum += idx < shown.size() ? shown[idx] : 0; }
    s->textMean = sum / (double)s->times.size();
  }
  return s;
}

// Walk one signal (already loaded into the reader) into a new store; with
// ranged, only the changes with s <= time < e (a time slice of a split walk).
static SigStore *walkSignal(fsdbVarIdcode id, std::string &err, bool ranged = false, uint64_t s0 = 0, uint64_t e0 = UINT64_MAX) {
  ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(id);
  if (!h) { err = "no traverse handle"; return nullptr; }
  bool f32 = false;
  const int kind = valueKind(h, f32, err);
  if (kind < 0) { h->ffrFree(); return nullptr; }
  if (kind != kBits) { SigStore *t = walkText(h, kind, f32, err, ranged, s0, e0); h->ffrFree(); return t; }
  SigStore *s = new SigStore();
  s->repeats = h->ffrGetVarType() == FSDB_VT_VCD_EVENT;
  s->bits = h->ffrGetBitSize();
  // Some signals (port-connected aliases, it seems) have changes but a traverse
  // handle with 0 bits and no value bytes; VaporView's reader shows them empty.
  if (s->bits == 0) { h->ffrFree(); delete s; err = "reader reports 0 bits (alias?)"; return nullptr; }
  s->stride = (s->bits + 7) / 8;
  const uint32_t bits = s->bits, stride = s->stride;
  if (h->ffrHasIncoreVC()) {
    // Under the cap the store holds at most capN changes (counting x/z planes),
    // checked at every change, and the vectors never grow past capN + 1: the
    // reserve is the loaded count (a view window's count for slices and cold
    // windows), growth past it is 1.5x clamped to capN + 1, not doubling.
    const size_t per = 8 + 2 * (size_t)stride;
    const size_t capN = g_signalCap ? g_signalCap / per : SIZE_MAX / per;
    size_t n = std::min<size_t>(fsdb_obj->ffrGetVCCount(id), capN);
    s->times.reserve(n + 1);
    s->val.reserve((n + 1) * stride);
    const uint32_t stopMask = stride >= 1024 ? 63 : stride >= 64 ? 511 : 4095;  // bgStop every ~0.5-8 MB of values
    fsdbTag64 time;
    h->ffrGetMinXTag((void *)&time);
    bool any = true;
    if (ranged && s0 > combineTime(time.H, time.L)) {
      fsdbTag64 at;
      at.H = (uint_T)(s0 >> 32);
      at.L = (uint_T)(s0 & 0xFFFFFFFF);
      if (FSDB_RC_SUCCESS == h->ffrGotoXTag((void *)&at)) {
        // Back up past every change at >= s0 (glitches share a time), then walk forward.
        for (;;) {
          h->ffrGetXTag(&at);
          if (combineTime(at.H, at.L) < s0 || FSDB_RC_SUCCESS != h->ffrGotoPrevVC()) break;
        }
      } else {
        any = false;  // s0 is past the last change
      }
    } else {
      h->ffrGotoXTag((void *)&time);
    }
    size_t k = 0;
    if (any) do {
      byte_T *vc;
      h->ffrGetXTag(&time);
      const uint64_t tnow = combineTime(time.H, time.L);
      if (tnow < s0) continue;
      if (tnow >= e0) break;
      h->ffrGetVC(&vc);
      if (k >= capN) { h->ffrFree(); delete s; err = capError(g_signalCap); return nullptr; }
      if (k == s->times.capacity()) {
        const size_t c = std::min(capN + 1, std::max<size_t>(1024, k + k / 2));
        s->times.reserve(c);
        s->val.reserve(c * stride);
        if (!s->xz.empty()) s->xz.reserve(c * stride);
      }
      s->times.push_back(tnow);
      s->val.resize((k + 1) * stride, 0);
      uint8_t *v = &s->val[k * stride];
      const uint32_t full = bits & ~7u;
      uint64_t anyxz = 0;
      for (uint32_t i = 0; i < full; i += 8) {
        uint64_t w;
        memcpy(&w, vc + i, 8);
        v[i >> 3] = packLow(w);
        anyxz |= w;
      }
      for (uint32_t i = full; i < bits; i++) {
        v[i >> 3] |= (uint8_t)((vc[i] & 1) << (i & 7));
        anyxz |= vc[i];
      }
      const bool hasXz = anyxz & 0x0202020202020202ull;
      if (hasXz || !s->xz.empty()) {
        if (s->xz.empty()) s->xz.reserve(s->val.capacity());  // one allocation, not doubling
        s->xz.resize((k + 1) * stride, 0);  // first x/z backfills zeros
        if (hasXz) {
          uint8_t *x = &s->xz[k * stride];
          for (uint32_t i = 0; i < full; i += 8) {
            uint64_t w;
            memcpy(&w, vc + i, 8);
            x[i >> 3] = packLow(w >> 1);
          }
          for (uint32_t i = full; i < bits; i++) x[i >> 3] |= (uint8_t)(((vc[i] >> 1) & 1) << (i & 7));
        }
      }
      k++;
      if ((k & stopMask) == 0 && bgStop()) { h->ffrFree(); delete s; err = "yielded"; return nullptr; }
    } while (FSDB_RC_SUCCESS == h->ffrGotoNextVC());
    normalizeStore(s, !ranged);  // a slice joins its neighbours in cacheAdopt
    s->times.shrink_to_fit();
    s->val.shrink_to_fit();
    s->xz.shrink_to_fit();
  }
  h->ffrFree();
  return s;
}

static inline void putChars(const SigStore *s, size_t k, uint8_t *out) {
  static const char lut[4] = {'0', '1', 'x', 'z'};
  const uint8_t *v = &s->val[k * s->stride];
  const uint8_t *x = s->xz.empty() ? nullptr : &s->xz[k * s->stride];
  for (uint32_t i = 0; i < s->bits; i++) {
    uint8_t b = (v[i >> 3] >> (i & 7)) & 1;
    if (x) b |= ((x[i >> 3] >> (i & 7)) & 1) << 1;
    out[i] = lut[b];
  }
}

// The value of change k as the viewer gets it (k < 0: before the first change). Bit vectors:
// one character per bit, all x before the first change. Strings and reals: their text
// ("x" before the first change).
static std::string valueText(const SigStore *s, ptrdiff_t k) {
  if (s->kind == kBits) {
    std::string v(s->bits, 'x');
    if (k >= 0) putChars(s, (size_t)k, (uint8_t *)&v[0]);
    return v;
  }
  if (k < 0) return "x";
  if (s->kind == kString) {
    uint32_t idx;
    memcpy(&idx, &s->val[(size_t)k * 4], 4);
    return idx < s->strs.size() ? s->strs[idx] : std::string();
  }
  double d;
  memcpy(&d, &s->val[(size_t)k * 8], 8);
  return realText(d, s->f32);
}

// Records: [u64 LE delta][bits chars] for bit vectors; for strings and reals (window
// header `text: true`) [u64 LE delta][u32 LE byte length][the text's bytes].
// Returns whether a text value was cut.
static inline bool putRecord(const SigStore *s, std::vector<uint8_t> &out, uint64_t &prev, uint64_t t, ptrdiff_t k, size_t lim = kWinText) {
  if (s->kind != kBits) {
    std::string v = valueText(s, k);
    const size_t n = shownLen(v, lim);
    const bool cut = n != v.size();
    if (cut) { v.resize(n - 3); v += "\xe2\x80\xa6"; }  // cut, then U+2026
    const size_t o = out.size();
    const uint64_t delta = t - prev;
    const uint32_t len = (uint32_t)v.size();
    prev = t;
    out.resize(o + 12 + len);
    memcpy(&out[o], &delta, 8);
    memcpy(&out[o + 8], &len, 4);
    if (len) memcpy(&out[o + 12], v.data(), len);
    return cut;
  }
  const size_t o = out.size();
  out.resize(o + 8 + s->bits);
  const uint64_t delta = t - prev;
  prev = t;
  memcpy(&out[o], &delta, 8);
  if (k < 0) memset(&out[o + 8], 'x', s->bits);  // before the first change
  else putChars(s, (size_t)k, &out[o + 8]);
  return false;
}

// Index of the first change with time > t.
static inline size_t upperIdx(const SigStore *s, uint64_t t, size_t lo, size_t hi) {
  return std::upper_bound(s->times.begin() + lo, s->times.begin() + hi, t) - s->times.begin();
}

static const size_t kLoadBatch = 16;
static const uint64_t kLoadBatchBits = 4096;

// cacheLoad(ids[], evict = true) -> [{signalId, cached, count, bits, bytes, xz, loadMs, walkMs} | {signalId, error}]
Napi::Value cacheLoad(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 1) || !CHECK_ARRAY(env, info[0])) return env.Undefined();
  Napi::Array ids = info[0].As<Napi::Array>();
  readerWindowAll();  // whole loads: never under a window left narrowed
  std::vector<int64_t> all, todo;
  for (uint32_t i = 0; i < ids.Length(); i++) {
    int64_t id = argI64(ids.Get(i));
    all.push_back(id);
    if (!g_store.count(id) && std::find(todo.begin(), todo.end(), id) == todo.end()) todo.push_back(id);
  }
  using clk = std::chrono::steady_clock;
  auto msSince = [](clk::time_point a) { return std::chrono::duration<double, std::milli>(clk::now() - a).count(); };
  double loadMs = 0;
  // Reader loads go in batches (at most kLoadBatch signals or kLoadBatchBits
  // bits), each walked and unloaded before the next, so the reader holds a
  // bounded amount however many cold signals one request names.
  size_t next = 0;  // first todo entry not yet loaded
  std::vector<int64_t> loaded, overLimit;
  auto loadBatch = [&]() {
    auto t = clk::now();
    uint64_t bitsSum = 0;
    size_t n = 0;
    while (next < todo.size() && n < kLoadBatch && (n == 0 || bitsSum < kLoadBatchBits)) {
      ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle((fsdbVarIdcode)todo[next]);
      bitsSum += h ? std::max<uint32_t>(1, h->ffrGetBitSize()) : 1;
      if (h) h->ffrFree();
      fsdb_obj->ffrAddToSignalList((fsdbVarIdcode)todo[next]);
      loaded.push_back(todo[next]);
      next++; n++;
    }
    fsdb_obj->ffrLoadSignals();
    fsdb_obj->ffrResetSignalList();
    loadMs += msSince(t);
    if (g_rssHard && processRss() > g_rssHard) {  // undo before walking: the walk would add the store on top
      for (size_t j = loaded.size() - n; j < loaded.size(); j++) { fsdb_obj->ffrUnloadSignals((fsdbVarIdcode)loaded[j]); overLimit.push_back(loaded[j]); }
    }
  };
  Napi::Array result = Napi::Array::New(env);
  for (uint32_t i = 0; i < all.size(); i++) {
    const int64_t id = all[i];
    if (!g_store.count(id) && std::find(loaded.begin(), loaded.end(), id) == loaded.end()) loadBatch();
    Napi::Object o = Napi::Object::New(env);
    o.Set("signalId", Napi::Number::New(env, (double)id));
    auto it = g_store.find(id);
    double walkMs = 0;
    bool cached = it != g_store.end();
    if (!cached && std::find(overLimit.begin(), overLimit.end(), id) != overLimit.end()) {
      o.Set("error", Napi::String::New(env, "worker memory limit (reader load over " + std::to_string(g_rssHard >> 20) + " MB)"));
      result.Set(i, o);
      continue;
    }
    if (!cached) {
      auto t = clk::now();
      std::string err;
      SigStore *s = walkSignal((fsdbVarIdcode)id, err);
      fsdb_obj->ffrUnloadSignals((fsdbVarIdcode)id);
      walkMs = msSince(t);
      if (!s) { o.Set("error", Napi::String::New(env, err)); result.Set(i, o); continue; }
      g_store[id] = s;
      g_bytes += s->bytes();
      it = g_store.find(id);
    }
    SigStore *s = it->second;
    s->lastUsed = ++g_clock;
    o.Set("cached", Napi::Boolean::New(env, cached));
    o.Set("count", Napi::Number::New(env, (double)s->times.size()));
    o.Set("bits", Napi::Number::New(env, s->bits));
    o.Set("bytes", Napi::Number::New(env, (double)s->bytes()));
    o.Set("xz", Napi::Boolean::New(env, !s->xz.empty()));
    if (s->kind != kBits) o.Set("kind", Napi::String::New(env, kindName(s->kind)));
    o.Set("loadMs", Napi::Number::New(env, cached ? 0 : loadMs));
    o.Set("walkMs", Napi::Number::New(env, walkMs));
    result.Set(i, o);
  }
  if (info.Length() < 2 || info[1].ToBoolean().Value()) storeEvict(all);  // cacheLoad(ids, false): no eviction
  return result;
}

// cacheWindow(id, t0, t1, buckets, textBudget?) -> {exact, count, records: Buffer, counts?: Buffer}
static Napi::Object windowOf(Napi::Env env, const SigStore *s, uint64_t t0, uint64_t t1, uint32_t B, size_t budget);
static size_t argBudget(const Napi::CallbackInfo &info, size_t i) {
  if (info.Length() <= i || !info[i].IsNumber()) return kTextBudget;
  const double b = info[i].As<Napi::Number>().DoubleValue();
  return b >= 1 && b < 9e15 ? (size_t)b : kTextBudget;
}
Napi::Value cacheWindow(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 4)) return env.Undefined();
  SigStore *s = storeGet(env, info[0]);
  if (!s) return env.Undefined();
  uint64_t t0 = argTime(info[1]), t1 = argTime(info[2]);
  if (t1 < t0) std::swap(t0, t1);
  uint32_t B = info[3].As<Napi::Number>().Uint32Value();
  if (B == 0) B = 1;
  Napi::Object o = windowOf(env, s, t0, t1, B, argBudget(info, 4));
  o.Set("total", Napi::Number::New(env, (double)s->times.size()));  // whole-signal (normalized) count
  return o;
}
static Napi::Object windowOf(Napi::Env env, const SigStore *s, uint64_t t0, uint64_t t1, uint32_t B, size_t budget) {
  const size_t n = s->times.size();
  auto lowerIdx = [&](uint64_t t, size_t from) {
    return (size_t)(std::lower_bound(s->times.begin() + from, s->times.end(), t) - s->times.begin());
  };
  const size_t lo = lowerIdx(t0, 0);          // first change >= t0 (counted)
  const size_t first = upperIdx(s, t0, lo, n);  // first change > t0 (sent as a record)
  const size_t hi = t1 > t0 ? lowerIdx(t1, first) : lo;
  const size_t count = hi - lo;
  const bool exact = count <= 2 * (size_t)B;
  const bool text = s->kind != kBits;
  // Text: the records this window sends (the value at t0, then up to 2 per bucket), and the
  // cut that makes them fit the budget (12 bytes of header and 3 of ellipsis per record).
  size_t lim = kWinText;
  if (text) {
    const size_t later = hi > first ? hi - first : 0;
    const size_t sends = 1 + (exact ? later : std::min(later, 2 * (size_t)B));
    lim = std::max(kMinText, std::min(kWinText, budget / sends > 15 ? budget / sends - 15 : 0));
  }
  std::vector<uint8_t> rec;
  uint64_t prev = 0;
  bool cut = putRecord(s, rec, prev, t0, (ptrdiff_t)first - 1, lim);
  Napi::Object o = Napi::Object::New(env);
  auto overBudget = [&]() {
    char mb[32];
    snprintf(mb, sizeof mb, "%.1f", budget / 1048576.0);
    o.Set("error", Napi::String::New(env, std::string("text window over its ") + mb + " MB reply budget (a narrower window fits)"));
    return o;
  };
  if (exact) {
    rec.reserve(text ? 4096 : (count + 1) * (8 + s->bits));
    for (size_t k = first; k < hi; k++) {
      cut |= putRecord(s, rec, prev, s->times[k], (ptrdiff_t)k, lim);
      if (text && rec.size() > budget) return overBudget();
    }
  } else {
    std::vector<uint32_t> counts(B);
    const unsigned __int128 span = t1 - t0;
    size_t a = lo;
    for (uint32_t k = 0; k < B; k++) {
      // Bucket k+1 starts at the first change with time >= t0 + ceil(span * (k+1) / B).
      const size_t b = k + 1 == B ? hi : lowerIdx(t0 + (uint64_t)((span * (k + 1) + B - 1) / B), a);
      counts[k] = (uint32_t)(b - a);
      const size_t f = std::max(a, first);
      if (b > f) {
        cut |= putRecord(s, rec, prev, s->times[f], (ptrdiff_t)f, lim);
        if (b - f >= 2) cut |= putRecord(s, rec, prev, s->times[b - 1], (ptrdiff_t)(b - 1), lim);
        if (text && rec.size() > budget) return overBudget();
      }
      a = b;
    }
    o.Set("counts", Napi::Buffer<uint8_t>::Copy(env, (uint8_t *)counts.data(), counts.size() * 4));
  }
  o.Set("exact", Napi::Boolean::New(env, exact));
  o.Set("count", Napi::Number::New(env, (double)count));
  o.Set("records", Napi::Buffer<uint8_t>::Copy(env, rec.data(), rec.size()));
  if (s->kind != kBits) {
    o.Set("text", Napi::Boolean::New(env, true));
    o.Set("kind", Napi::String::New(env, kindName(s->kind)));
    if (cut) o.Set("cut", Napi::Boolean::New(env, true));  // a value was cut: the viewer doesn't load it whole
  }
  if (s->kind == kReal) { o.Set("min", Napi::Number::New(env, s->rmin)); o.Set("max", Napi::Number::New(env, s->rmax)); }
  if (s->kind == kString) o.Set("textMean", Napi::Number::New(env, s->textMean));
  return o;
}

// cacheRecords(id) -> Buffer of every change, same layout as getValueChangesPacked.
Napi::Value cacheRecords(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 1)) return env.Undefined();
  SigStore *s = storeGet(env, info[0]);
  if (!s) return env.Undefined();
  std::vector<uint8_t> rec;
  rec.reserve(s->times.size() * (8 + (s->kind == kBits ? s->bits : 16)));
  uint64_t prev = 0;
  for (size_t k = 0; k < s->times.size(); k++) putRecord(s, rec, prev, s->times[k], (ptrdiff_t)k);
  return Napi::Buffer<uint8_t>::Copy(env, rec.data(), rec.size());
}

// cacheValueAt(id, t) -> value string in effect at t (all x before the first change).
Napi::Value cacheValueAt(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 2)) return env.Undefined();
  SigStore *s = storeGet(env, info[0]);
  if (!s) return env.Undefined();
  const size_t k = upperIdx(s, argTime(info[1]), 0, s->times.size());
  return Napi::String::New(env, valueText(s, (ptrdiff_t)k - 1));
}

// cacheEdge(id, t, dir, kind, start?) -> time of the next (dir 1, time > t) or previous
// (dir -1, time < t) change, or null. kind 0 any change, 1 rise (new value '1',
// so x->1 counts, as in VaporView), 2 fall (new value '0'); rise/fall look at
// 1-bit signals, wider ones treat them as any. SystemVerilog kinds, by the change from the
// previous value (1-bit signals only; wider ones throw): 3 posedge (0->1, 0->x, 0->z, x->1,
// z->1), 4 negedge (1->0, 1->x, 1->z, x->0, z->0), 5 edge (either; x<->z is none). The
// dump's first value (a first change at or before `start`, the dump's start time) is never an
// edge; a first change after it is one from 'x'.
Napi::Value cacheEdge(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 4)) return env.Undefined();
  SigStore *s = storeGet(env, info[0]);
  if (!s) return env.Undefined();
  const uint64_t t = argTime(info[1]);
  const int dir = info[2].As<Napi::Number>().Int32Value() < 0 ? -1 : 1;
  int kind = info[3].As<Napi::Number>().Int32Value();
  const uint64_t start = info.Length() > 4 && info[4].IsNumber() ? argTime(info[4]) : 0;
  const bool bitRow = s->bits == 1 && s->kind == kBits;
  if (kind >= 3 && !bitRow) {
    Napi::Error::New(env, "edge: posedge, negedge and edge need a 1-bit signal").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  if (kind < 3 && !bitRow) kind = 0;  // wider signals, strings and reals: every change is an edge
  const size_t n = s->times.size();
  auto bit2 = [&](size_t k) -> int {  // 0..3 like the reader's bit types
    int b = s->val[k] & 1;
    if (!s->xz.empty()) b |= (s->xz[k] & 1) << 1;
    return b;
  };
  auto isEdge = [&](size_t k) -> bool {
    if (kind == 0) return true;
    const int b = bit2(k);
    if (kind <= 2) return b == (kind == 1 ? 1 : 0);
    if (k == 0 && s->times[0] <= start) return false;
    const int a = k > 0 ? bit2(k - 1) : 2;  // (before the first change: 'x')
    const bool pos = (a == 0 && b != 0) || (a >= 2 && b == 1);
    const bool neg = (a == 1 && b != 1) || (a >= 2 && b == 0);
    return kind == 3 ? pos : kind == 4 ? neg : pos || neg;
  };
  if (dir > 0) {
    for (size_t k = upperIdx(s, t, 0, n); k < n; k++)
      if (isEdge(k)) return Napi::Number::New(env, (double)s->times[k]);
  } else {
    size_t k = std::lower_bound(s->times.begin(), s->times.end(), t) - s->times.begin();
    while (k-- > 0)
      if (isEdge(k)) return Napi::Number::New(env, (double)s->times[k]);
  }
  return env.Null();
}

// cacheSearch(id, t, dir, pattern) -> time of the first change whose new value matches
// `pattern` (next after t, or last before t), or null. The pattern is MSB-first
// like the value strings; 'x' (or '?') is a wildcard, '0'/'1'/'z' are literal
// (strict '!' patterns: see patternBits); a short pattern is padded on the left with '0'.
// First change in direction dir from t whose value matches pattern p, not
// past `bound` (dir 1: time <= bound, dir -1: time >= bound). -> found?
// A pattern that starts with '!' is strict (search {wildcard: '?'}): only '?'
// matches anything and 'x' is literal. -> per-bit 'd' (don't care), '0', '1', 'x', 'z'.
static std::string patternBits(std::string p, uint32_t bits) {
  const bool strict = !p.empty() && p[0] == '!';
  if (strict) p = p.substr(1);
  if (p.size() > bits) p = p.substr(p.size() - bits);
  if (p.size() < bits) p = std::string(bits - p.size(), '0') + p;
  for (char &c : p) {
    if (c == '?') c = 'd';
    else if (c == 'x' || c == 'X') c = strict ? 'x' : 'd';
    else if (c == 'z' || c == 'Z') c = 'z';
    else if (c != '1') c = '0';
  }
  return p;
}

static bool storeSearch(const SigStore *s, uint64_t t, int dir, std::string p, uint64_t bound, uint64_t &hit) {
  p = patternBits(p, s->bits);
  const uint32_t st = s->stride;
  std::vector<uint8_t> care(st, 0), wantV(st, 0), wantX(st, 0);
  for (uint32_t i = 0; i < s->bits; i++) {
    const char c = p[i];
    if (c == 'd') continue;
    care[i >> 3] |= 1 << (i & 7);
    if (c == '1' || c == 'z') wantV[i >> 3] |= 1 << (i & 7);
    if (c == 'x' || c == 'z') wantX[i >> 3] |= 1 << (i & 7);
  }
  const bool hasXz = !s->xz.empty();
  auto match = [&](size_t k) -> bool {
    const uint8_t *v = &s->val[k * st];
    const uint8_t *x = hasXz ? &s->xz[k * st] : nullptr;
    for (uint32_t j = 0; j < st; j++) {
      if ((v[j] ^ wantV[j]) & care[j]) return false;
      if (((x ? x[j] : 0) ^ wantX[j]) & care[j]) return false;
    }
    return true;
  };
  const size_t n = s->times.size();
  if (dir > 0) {
    for (size_t k = upperIdx(s, t, 0, n); k < n && s->times[k] <= bound; k++)
      if (match(k)) { hit = s->times[k]; return true; }
  } else {
    size_t k = std::lower_bound(s->times.begin(), s->times.end(), t) - s->times.begin();
    while (k-- > 0 && s->times[k] >= bound)
      if (match(k)) { hit = s->times[k]; return true; }
  }
  return false;
}

Napi::Value cacheSearch(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 4) || !CHECK_STRING(env, info[3])) return env.Undefined();
  SigStore *s = storeGet(env, info[0]);
  if (!s) return env.Undefined();
  if (s->kind != kBits) {
    Napi::Error::New(env, std::string("search: a ") + kindName(s->kind) + " signal has no bit pattern (use searchText, format string)").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  const int dir = info[2].As<Napi::Number>().Int32Value() < 0 ? -1 : 1;
  const uint64_t bound = info.Length() > 4 ? argTime(info[4]) : (dir > 0 ? UINT64_MAX : 0);
  uint64_t hit;
  if (storeSearch(s, argTime(info[1]), dir, info[3].As<Napi::String>().Utf8Value(), bound, hit)) return Napi::Number::New(env, (double)hit);
  return env.Null();
}

// ---- searchText: text search over a signal's distinct values ----
// The formatting and matching are JS (the viewer's own formatters); C++ only maps
// changes to distinct values and scans for the first change whose value is known to
// match. Distinct values are keyed on the change's raw value and x/z planes.
static const size_t kMaxDistinct = 1u << 22;
static uint64_t g_dgen = 0;
// Change k's value (and x/z plane) hashed and compared in place: the build keeps no key
// copies, only vidx (4 B per change), dfirst (4 B per distinct value, up to 2x with vector
// growth) and an open-addressing slot table (2-4 slots of 4 B per distinct value, plus the old
// table while growing), so its transient memory is at most 4 B per change + 32 B per distinct
// value (searchText verify N6; spike_rvfi: 5.1 MB peak for 750k changes / 84k values).
static inline uint64_t changeHash(const SigStore *s, size_t k) {
  const size_t st = s->stride;
  uint64_t h = 1469598103934665603ull;
  const uint8_t *v = &s->val[k * st];
  for (size_t i = 0; i < st; i++) { h ^= v[i]; h *= 1099511628211ull; }
  if (!s->xz.empty()) { const uint8_t *x = &s->xz[k * st]; for (size_t i = 0; i < st; i++) { h ^= x[i]; h *= 1099511628211ull; } }
  return h ^ (h >> 29);
}
static inline bool changeEq(const SigStore *s, size_t a, size_t b) {
  const size_t st = s->stride;
  if (memcmp(&s->val[a * st], &s->val[b * st], st) != 0) return false;
  return s->xz.empty() || memcmp(&s->xz[a * st], &s->xz[b * st], st) == 0;
}
// -> 0 ok, 1 error (err), 2 too large for the signal cap (err)
static int buildDistinct(int64_t id, SigStore *s, std::string &err, double *buildBytes) {
  if (s->dgen) return 0;
  const size_t n = s->times.size();
  // The table goes into the store: refuse before building if store + vidx is already over the
  // signal cap (dfirst is checked once known).
  if (g_signalCap && s->bytes() + n * 4 > g_signalCap) { err = "signal too large for a text search: store + value table over the " + std::to_string(g_signalCap >> 20) + " MB worker store limit"; return 2; }
  std::vector<uint32_t> vidx(n), first;
  size_t cap = 1024;
  std::vector<uint32_t> slot(cap, UINT32_MAX);
  size_t peak = n * 4 + cap * 4;
  for (size_t k = 0; k < n; k++) {
    const uint64_t hk = changeHash(s, k);
    size_t i = hk & (cap - 1);
    uint32_t d;
    for (;;) {
      d = slot[i];
      if (d == UINT32_MAX || changeEq(s, first[d], k)) break;
      i = (i + 1) & (cap - 1);
    }
    if (d == UINT32_MAX) {
      if (first.size() >= kMaxDistinct) { err = "too many distinct values for a text search (over 4M)"; return 2; }
      d = (uint32_t)first.size();
      first.push_back((uint32_t)k);
      slot[i] = d;
      if (first.size() * 2 > cap) {  // grow: rehash from the first changes
        cap *= 2;
        std::vector<uint32_t> ns(cap, UINT32_MAX);
        for (uint32_t e = 0; e < first.size(); e++) {
          size_t j = changeHash(s, first[e]) & (cap - 1);
          while (ns[j] != UINT32_MAX) j = (j + 1) & (cap - 1);
          ns[j] = e;
        }
        slot.swap(ns);
        peak = std::max(peak, n * 4 + first.capacity() * 4 + cap * 4 + cap * 2);
      }
    }
    vidx[k] = d;
  }
  if (buildBytes) *buildBytes = (double)std::max(peak, n * 4 + first.capacity() * 4 + cap * 4);
  first.shrink_to_fit();
  if (g_signalCap && s->bytes() + (vidx.capacity() + first.capacity()) * 4 > g_signalCap) { err = "signal too large for a text search: store + value table over the " + std::to_string(g_signalCap >> 20) + " MB worker store limit"; return 2; }
  g_bytes -= s->bytes();
  s->vidx.swap(vidx);
  s->dfirst.swap(first);
  s->dgen = ++g_dgen;
  g_bytes += s->bytes();
  storeEvict({id});  // the table counts in the store's bytes: make room for it like any load
  return 0;
}

// cacheTextScan(id, t, dir, mask, maxNew, fromK = -1, bound?, inclusive = false) ->
//   {gen, n, t, k, d, v}         the first change (dir 1: time > t; dir -1: time < t, as
//                                cacheSearch; >= / <= when inclusive) whose distinct value d
//                                has mask[d] == 1
//   {tooLarge, error}            the value table doesn't fit the signal cap (store unchanged)
//   {gen, n, need: [{d, v}], k}  values not yet judged (mask[d] == 0 or d >= mask.length)
//                                met before any match: at most maxNew, in scan order;
//                                rescan from change k (fromK) once they are judged
//   {gen, n, t: null}            no match (mask[d] == 2 for every value in the way)
// fromK >= 0 starts at that change index (inclusive) instead of t; bound as cacheSearch.
Napi::Value cacheTextScan(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 5)) return env.Undefined();
  SigStore *s = storeGet(env, info[0]);
  if (!s) return env.Undefined();
  std::string err;
  double buildBytes = 0;
  const int b = buildDistinct(argI64(info[0]), s, err, &buildBytes);
  if (b == 2) {
    Napi::Object o = Napi::Object::New(env);
    o.Set("tooLarge", Napi::Boolean::New(env, true));
    o.Set("error", Napi::String::New(env, err));
    return o;
  }
  if (b) { Napi::Error::New(env, err).ThrowAsJavaScriptException(); return env.Undefined(); }
  const uint64_t t = argTime(info[1]);
  const int dir = info[2].As<Napi::Number>().Int32Value() < 0 ? -1 : 1;
  const uint8_t *mask = nullptr; size_t mlen = 0;
  if (info[3].IsTypedArray()) { auto a = info[3].As<Napi::Uint8Array>(); mask = a.Data(); mlen = a.ElementLength(); }
  const uint32_t maxNew = std::max<uint32_t>(1, info[4].As<Napi::Number>().Uint32Value());
  const int64_t fromK = info.Length() > 5 && info[5].IsNumber() ? argI64(info[5]) : -1;
  const uint64_t bound = info.Length() > 6 && info[6].IsNumber() ? argTime(info[6]) : (dir > 0 ? UINT64_MAX : 0);
  const bool inclusive = info.Length() > 7 && info[7].ToBoolean().Value();
  const size_t n = s->times.size();
  Napi::Object o = Napi::Object::New(env);
  o.Set("gen", Napi::Number::New(env, (double)s->dgen));
  o.Set("n", Napi::Number::New(env, (double)s->dfirst.size()));
  if (buildBytes > 0) o.Set("buildBytes", Napi::Number::New(env, buildBytes));
  // k walks change indices; dir -1 walks down from the last change < t (<= t when inclusive),
  // dir 1 up from the first change > t (>= t when inclusive).
  int64_t k;
  if (fromK >= 0) k = std::min<int64_t>(fromK, (int64_t)n - (dir > 0 ? 0 : 1));
  else if (dir > 0) k = inclusive ? (int64_t)(std::lower_bound(s->times.begin(), s->times.end(), t) - s->times.begin()) : (int64_t)upperIdx(s, t, 0, n);
  else k = (int64_t)(inclusive ? std::upper_bound(s->times.begin(), s->times.end(), t) - s->times.begin()
                               : std::lower_bound(s->times.begin(), s->times.end(), t) - s->times.begin()) - 1;
  Napi::Array need = Napi::Array::New(env);
  std::unordered_set<uint32_t> seen;
  int64_t needK = -1;
  for (; k >= 0 && k < (int64_t)n; k += dir) {
    const uint64_t tk = s->times[k];
    if (dir > 0 ? tk > bound : tk < bound) break;
    const uint32_t d = s->vidx[k];
    const uint8_t m = d < mlen ? mask[d] : 0;
    if (m == 1 && needK < 0) {
      o.Set("t", Napi::Number::New(env, (double)tk));
      o.Set("k", Napi::Number::New(env, (double)k));
      o.Set("d", Napi::Number::New(env, d));
      o.Set("v", Napi::String::New(env, valueText(s, (ptrdiff_t)k)));
      return o;
    }
    if (m == 0 && seen.insert(d).second) {
      if (needK < 0) needK = k;
      Napi::Object e = Napi::Object::New(env);
      e.Set("d", Napi::Number::New(env, d));
      e.Set("v", Napi::String::New(env, valueText(s, (ptrdiff_t)s->dfirst[d])));
      need.Set(need.Length(), e);
      if (seen.size() >= maxNew) break;
    }
  }
  if (needK >= 0) {
    o.Set("need", need);
    o.Set("k", Napi::Number::New(env, (double)needK));
    o.Set("kt", Napi::Number::New(env, (double)s->times[needK]));
    return o;
  }
  o.Set("t", env.Null());
  return o;
}

// ---- search index (opt-in warm-up) ----
// indexWrite(id, path) -> {count, bytes, rawBytes, bits} | {error}: walk a signal
// straight into a compressed index file (not the LRU store); background, so it may yield.
Napi::Value indexWrite(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 2) || !CHECK_STRING(env, info[1])) return env.Undefined();
  const fsdbVarIdcode id = (fsdbVarIdcode)argI64(info[0]);
  fsdb_obj->ffrAddToSignalList(id);
  fsdb_obj->ffrLoadSignals();
  fsdb_obj->ffrResetSignalList();
  std::string err;
  SigStore *s = walkSignal(id, err);
  fsdb_obj->ffrUnloadSignals(id);
  Napi::Object o = Napi::Object::New(env);
  if (!s) { o.Set("error", Napi::String::New(env, err)); return o; }
  if (s->kind != kBits) { delete s; o.Set("error", Napi::String::New(env, "string and real signals are not indexed")); return o; }
  const uint64_t raw = 17 + s->times.size() * 8 + s->val.size() + s->xz.size();
  uint64_t bytes = 0;
  const bool ok = writeIndexFile(s, info[1].As<Napi::String>().Utf8Value(), bytes);
  o.Set("rawBytes", Napi::Number::New(env, (double)raw));
  o.Set("count", Napi::Number::New(env, (double)s->times.size()));
  o.Set("bits", Napi::Number::New(env, s->bits));
  o.Set("bytes", Napi::Number::New(env, (double)bytes));
  if (!ok) o.Set("error", Napi::String::New(env, "cannot write index file"));
  delete s;
  return o;
}

// indexSearch(paths[], ids[], t, dir, pattern, bound) -> [{signalId, t | null} | {signalId, error} | {signalId, yielded}]
// searchAll from index files (read, searched, dropped; nothing kept).
Napi::Value indexSearch(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 6) || !CHECK_ARRAY(env, info[0]) || !CHECK_ARRAY(env, info[1]) || !CHECK_STRING(env, info[4])) return env.Undefined();
  Napi::Array paths = info[0].As<Napi::Array>(), ids = info[1].As<Napi::Array>();
  const uint64_t t = argTime(info[2]);
  const int dir = info[3].As<Napi::Number>().Int32Value() < 0 ? -1 : 1;
  const std::string pat = info[4].As<Napi::String>().Utf8Value();
  const uint64_t bound = argTime(info[5]);
  Napi::Array out = Napi::Array::New(env);
  for (uint32_t i = 0; i < paths.Length() && i < ids.Length(); i++) {
    Napi::Object o = Napi::Object::New(env);
    o.Set("signalId", ids.Get(i));
    out.Set(i, o);
    if (bgStop()) { o.Set("yielded", Napi::Boolean::New(env, true)); continue; }
    std::string err;
    SigStore *s = readIndexFile(paths.Get(i).As<Napi::String>().Utf8Value(), err);
    if (!s) { o.Set("error", Napi::String::New(env, err)); continue; }
    uint64_t hit;
    o.Set("t", storeSearch(s, t, dir, pat, bound, hit) ? Napi::Number::New(env, (double)hit) : env.Null());
    delete s;
  }
  return out;
}

// cacheFree(id?) frees one signal, or all with no argument.
Napi::Value cacheFree(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() == 0 || info[0].IsUndefined()) {
    for (auto &kv : g_store) delete kv.second;
    g_store.clear();
    g_bytes = 0;
    return Napi::Boolean::New(env, true);
  }
  const int64_t id = argI64(info[0]);
  const bool had = g_store.count(id) > 0;
  storeFree(id);
  return Napi::Boolean::New(env, had);
}

// cacheSetLimit(bytes): LRU budget for this process; evicts at once if over.
Napi::Value cacheSetLimit(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 1) || !CHECK_NUMBER(env, info[0])) return env.Undefined();
  g_limit = (size_t)info[0].As<Napi::Number>().DoubleValue();
  storeEvict({});
  return Napi::Number::New(env, (double)g_limit);
}

// cacheStats() -> {bytes, limit, signals: [{signalId, count, bits, bytes, xz}]}
Napi::Value cacheStats(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  Napi::Object o = Napi::Object::New(env);
  Napi::Array sigs = Napi::Array::New(env);
  uint32_t i = 0;
  for (auto &kv : g_store) {
    Napi::Object e = Napi::Object::New(env);
    e.Set("signalId", Napi::Number::New(env, (double)kv.first));
    e.Set("count", Napi::Number::New(env, (double)kv.second->times.size()));
    e.Set("bits", Napi::Number::New(env, kv.second->bits));
    e.Set("bytes", Napi::Number::New(env, (double)kv.second->bytes()));
    e.Set("xz", Napi::Boolean::New(env, !kv.second->xz.empty()));
    if (kv.second->kind != kBits) e.Set("kind", Napi::String::New(env, kindName(kv.second->kind)));
    sigs.Set(i++, e);
  }
  o.Set("bytes", Napi::Number::New(env, (double)g_bytes));
  o.Set("limit", Napi::Number::New(env, (double)g_limit));
  o.Set("signals", sigs);
  return o;
}

// ---- split walks: a wide signal is walked in time slices by several workers ----
// cacheWalkSlice(id, s, e, path) -> {count, xz, loadMs, walkMs}: load the signal,
// walk s <= time < e, write [bits u32][n u64][hasXz u8][times][val][xz] to path.
Napi::Value cacheWalkSlice(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 4) || !CHECK_STRING(env, info[3])) return env.Undefined();
  const int64_t id = argI64(info[0]);
  using clk = std::chrono::steady_clock;
  auto msSince = [](clk::time_point a) { return std::chrono::duration<double, std::milli>(clk::now() - a).count(); };
  auto t = clk::now();
  const uint64_t s0 = argTime(info[1]), e0 = argTime(info[2]);
  // Load only this slice (the reader adds the value in effect at s0 as a change
  // at s0, which cacheAdopt's normalization drops when it repeats). Before view
  // windows every slice loaded the whole signal, which capped the split at ~1.5x.
  ReaderScope scope;
  if (e0 > s0) readerWindow(s0, e0 - 1);
  fsdb_obj->ffrAddToSignalList((fsdbVarIdcode)id);
  scope.loaded.push_back((fsdbVarIdcode)id);
  fsdb_obj->ffrLoadSignals();
  fsdb_obj->ffrResetSignalList();
  const double loadMs = msSince(t);
  t = clk::now();
  std::string err;
  SigStore *s = walkSignal((fsdbVarIdcode)id, err, true, s0, e0);
  scope.unload((fsdbVarIdcode)id);
  readerWindowAll();
  if (!s) { Napi::Error::New(env, err).ThrowAsJavaScriptException(); return env.Undefined(); }
  if (s->kind != kBits) { delete s; Napi::Error::New(env, "string and real signals are not split").ThrowAsJavaScriptException(); return env.Undefined(); }
  const std::string path = info[3].As<Napi::String>().Utf8Value();
  const uint64_t n = s->times.size();
  const uint8_t hasXz = !s->xz.empty();
  const bool wrote = writeStoreFile(s, path);
  delete s;
  if (!wrote) { Napi::Error::New(env, "cannot write " + path).ThrowAsJavaScriptException(); return env.Undefined(); }
  Napi::Object o = Napi::Object::New(env);
  o.Set("count", Napi::Number::New(env, (double)n));
  o.Set("xz", Napi::Boolean::New(env, hasXz));
  o.Set("loadMs", Napi::Number::New(env, loadMs));
  o.Set("walkMs", Napi::Number::New(env, msSince(t)));
  return o;
}

// cacheAdopt(id, paths[]) -> {count, bytes}: concatenate slice files (in time
// order) into this process's store and delete them.
Napi::Value cacheAdopt(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 2) || !CHECK_ARRAY(env, info[1])) return env.Undefined();
  const int64_t id = argI64(info[0]);
  Napi::Array paths = info[1].As<Napi::Array>();
  std::vector<SigStore *> parts;
  auto cleanup = [&]() { for (SigStore *q : parts) delete q; };
  uint64_t total = 0, lastT = 0;
  bool anyXz = false;
  for (uint32_t i = 0; i < paths.Length(); i++) {
    std::string err;
    SigStore *q = paths.Get(i).IsString() ? readStoreFile(paths.Get(i).As<Napi::String>().Utf8Value(), err) : nullptr;
    if (!q) { cleanup(); Napi::Error::New(env, err.empty() ? "bad slice path" : err).ThrowAsJavaScriptException(); return env.Undefined(); }
    parts.push_back(q);
    const bool joins = q->bits == parts[0]->bits && (q->times.empty() || total == 0 || lastT <= q->times.front());
    if (!q->times.empty()) lastT = q->times.back();
    if (!joins) { cleanup(); Napi::Error::New(env, "slices do not join").ThrowAsJavaScriptException(); return env.Undefined(); }
    total += q->times.size();
    anyXz = anyXz || !q->xz.empty();
  }
  if (g_signalCap && !parts.empty() && total * (8 + 2 * (size_t)((parts[0]->bits + 7) / 8)) > g_signalCap) {
    cleanup(); Napi::Error::New(env, capError(g_signalCap)).ThrowAsJavaScriptException(); return env.Undefined();
  }
  SigStore *s = new SigStore();
  s->bits = parts.empty() ? 0 : parts[0]->bits;
  s->stride = (s->bits + 7) / 8;
  s->times.reserve(total);
  s->val.reserve(total * s->stride);
  if (anyXz) s->xz.reserve(total * s->stride);
  for (SigStore *q : parts) {
    s->times.insert(s->times.end(), q->times.begin(), q->times.end());
    s->val.insert(s->val.end(), q->val.begin(), q->val.end());
    if (anyXz) {
      if (!q->xz.empty()) s->xz.insert(s->xz.end(), q->xz.begin(), q->xz.end());
      else s->xz.resize(s->xz.size() + q->val.size(), 0);
    }
    delete q;
  }
  parts.clear();
  normalizeStore(s, true);
  s->times.shrink_to_fit();
  s->val.shrink_to_fit();
  s->xz.shrink_to_fit();
  storeFree(id);
  s->lastUsed = ++g_clock;
  g_store[id] = s;
  g_bytes += s->bytes();
  storeEvict({id});
  Napi::Object o = Napi::Object::New(env);
  o.Set("count", Napi::Number::New(env, (double)s->times.size()));
  o.Set("bytes", Napi::Number::New(env, (double)s->bytes()));
  return o;
}

// searchScan(ids[], t, dir, pattern, bound, kind?, start?) -> [{signalId, t | null, scanned} | {signalId, error}]
// searchAll on signals that aren't stored: load them (one batched reader load),
// scan the reader's changes from t in direction dir for the first change whose
// value matches `pattern` (as cacheSearch), and stop early past `bound`
// (dir 1: time > bound, dir -1: time < bound). Nothing is kept.
// kind >= 0: the first edge of that kind instead (cacheEdge's kinds and rules, `start` the
// dump's start): edge and value search on a signal too big for the store, by ranged reads.
Napi::Value searchScan(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 5) || !CHECK_ARRAY(env, info[0]) || !CHECK_STRING(env, info[3])) return env.Undefined();
  Napi::Array ids = info[0].As<Napi::Array>();
  const uint64_t t = argTime(info[1]);
  const int dir = info[2].As<Napi::Number>().Int32Value() < 0 ? -1 : 1;
  const std::string pat0 = info[3].As<Napi::String>().Utf8Value();
  const uint64_t bound = argTime(info[4]);
  const int kind0 = info.Length() > 5 && info[5].IsNumber() ? info[5].As<Napi::Number>().Int32Value() : -1;
  const uint64_t start = info.Length() > 6 && info[6].IsNumber() ? argTime(info[6]) : 0;
  std::vector<fsdbVarIdcode> list;
  for (uint32_t i = 0; i < ids.Length(); i++) list.push_back((fsdbVarIdcode)argI64(ids.Get(i)));
  // Load a few at a time: a reader load can't be interrupted, so small
  // batches keep the wait for interactive work (which makes us yield) short.
  const size_t batch = g_bg ? 1 : 16;
  size_t loadedEnd = 0;
  Napi::Array out = Napi::Array::New(env);
  bool stopped = false;
  // Only the part of the file the scan can use is loaded: forward [t, bound]
  // (the reader's first change at t is the value in effect there, the scan's
  // `prev`), backward [bound - 1, t] (the change at bound - 1 is the value
  // before a group at bound). Once `limit` matches are known the bound is the
  // limit-th nearest match, so later candidates load a fraction of the file.
  ReaderScope scope;  // widens the window (and unloads) on every exit path
  {
    const uint64_t end = fileEnd();
    const uint64_t ws = dir > 0 ? t : (bound > 0 ? bound - 1 : 0);
    const uint64_t we = dir > 0 ? std::min(bound, end) : std::min(t, end);
    if (ws > 0 || we < end) readerWindow(ws, std::max(ws, we));
  }
  for (uint32_t i = 0; i < list.size(); i++) {
    const fsdbVarIdcode id = list[i];
    Napi::Object o = Napi::Object::New(env);
    o.Set("signalId", Napi::Number::New(env, (double)id));
    out.Set(i, o);
    if (stopped || (stopped = bgStop())) {
      o.Set("yielded", Napi::Boolean::New(env, true));
      if (i < loadedEnd) scope.unload(id);  // loaded with its batch, not scanned
      continue;
    }
    if (i % batch == 0) {
      loadedEnd = std::min<size_t>(list.size(), i + batch);
      for (size_t j = i; j < loadedEnd; j++) { fsdb_obj->ffrAddToSignalList(list[j]); scope.loaded.push_back(list[j]); }
      fsdb_obj->ffrLoadSignals();
      fsdb_obj->ffrResetSignalList();
    }
    ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(id);
    if (!h) { o.Set("error", Napi::String::New(env, "no traverse handle")); scope.unload(id); continue; }
    const uint32_t bits = h->ffrGetBitSize();
    {
      bool f32;
      std::string kerr;
      const int kind = valueKind(h, f32, kerr);
      if (kind != kBits) {
        o.Set("error", Napi::String::New(env, kind < 0 ? kerr : std::string("not a bit signal (") + kindName((uint8_t)kind) + ")"));
        h->ffrFree(); scope.unload(id); continue;
      }
    }
    if (kind0 >= 3 && bits != 1) {
      o.Set("error", Napi::String::New(env, "edge: posedge, negedge and edge need a 1-bit signal"));
      h->ffrFree(); scope.unload(id); continue;
    }
    const int kind = kind0 >= 0 && kind0 < 3 && bits != 1 ? 0 : kind0;
    const std::string p = patternBits(pat0, bits);
    std::vector<uint32_t> care;
    std::vector<uint8_t> want;
    for (uint32_t j = 0; j < bits; j++) {
      const char c = p[j];
      if (c == 'd') continue;
      care.push_back(j);
      want.push_back(c == '1' ? 1 : c == 'x' ? 2 : c == 'z' ? 3 : 0);
    }
    auto match = [&](const uint8_t *vc) {
      for (size_t j = 0; j < care.size(); j++) if ((vc[care[j]] & 3) != want[j]) return false;
      return true;
    };
    // The change at ct from value `was` to `now` (normalized, so they differ): a hit? (bit types
    // 0 1 2=x 3=z, as cacheEdge's bit2)
    auto hitOf = [&](const std::vector<uint8_t> &was, const std::vector<uint8_t> &now, uint64_t ct) -> bool {
      if (kind < 0) return match(now.data());
      if (kind == 0) return true;
      const int b = now[0];
      if (kind <= 2) return b == (kind == 1 ? 1 : 0);
      if (ct <= start) return false;  // (the dump's first value is no edge)
      const int a = was[0];
      const bool pos = (a == 0 && b != 0) || (a >= 2 && b == 1);
      const bool neg = (a == 1 && b != 1) || (a >= 2 && b == 0);
      return kind == 3 ? pos : kind == 4 ? neg : pos || neg;
    };
    // The reader's raw changes, read as the normalized stream (normalizeStore):
    // per time only the last change counts, and only if it differs from the
    // value in effect before it (all x before the first change).
    std::vector<uint8_t> prev(bits, 2), cur(bits);
    const bool ev = h->ffrGetVarType() == FSDB_VT_VCD_EVENT;  // each occurrence is a change (as normalizeStore's repeats)
    auto grab = [&](std::vector<uint8_t> &dst) { byte_T *vc; h->ffrGetVC(&vc); for (uint32_t j = 0; j < bits; j++) dst[j] = vc[j] & 3; };
    double found = -1, scanned = 0;
    uint64_t steps = 0;
    if (h->ffrHasIncoreVC()) {
      fsdbTag64 tag, at;
      tag.H = (uint_T)(t >> 32);
      tag.L = (uint_T)(t & 0xFFFFFFFF);
      fsdbTag64 maxTag;
      const bool past = dir > 0 && FSDB_RC_SUCCESS == h->ffrGetMaxXTag((void *)&maxTag) && combineTime(maxTag.H, maxTag.L) <= t;
      bool onT = !past && FSDB_RC_SUCCESS == h->ffrGotoXTag((void *)&tag);  // a change <= t
      // t past the last loaded change (a view window ends at the file's end): start from the last one.
      if (!onT && dir < 0 && FSDB_RC_SUCCESS == h->ffrGetMaxXTag((void *)&tag) && combineTime(tag.H, tag.L) <= t)
        onT = FSDB_RC_SUCCESS == h->ffrGotoXTag((void *)&tag);
      if (dir > 0 && !past) {
        if (!onT) { h->ffrGetMinXTag((void *)&tag); h->ffrGotoXTag((void *)&tag); }
        bool have = false, more = true;  // `cur` holds the latest change at time `ct`
        uint64_t ct = 0;
        while (more) {
          if ((++steps & 4095) == 0 && bgStop()) { stopped = true; break; }
          h->ffrGetXTag(&at);
          const uint64_t tt = combineTime(at.H, at.L);
          if (have && tt != ct) {  // ct's group is complete
            if (ct > t) {
              if (ct > bound) { have = false; break; }
              if (ev || cur != prev) { scanned++; if (hitOf(prev, cur, ct)) { found = (double)ct; have = false; break; } }
            }
            prev.swap(cur);
          }
          grab(cur);  // the last change at a time wins
          ct = tt;
          have = true;
          more = FSDB_RC_SUCCESS == h->ffrGotoNextVC();
        }
        if (!stopped && have && ct > t && ct <= bound && (ev || cur != prev)) { scanned++; if (hitOf(prev, cur, ct)) found = (double)ct; }
      } else if (dir < 0 && onT) {
        // Start at the very last change <= t (the reader may land on the first of a time's changes).
        while (FSDB_RC_SUCCESS == h->ffrGotoNextVC()) {
          h->ffrGetXTag(&at);
          if (combineTime(at.H, at.L) > t) { h->ffrGotoPrevVC(); break; }
        }
        // Walking back, the first change met at a time is that time's value; it
        // counts if it differs from the value of the next time met.
        bool have = false, more = true;  // `cur` = value of time `ct`
        uint64_t ct = 0;
        while (more) {
          if ((++steps & 4095) == 0 && bgStop()) { stopped = true; break; }
          h->ffrGetXTag(&at);
          const uint64_t tt = combineTime(at.H, at.L);
          if (tt < t && !(have && tt == ct)) {
            grab(prev);  // the value in effect before ct
            if (have) {
              if (ct < bound) { have = false; break; }
              if (ev || cur != prev) { scanned++; if (hitOf(prev, cur, ct)) { found = (double)ct; have = false; break; } }
            }
            cur.swap(prev);
            ct = tt;
            have = true;
          }
          more = FSDB_RC_SUCCESS == h->ffrGotoPrevVC();
        }
        if (!stopped && have && ct >= bound) {  // the earliest group: before it, all x
          std::fill(prev.begin(), prev.end(), 2);
          if (ev || cur != prev) { scanned++; if (hitOf(prev, cur, ct)) found = (double)ct; }
        }
      }
    }
    h->ffrFree();
    scope.unload(id);
    if (stopped && found < 0) { o.Set("yielded", Napi::Boolean::New(env, true)); continue; }
    o.Set("t", found < 0 ? env.Null() : Napi::Number::New(env, found));
    o.Set("scanned", Napi::Number::New(env, scanned));
  }
  readerWindowAll();
  return out;
}

// ---- diagnostics: reader cost with a view window (measurements) ----
// readerProbe(id, s, e, seeks, useWindow) -> {loadMs, walkMs, seekMs, count, walked, first, last,
//   atS: {t, value}, bits}: optionally set the reader's view window to [s, e], load the
//   signal, walk every loaded change, then `seeks` gotoXTag+getVC at evenly spaced times
//   in [s, e]; unload and reset the view window to the whole file.
Napi::Value readerProbe(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  const fsdbVarIdcode id = (fsdbVarIdcode)argI64(info[0]);
  const uint64_t s = argTime(info[1]), e = argTime(info[2]);
  const uint32_t seeks = info[3].As<Napi::Number>().Uint32Value();
  const bool useWin = info[4].ToBoolean().Value();
  using clk = std::chrono::steady_clock;
  auto msSince = [](clk::time_point a) { return std::chrono::duration<double, std::milli>(clk::now() - a).count(); };
  Napi::Object o = Napi::Object::New(env);
  o.Set("countBefore", Napi::Number::New(env, (double)fsdb_obj->ffrGetVCCount(id)));
  auto t = clk::now();
  if (useWin) {
    fsdbTag64 a, b; setTag(a, s); setTag(b, e);
    const bool was = fsdb_obj->ffrIsViewWindowSet();
    o.Set("setRc", Napi::Number::New(env, (int)(was ? fsdb_obj->ffrResetViewWindow((fsdbXTag *)&a, (fsdbXTag *)&b) : fsdb_obj->ffrSetViewWindow((fsdbXTag *)&a, (fsdbXTag *)&b))));
    g_winNarrow = true;  // so the next whole load (or readerWindowAll) widens it again
    o.Set("wasSet", Napi::Boolean::New(env, was));
  }
  fsdb_obj->ffrAddToSignalList(id);
  fsdb_obj->ffrLoadSignals();
  fsdb_obj->ffrResetSignalList();
  o.Set("loadMs", Napi::Number::New(env, msSince(t)));
  o.Set("count", Napi::Number::New(env, (double)fsdb_obj->ffrGetVCCount(id)));
  ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(id);
  if (h) {
    const uint32_t bits = h->ffrGetBitSize();
    o.Set("bits", Napi::Number::New(env, bits));
    o.Set("incore", Napi::Boolean::New(env, h->ffrHasIncoreVC()));
    fsdbTag64 tag;
    t = clk::now();
    double walked = 0, first = -1, last = -1;
    if (FSDB_RC_SUCCESS == h->ffrGetMinXTag((void *)&tag) && FSDB_RC_SUCCESS == h->ffrGotoXTag((void *)&tag)) {
      do {
        h->ffrGetXTag(&tag);
        byte_T *vc; h->ffrGetVC(&vc);
        const double tt = (double)combineTime(tag.H, tag.L);
        if (first < 0) first = tt;
        last = tt; walked++;
      } while (FSDB_RC_SUCCESS == h->ffrGotoNextVC());
    }
    o.Set("walkMs", Napi::Number::New(env, msSince(t)));
    o.Set("walked", Napi::Number::New(env, walked));
    o.Set("first", Napi::Number::New(env, first));
    o.Set("last", Napi::Number::New(env, last));
    auto valueAt = [&](uint64_t at, double &tAt) -> std::string {
      fsdbTag64 g; setTag(g, at);
      if (FSDB_RC_SUCCESS != h->ffrGotoXTag((void *)&g)) { tAt = -1; return ""; }
      h->ffrGetXTag(&g);
      tAt = (double)combineTime(g.H, g.L);
      byte_T *vc; h->ffrGetVC(&vc);
      std::string v(bits, '?');
      for (uint32_t j = 0; j < bits; j++) v[j] = "01xz"[vc[j] & 3];
      return v;
    };
    t = clk::now();
    double tAt = 0;
    for (uint32_t k = 0; k < seeks; k++) valueAt(s + (uint64_t)((double)(e - s) * k / std::max<uint32_t>(1, seeks)), tAt);
    o.Set("seekMs", Napi::Number::New(env, msSince(t)));
    Napi::Object atS = Napi::Object::New(env);
    const std::string v = valueAt(s, tAt);
    atS.Set("t", Napi::Number::New(env, tAt));
    atS.Set("value", Napi::String::New(env, v.substr(0, 64)));
    o.Set("atS", atS);
    h->ffrFree();
  }
  fsdb_obj->ffrUnloadSignals(id);
  if (useWin && info.Length() > 5 && info[5].ToBoolean().Value()) {  // widen back to the whole file
    fsdbTag64 a, b; setTag(a, 0); setTag(b, UINT64_MAX >> 1);
    o.Set("resetRc", Napi::Number::New(env, (int)fsdb_obj->ffrResetViewWindow((fsdbXTag *)&a, (fsdbXTag *)&b)));
    g_winNarrow = false;
  }
  return o;
}

// ---- cold reads with view windows (no full walk, nothing cached) ----
// Loads go in batches like cacheLoad's (<= kLoadBatch signals, kLoadBatchBits bits).
template <class F> static void forBatches(const std::vector<fsdbVarIdcode> &ids, F each) {
  for (size_t i = 0; i < ids.size();) {
    size_t j = i;
    uint64_t bitsSum = 0;
    while (j < ids.size() && j - i < kLoadBatch && (j == i || bitsSum < kLoadBatchBits)) {
      ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(ids[j]);
      bitsSum += h ? std::max<uint32_t>(1, h->ffrGetBitSize()) : 1;
      if (h) h->ffrFree();
      fsdb_obj->ffrAddToSignalList(ids[j]);
      j++;
    }
    const auto t = std::chrono::steady_clock::now();
    ReaderScope batch;  // unloads this batch even if `each` throws (the window is the caller's)
    batch.widen = false;
    batch.loaded.assign(ids.begin() + i, ids.begin() + j);
    fsdb_obj->ffrLoadSignals();
    fsdb_obj->ffrResetSignalList();
    const double loadMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
    // Unload only after the whole batch: an id listed twice must still be loaded
    // for its second entry (the scope unloads them if `each` throws).
    for (size_t k = i; k < j; k++) each(k, loadMs);
    for (size_t k = i; k < j; k++) batch.unload(ids[k]);
    i = j;
  }
}

// coldValueAt(ids[], t) -> [string | {error}]: the value in effect at t of
// signals that aren't stored, read with a [t, t] view window: one goto, one
// value, no walk, nothing kept. As cacheValueAt: all x before the first change
// (the normalized stream's value at t is always the reader's last change <= t).
Napi::Value coldValueAt(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 2) || !CHECK_ARRAY(env, info[0])) return env.Undefined();
  Napi::Array arr = info[0].As<Napi::Array>();
  const uint64_t t = argTime(info[1]);
  std::vector<fsdbVarIdcode> ids;
  for (uint32_t i = 0; i < arr.Length(); i++) ids.push_back((fsdbVarIdcode)argI64(arr.Get(i)));
  Napi::Array out = Napi::Array::New(env);
  ReaderScope scope;
  readerWindow(t, t);
  forBatches(ids, [&](size_t k, double) {
    ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(ids[k]);
    std::string err;
    bool f32 = false;
    int kind = -1;
    if (!h) err = "no traverse handle";
    else kind = valueKind(h, f32, err);
    if (kind < 0) {
      Napi::Object o = Napi::Object::New(env);
      o.Set("error", Napi::String::New(env, err));
      out.Set((uint32_t)k, o);
    } else {
      const uint32_t bits = h->ffrGetBitSize();
      std::string v = kind == kBits ? std::string(bits, 'x') : std::string("x");
      fsdbTag64 g;
      setTag(g, t);
      bool on = h->ffrHasIncoreVC() && FSDB_RC_SUCCESS == h->ffrGotoXTag((void *)&g);
      if (!on && h->ffrHasIncoreVC() && FSDB_RC_SUCCESS == h->ffrGetMaxXTag((void *)&g) && combineTime(g.H, g.L) <= t)
        on = FSDB_RC_SUCCESS == h->ffrGotoXTag((void *)&g);  // t is past the last change: the value is the last one
      if (on) {
        // The value at t is the LAST change <= t. This reader lands on the last
        // of same-time changes (helper-v2's glitch test), but don't rely on it: step
        // forward while the next change is still <= t.
        for (;;) {
          if (FSDB_RC_SUCCESS != h->ffrGotoNextVC()) break;
          fsdbTag64 nx;
          h->ffrGetXTag(&nx);
          if (combineTime(nx.H, nx.L) > t) { h->ffrGotoPrevVC(); break; }
        }
        h->ffrGetXTag(&g);
        if (combineTime(g.H, g.L) <= t) {
          byte_T *vc;
          h->ffrGetVC(&vc);
          if (kind != kBits) v = vcText(vc, kind, f32);
          else for (uint32_t j = 0; j < bits; j++) v[j] = "01xz"[vc[j] & 3];
        }
      }
      out.Set((uint32_t)k, Napi::String::New(env, v));
    }
    if (h) h->ffrFree();
  });
  readerWindowAll();
  return out;
}

// cacheLastChange(id, t) -> {t, value} | null: a stored signal's last (normalized) change at or
// before t, and its value (null: no change yet, the value is all x).
Napi::Value cacheLastChange(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 2)) return env.Undefined();
  SigStore *s = storeGet(env, info[0]);
  if (!s) return env.Undefined();
  const size_t k = upperIdx(s, argTime(info[1]), 0, s->times.size());
  if (k == 0) return env.Null();
  std::string v(s->bits, 'x');
  putChars(s, k - 1, (uint8_t *)&v[0]);
  Napi::Object o = Napi::Object::New(env);
  o.Set("t", Napi::Number::New(env, (double)s->times[k - 1]));
  o.Set("value", Napi::String::New(env, v));
  return o;
}

// coldValueNear(ids[], t, span) -> [{t, value} | {none: true, value} | {error}]: for signals
// that aren't stored, one view window [lo, t] (lo = t - span, at least 0): the value at t and,
// if there is one in [lo, t], the last normalized change (same-time changes count as their
// last value; a change to the value already in effect is none). The window starts at lo - 1,
// so whatever the reader gives before lo (its synthetic first change) is the value in effect
// on entry; with lo = 0 that is all x. A rebuilt signal's cost scales with the span; a stored
// one's mostly doesn't. Nothing is walked into the store or kept.
// The value at t and the last real change in [lo, t] of one loaded signal (coldValueNear,
// warmNear): {t, value} | {none: true, value} | {error}.
static Napi::Object nearOf(Napi::Env env, fsdbVarIdcode id, uint64_t t, uint64_t lo) {
  ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(id);
  std::string err;
  if (!h) err = "no traverse handle";
  else if (h->ffrGetBitSize() == 0) err = "reader reports 0 bits (alias?)";
  else if (h->ffrGetBytesPerBit() != FSDB_BYTES_PER_BIT_1B) err = "unsupported encoding";
  Napi::Object o = Napi::Object::New(env);
  if (!err.empty()) {
    o.Set("error", Napi::String::New(env, err));
  } else {
    const uint32_t bits = h->ffrGetBitSize();
    std::string cur(bits, 'x'), grp, v(bits, 'x');
    uint64_t gt = 0, lastT = 0;
    bool have = false, found = false;
    fsdbTag64 g;
    if (h->ffrHasIncoreVC() && FSDB_RC_SUCCESS == h->ffrGetMinXTag((void *)&g) && FSDB_RC_SUCCESS == h->ffrGotoXTag((void *)&g)) {
      do {
        h->ffrGetXTag(&g);
        const uint64_t tt = combineTime(g.H, g.L);
        if (tt > t) break;
        byte_T *vc;
        h->ffrGetVC(&vc);
        for (uint32_t j = 0; j < bits; j++) v[j] = "01xz"[vc[j] & 3];
        if (tt < lo) { cur = v; continue; }  // in effect on entry to [lo, t]
        if (have && tt != gt && grp != cur) { cur = grp; lastT = gt; found = true; }
        gt = tt; grp = v; have = true;
      } while (FSDB_RC_SUCCESS == h->ffrGotoNextVC());
      if (have && grp != cur) { cur = grp; lastT = gt; found = true; }
    }
    if (found) o.Set("t", Napi::Number::New(env, (double)lastT));
    else o.Set("none", Napi::Boolean::New(env, true));
    o.Set("value", Napi::String::New(env, cur));
  }
  if (h) h->ffrFree();
  return o;
}

Napi::Value coldValueNear(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 3) || !CHECK_ARRAY(env, info[0])) return env.Undefined();
  Napi::Array arr = info[0].As<Napi::Array>();
  const uint64_t t = argTime(info[1]), span = argTime(info[2]);
  const uint64_t lo = t > span ? t - span : 0;
  std::vector<fsdbVarIdcode> ids;
  for (uint32_t i = 0; i < arr.Length(); i++) ids.push_back((fsdbVarIdcode)argI64(arr.Get(i)));
  Napi::Array out = Napi::Array::New(env);
  ReaderScope scope;
  readerWindow(lo > 0 ? lo - 1 : 0, t);
  forBatches(ids, [&](size_t k, double) { out.Set((uint32_t)k, nearOf(env, ids[k], t, lo)); });
  readerWindowAll();
  return out;
}

// cacheWindowCold(ids[], t0, t1, buckets) -> [{signalId, exact, count, records, counts?, loadMs, walkMs} | {signalId, error}]
// A window over a short range of signals that aren't stored: load only
// [t0 - 1, t1] (the reader's synthetic first change at t0 - 1 is the value in
// effect before t0, so normalization and the t0 record come out exactly as
// from the whole signal), walk that into a scratch store, answer, free it.
Napi::Value cacheWindowCold(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 4) || !CHECK_ARRAY(env, info[0])) return env.Undefined();
  Napi::Array arr = info[0].As<Napi::Array>();
  uint64_t t0 = argTime(info[1]), t1 = argTime(info[2]);
  if (t1 < t0) std::swap(t0, t1);
  uint32_t B = info[3].As<Napi::Number>().Uint32Value();
  if (B == 0) B = 1;
  const size_t budget = argBudget(info, 4);
  std::vector<fsdbVarIdcode> ids;
  for (uint32_t i = 0; i < arr.Length(); i++) ids.push_back((fsdbVarIdcode)argI64(arr.Get(i)));
  using clk = std::chrono::steady_clock;
  auto msSince = [](clk::time_point a) { return std::chrono::duration<double, std::milli>(clk::now() - a).count(); };
  Napi::Array out = Napi::Array::New(env);
  ReaderScope scope;
  readerWindow(t0 > 0 ? t0 - 1 : 0, t1);
  forBatches(ids, [&](size_t k, double loadMs) {
    auto tw = clk::now();
    std::string err;
    SigStore *s = walkSignal(ids[k], err);
    Napi::Object o = s ? windowOf(env, s, t0, t1, B, budget) : Napi::Object::New(env);
    o.Set("signalId", Napi::Number::New(env, (double)ids[k]));
    if (!s) o.Set("error", Napi::String::New(env, err));
    o.Set("loadMs", Napi::Number::New(env, loadMs));
    o.Set("walkMs", Napi::Number::New(env, msSince(tw)));
    delete s;
    out.Set((uint32_t)k, o);
  });
  readerWindowAll();
  return out;
}

// cacheEvict(keepIds[]): evict least recently used signals other than keepIds
// until the store is within its limit (after loads done with evict = false).
Napi::Value cacheEvict(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 1) || !CHECK_ARRAY(env, info[0])) return env.Undefined();
  Napi::Array arr = info[0].As<Napi::Array>();
  std::vector<int64_t> keep;
  for (uint32_t i = 0; i < arr.Length(); i++) keep.push_back(argI64(arr.Get(i)));
  storeEvict(keep);
  return env.Undefined();
}

// cacheSetBounds(signalCapBytes, rssHardBytes): the hard bounds above (0 = none).
Napi::Value cacheSetBounds(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 2) || !CHECK_NUMBER(env, info[0]) || !CHECK_NUMBER(env, info[1])) return env.Undefined();
  g_signalCap = (size_t)std::max(0.0, info[0].As<Napi::Number>().DoubleValue());
  g_rssHard = (size_t)std::max(0.0, info[1].As<Napi::Number>().DoubleValue());
  return env.Undefined();
}

// ---- persistent store cache (the search index's .vvz files) ----
// cacheAdoptIndex(id, path, evict = true) -> {count, bytes, bits} | {error, tooLarge?}:
// load a signal's normalized store from its index file instead of walking it
// (spike_rvfi: ~70 ms instead of ~1.6 s), with readIndexFile's checks. A file
// over the signal cap is refused from its header (tooLarge: keep the file).
// evict = false leaves the LRU alone (as cacheLoad's; searchAll's candidates).
Napi::Value cacheAdoptIndex(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 2) || !CHECK_STRING(env, info[1])) return env.Undefined();
  const int64_t id = argI64(info[0]);
  Napi::Object o = Napi::Object::New(env);
  std::string err;
  const bool evict = info.Length() < 3 || info[2].ToBoolean().Value();
  bool tooLarge = false;
  SigStore *s = readIndexFile(info[1].As<Napi::String>().Utf8Value(), err, g_signalCap, &tooLarge);
  if (!s) { o.Set("error", Napi::String::New(env, err)); if (tooLarge) o.Set("tooLarge", Napi::Boolean::New(env, true)); return o; }
  if (g_signalCap && s->bytes() > g_signalCap) { delete s; o.Set("error", Napi::String::New(env, capError(g_signalCap))); o.Set("tooLarge", Napi::Boolean::New(env, true)); return o; }
  storeFree(id);
  s->lastUsed = ++g_clock;
  g_store[id] = s;
  g_bytes += s->bytes();
  if (evict) storeEvict({id});
  o.Set("count", Napi::Number::New(env, (double)s->times.size()));
  o.Set("bytes", Napi::Number::New(env, (double)s->bytes()));
  o.Set("bits", Napi::Number::New(env, s->bits));
  return o;
}

// cacheWriteIndex(id, path) -> {bytes, rawBytes, count} | {error}: write a stored
// signal to an index file (no re-walk).
Napi::Value cacheWriteIndex(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 2) || !CHECK_STRING(env, info[1])) return env.Undefined();
  Napi::Object o = Napi::Object::New(env);
  auto it = g_store.find(argI64(info[0]));
  if (it == g_store.end()) { o.Set("error", Napi::String::New(env, "signal not loaded")); return o; }
  const SigStore *s = it->second;
  if (s->kind != kBits) { o.Set("error", Napi::String::New(env, "string and real signals are not persisted")); return o; }
  uint64_t bytes = 0;
  bool yielded = false;
  if (!writeIndexFile(s, info[1].As<Napi::String>().Utf8Value(), bytes, &yielded)) {
    o.Set("error", Napi::String::New(env, yielded ? "yielded" : "cannot write index file"));
    if (yielded) o.Set("yielded", Napi::Boolean::New(env, true));
    return o;
  }
  o.Set("bytes", Napi::Number::New(env, (double)bytes));
  o.Set("rawBytes", Napi::Number::New(env, (double)(17 + s->times.size() * 8 + s->val.size() + s->xz.size())));
  o.Set("count", Napi::Number::New(env, (double)s->times.size()));
  o.Set("bits", Napi::Number::New(env, s->bits));
  o.Set("xz", Napi::Boolean::New(env, !s->xz.empty()));
  return o;
}

// ---- warm readers: navigation DB kept (ffrSetLoadNavDBOnlyOnce) ----
// The reader keeps the file's navigation DB after the first load, so a view window of the same
// signals costs ~1-20 ms instead of a per-call floor (~110 ms on 1.7 GB, ~650 ms on 10 GB). Its
// documented condition: every signal read later must be in the first load (others can come back
// WRONG). So a warm process loads its set once (warmLoad) and keeps that signal list for good;
// warmWindow refuses any id outside it. Values are unloaded after every window.
static bool g_hotOn = false;
static std::unordered_set<int64_t> g_hotSet;

// readerNavOnce(): before any load.
Napi::Value readerNavOnce(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!fsdb_obj) { Napi::Error::New(env, "no file open").ThrowAsJavaScriptException(); return env.Undefined(); }
  readerWindowAll();
  g_hotEnd = fileEnd();
  fsdb_obj->ffrSetLoadNavDBOnlyOnce(true);
  g_hotOn = true;
  return env.Undefined();
}

// warmLoad(ids[]) -> [{signalId} | {signalId, error}]: fixes the signal list (unreadable signals are
// left out); the first warmWindow is the first load.
Napi::Value warmLoad(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 1) || !CHECK_ARRAY(env, info[0])) return env.Undefined();
  if (!g_hotOn || !g_hotSet.empty()) { Napi::Error::New(env, "warmLoad: not a fresh navDB-once reader").ThrowAsJavaScriptException(); return env.Undefined(); }
  Napi::Array arr = info[0].As<Napi::Array>();
  Napi::Array out = Napi::Array::New(env);
  std::vector<fsdbVarIdcode> ok;
  for (uint32_t i = 0; i < arr.Length(); i++) {
    const fsdbVarIdcode id = (fsdbVarIdcode)argI64(arr.Get(i));
    Napi::Object o = Napi::Object::New(env);
    o.Set("signalId", Napi::Number::New(env, (double)id));
    ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(id);
    std::string err;
    if (!h) err = "no traverse handle";
    else if (h->ffrGetBitSize() == 0) err = "reader reports 0 bits (alias?)";
    else if (h->ffrGetBytesPerBit() != FSDB_BYTES_PER_BIT_1B) err = "unsupported encoding";
    if (h) h->ffrFree();
    if (!err.empty()) o.Set("error", Napi::String::New(env, err));
    else if (!g_hotSet.count(id)) { g_hotSet.insert(id); ok.push_back(id); }
    out.Set(i, o);
  }
  // (the first window's load is the first load, as in the reader's own example)
  for (fsdbVarIdcode id : ok) fsdb_obj->ffrAddToSignalList(id);
  return out;
}

// warmWindow(ids[], t0, t1, buckets, textBudget?) -> as cacheWindowCold, for ids of the first load only.
// A warm load that leaves the process over the hard bound (cacheSetBounds, set by a warm reader's
// open) is undone before anything is walked, as on the cold path (#5): each id answers an error.
static bool warmOverBound(Napi::Env env, const std::vector<fsdbVarIdcode> &ids, Napi::Array &out) {
  if (!g_rssHard || processRss() <= g_rssHard) return false;
  fsdb_obj->ffrUnloadSignals();
  for (size_t k = 0; k < ids.size(); k++) {
    Napi::Object o = Napi::Object::New(env);
    o.Set("signalId", Napi::Number::New(env, (double)ids[k]));
    o.Set("error", Napi::String::New(env, "warm reader memory limit (reader load over " + std::to_string(g_rssHard >> 20) + " MB)"));
    out.Set((uint32_t)k, o);
  }
  return true;
}

Napi::Value warmWindow(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 4) || !CHECK_ARRAY(env, info[0])) return env.Undefined();
  Napi::Array arr = info[0].As<Napi::Array>();
  uint64_t t0 = argTime(info[1]), t1 = argTime(info[2]);
  if (t1 < t0) std::swap(t0, t1);
  uint32_t B = info[3].As<Napi::Number>().Uint32Value();
  if (B == 0) B = 1;
  std::vector<fsdbVarIdcode> ids;
  for (uint32_t i = 0; i < arr.Length(); i++) {
    const fsdbVarIdcode id = (fsdbVarIdcode)argI64(arr.Get(i));
    if (!g_hotSet.count(id)) { Napi::Error::New(env, "warmWindow: signal not in the first load").ThrowAsJavaScriptException(); return env.Undefined(); }
    ids.push_back(id);
  }
  using clk = std::chrono::steady_clock;
  auto msSince = [](clk::time_point a) { return std::chrono::duration<double, std::milli>(clk::now() - a).count(); };
  Napi::Array out = Napi::Array::New(env);
  readerWindow(t0 > 0 ? t0 - 1 : 0, t1);
  const auto tl = clk::now();
  fsdb_obj->ffrLoadSignals();  // the whole set (its list is fixed)
  const double loadMs = msSince(tl);
  if (warmOverBound(env, ids, out)) return out;
  try {
    for (size_t k = 0; k < ids.size(); k++) {
      auto tw = clk::now();
      std::string err;
      SigStore *s = walkSignal(ids[k], err);
      Napi::Object o = s ? windowOf(env, s, t0, t1, B, argBudget(info, 4)) : Napi::Object::New(env);
      o.Set("signalId", Napi::Number::New(env, (double)ids[k]));
      if (!s) o.Set("error", Napi::String::New(env, err));
      o.Set("loadMs", Napi::Number::New(env, loadMs));
      o.Set("walkMs", Napi::Number::New(env, msSince(tw)));
      delete s;
      out.Set((uint32_t)k, o);
    }
  } catch (...) {
    fsdb_obj->ffrUnloadSignals();
    throw;
  }
  fsdb_obj->ffrUnloadSignals();
  return out;
}

// warmNear(ids[], t, span) -> as coldValueNear, for ids of the first load only (trace-X's
// fan-in reads on a warm reader; span 0 is the value at t).
Napi::Value warmNear(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 3) || !CHECK_ARRAY(env, info[0])) return env.Undefined();
  Napi::Array arr = info[0].As<Napi::Array>();
  const uint64_t t = argTime(info[1]), span = argTime(info[2]);
  const uint64_t lo = t > span ? t - span : 0;
  std::vector<fsdbVarIdcode> ids;
  for (uint32_t i = 0; i < arr.Length(); i++) {
    const fsdbVarIdcode id = (fsdbVarIdcode)argI64(arr.Get(i));
    if (!g_hotSet.count(id)) { Napi::Error::New(env, "warmNear: signal not in the first load").ThrowAsJavaScriptException(); return env.Undefined(); }
    ids.push_back(id);
  }
  Napi::Array out = Napi::Array::New(env);
  readerWindow(lo > 0 ? lo - 1 : 0, t);
  fsdb_obj->ffrLoadSignals();  // the whole set (its list is fixed)
  if (warmOverBound(env, ids, out)) return out;
  try {
    for (size_t k = 0; k < ids.size(); k++) {
      Napi::Object o = nearOf(env, ids[k], t, lo);
      o.Set("signalId", Napi::Number::New(env, (double)ids[k]));
      out.Set((uint32_t)k, o);
    }
  } catch (...) {
    fsdb_obj->ffrUnloadSignals();
    throw;
  }
  fsdb_obj->ffrUnloadSignals();
  return out;
}
