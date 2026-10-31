// Part of cmux's FSDB helper v2, written for cmux. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), whose addon it extends; see ../../LICENSE.
// ---- cmux additions (helper v2): derived-signal evaluator core ----
//
// No Napi or FsdbReader here, so test/deval-test.cpp can build it standalone
// with ASan/UBSan and fuzz it against test/svref.js.
//
// A program is a flat list of nodes (operands before users, last = result),
// produced by expr.js with SystemVerilog (IEEE 1800 §11.6) sizing already
// applied: every context-determined operand arrives extended to its node's
// width by an explicit EXT node, so ops here only check widths, they never
// extend. Values are 4-state bit vectors, bit 0 = LSB, as two word planes v
// (value) and x (unknown); z is read as x, and v & x == 0 always.
//   bitwise ops per bit (0 & x = 0, 1 | x = 1); + - * / % and relational ops
//   give all x if any operand bit is x (and / % by 0 give x); == != give x
//   only when the known bits don't already decide; === !== compare the planes
//   exactly (never x; x and z are not told apart); shifts by an x amount give
//   all x; ?: with an x condition merges both sides bitwise. `s` marks signed
//   EXT (sign extension), < > <= >=, / %, and >>> (arithmetic).
#pragma once
#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

enum DOp {
  D_SIG, D_CONST, D_SEL, D_CONCAT, D_REPL, D_NOT, D_AND, D_OR, D_XOR, D_RAND, D_ROR, D_RXOR,
  D_LNOT, D_LAND, D_LOR, D_EQ, D_NE, D_LT, D_GT, D_LE, D_GE, D_ADD, D_SUB, D_TERN, D_BOOL,
  D_EXT, D_MUL, D_DIV, D_MOD, D_SHL, D_SHR, D_ASHR, D_CEQ, D_CNE,
  D_COUNT
};

static const uint32_t kMaxExprBits = 65536;            // any node (same cap as expr.js)
static const uint64_t kMaxProgramWords = 1ull << 20;   // sum of node words (8 MB per plane)
static const size_t kMaxProgramNodes = 100000;

struct DNode {
  int op = D_CONST;
  uint32_t w = 1, nw = 1;
  int a = -1, b = -1, c = -1, k = -1;
  bool s = false;
  std::vector<int> args;
  int64_t lo = 0;
  uint32_t n = 0;
  std::vector<uint64_t> v, x;
};

static inline uint64_t topMask(uint32_t w) { return (w & 63) ? ((1ull << (w & 63)) - 1) : ~0ull; }
static inline void maskTop(DNode &d) { d.v[d.nw - 1] &= topMask(d.w); d.x[d.nw - 1] &= topMask(d.w); }
static inline void clearNode(DNode &d) { std::fill(d.v.begin(), d.v.end(), 0); std::fill(d.x.begin(), d.x.end(), 0); }
static inline void allX(DNode &d) { for (uint32_t j = 0; j < d.nw; j++) { d.v[j] = 0; d.x[j] = ~0ull; } maskTop(d); }
static inline void set1(DNode &d, int b) { d.v[0] = b == 1; d.x[0] = b == 2; }
static inline int bitOf(const DNode &d, uint64_t i) {  // 0, 1, 2 (x); i < d.w
  if ((d.x[i >> 6] >> (i & 63)) & 1) return 2;
  return (int)((d.v[i >> 6] >> (i & 63)) & 1);
}

// 64 bits of a plane starting at bit p (may be negative or past w); bits
// outside [0, w) read as `fill` (all ones or zero). Word ops only.
static inline uint64_t extract(const std::vector<uint64_t> &pl, uint32_t w, int64_t p, bool fill) {
  const int64_t lo = std::max<int64_t>(p, 0), hi = std::min<int64_t>(p + 64, (int64_t)w);  // in-range source bits
  uint64_t r = 0, in = 0;
  if (lo < hi) {
    const uint64_t wi = (uint64_t)lo >> 6, sh = (uint64_t)lo & 63, n = (uint64_t)(hi - lo);
    uint64_t v = pl[wi] >> sh;
    if (sh && wi + 1 < pl.size()) v |= pl[wi + 1] << (64 - sh);
    const uint64_t m = n < 64 ? (1ull << n) - 1 : ~0ull;
    r = (v & m) << (lo - p);
    in = m << (lo - p);
  }
  return fill ? (r | ~in) : r;
}
// OR the low n (<= 64) bits of val into a plane at bit `at` (at + n <= plane bits).
static inline void orBits(std::vector<uint64_t> &pl, uint64_t at, uint64_t val, uint32_t n) {
  if (n < 64) val &= (1ull << n) - 1;
  if (!val) return;
  const uint64_t wi = at >> 6, sh = at & 63;
  pl[wi] |= val << sh;
  if (sh && sh + n > 64) pl[wi + 1] |= val >> (64 - sh);
}
// dst bits [at, at+n) |= src bits [from, from+n); src bits outside [0, src.w) read as x.
static inline void copyRange(DNode &dst, uint64_t at, const DNode &src, int64_t from, uint64_t n) {
  for (uint64_t off = 0; off < n; off += 64) {
    const uint32_t k = (uint32_t)std::min<uint64_t>(64, n - off);
    const uint64_t xv = extract(src.x, src.w, from + (int64_t)off, true);
    const uint64_t vv = extract(src.v, src.w, from + (int64_t)off, false) & ~xv;
    orBits(dst.v, at + off, vv, k);
    orBits(dst.x, at + off, xv, k);
  }
}
static inline void fillRange(DNode &d, uint64_t at, uint64_t n, int b) {  // b: 1 or 2
  std::vector<uint64_t> &pl = b == 2 ? d.x : d.v;
  for (uint64_t off = 0; off < n; off += 64) orBits(pl, at + off, ~0ull, (uint32_t)std::min<uint64_t>(64, n - off));
}
// Truth value: 1 if any bit is 1, else x if any bit is x, else 0.
static inline int truth(const DNode &d) {
  uint64_t av = 0, ax = 0;
  for (uint32_t i = 0; i < d.nw; i++) { av |= d.v[i]; ax |= d.x[i]; }
  return av ? 1 : (ax ? 2 : 0);
}
static inline bool anyX(const DNode &d) {
  for (uint32_t i = 0; i < d.nw; i++) if (d.x[i]) return true;
  return false;
}
static inline bool isZero(const std::vector<uint64_t> &a) {
  for (uint64_t q : a) if (q) return false;
  return true;
}
static inline bool negative(const std::vector<uint64_t> &a, uint32_t w) { return (a[(w - 1) >> 6] >> ((w - 1) & 63)) & 1; }
static void negate(std::vector<uint64_t> &a, uint32_t w) {  // two's complement at width w
  unsigned __int128 c = 1;
  for (auto &q : a) { const unsigned __int128 s = (unsigned __int128)(~q) + c; q = (uint64_t)s; c = s >> 64; }
  a.back() &= topMask(w);
}
static int cmpU(const std::vector<uint64_t> &a, const std::vector<uint64_t> &b) {
  for (size_t i = a.size(); i-- > 0;) if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}
// Unsigned long division of known values at width w (b != 0).
static void divmodU(const std::vector<uint64_t> &a, const std::vector<uint64_t> &b, uint32_t w,
                    std::vector<uint64_t> &q, std::vector<uint64_t> &r) {
  const size_t nw = a.size();
  q.assign(nw, 0); r.assign(nw, 0);
  if (nw == 1) { q[0] = a[0] / b[0]; r[0] = a[0] % b[0]; return; }
  for (uint32_t i = w; i-- > 0;) {
    uint64_t carry = (a[i >> 6] >> (i & 63)) & 1;  // r = r << 1 | bit
    for (size_t j = 0; j < nw; j++) { const uint64_t nc = r[j] >> 63; r[j] = (r[j] << 1) | carry; carry = nc; }
    if (carry || cmpU(r, b) >= 0) {  // a bit shifted out of the top word means r > b
      unsigned __int128 br = 0;
      for (size_t j = 0; j < nw; j++) { const unsigned __int128 dd = (unsigned __int128)r[j] - b[j] - br; r[j] = (uint64_t)dd; br = (dd >> 64) & 1; }
      q[i >> 6] |= 1ull << (i & 63);
    }
  }
}

static void evalNode(std::vector<DNode> &P, size_t i) {
  DNode &d = P[i];
  switch (d.op) {
    case D_SIG: case D_CONST: return;  // filled by the merge / at load time
    case D_SEL: { clearNode(d); copyRange(d, 0, P[d.a], d.lo, d.w); return; }
    case D_EXT: {
      const DNode &a = P[d.a];
      clearNode(d);
      copyRange(d, 0, a, 0, std::min(a.w, d.w));
      if (d.w > a.w && d.s) {
        const int top = bitOf(a, a.w - 1);
        if (top) fillRange(d, a.w, d.w - a.w, top);
      }
      return;
    }
    case D_CONCAT: {
      clearNode(d);
      uint64_t at = 0;
      for (size_t j = d.args.size(); j-- > 0;) { const DNode &p = P[d.args[j]]; copyRange(d, at, p, 0, p.w); at += p.w; }
      return;
    }
    case D_REPL: {
      clearNode(d);
      const DNode &a = P[d.a];
      for (uint64_t r = 0; r < d.n; r++) copyRange(d, r * a.w, a, 0, a.w);
      return;
    }
    case D_NOT: {
      const DNode &a = P[d.a];
      for (uint32_t j = 0; j < d.nw; j++) { d.x[j] = a.x[j]; d.v[j] = ~a.v[j] & ~a.x[j]; }
      maskTop(d);
      return;
    }
    case D_AND: case D_OR: case D_XOR: {
      const DNode &a = P[d.a], &b = P[d.b];
      for (uint32_t j = 0; j < d.nw; j++) {
        const uint64_t av = a.v[j], ax = a.x[j], bv = b.v[j], bx = b.x[j];
        if (d.op == D_AND) {
          const uint64_t zero = (~av & ~ax) | (~bv & ~bx);
          d.x[j] = (ax | bx) & ~zero;
          d.v[j] = av & bv;
        } else if (d.op == D_OR) {
          d.v[j] = av | bv;
          d.x[j] = (ax | bx) & ~(av | bv);
        } else {
          d.x[j] = ax | bx;
          d.v[j] = (av ^ bv) & ~d.x[j];
        }
      }
      maskTop(d);
      return;
    }
    case D_RAND: {
      const DNode &a = P[d.a];
      bool zero = false;
      for (uint32_t j = 0; j < a.nw; j++) {
        const uint64_t m = j + 1 == a.nw ? topMask(a.w) : ~0ull;
        if ((~a.v[j] & ~a.x[j]) & m) zero = true;
      }
      set1(d, zero ? 0 : (anyX(a) ? 2 : 1));
      return;
    }
    case D_ROR: case D_BOOL: set1(d, truth(P[d.a])); return;
    case D_RXOR: {
      const DNode &a = P[d.a];
      if (anyX(a)) { set1(d, 2); return; }
      int par = 0;
      for (uint32_t j = 0; j < a.nw; j++) par ^= __builtin_parityll(a.v[j]);
      set1(d, par);
      return;
    }
    case D_LNOT: { const int t = truth(P[d.a]); set1(d, t == 2 ? 2 : !t); return; }
    case D_LAND: case D_LOR: {
      const int p = truth(P[d.a]), q = truth(P[d.b]);
      if (d.op == D_LAND) set1(d, (p == 0 || q == 0) ? 0 : (p == 1 && q == 1 ? 1 : 2));
      else set1(d, (p == 1 || q == 1) ? 1 : (p == 0 && q == 0 ? 0 : 2));
      return;
    }
    case D_EQ: case D_NE: {
      const DNode &a = P[d.a], &b = P[d.b];
      bool differ = false, unknown = false;
      for (uint32_t j = 0; j < a.nw; j++) {
        if ((a.v[j] ^ b.v[j]) & ~a.x[j] & ~b.x[j]) differ = true;
        if (a.x[j] | b.x[j]) unknown = true;
      }
      const int eq = differ ? 0 : (unknown ? 2 : 1);
      set1(d, eq == 2 ? 2 : (d.op == D_EQ ? eq : !eq));
      return;
    }
    case D_CEQ: case D_CNE: {
      const DNode &a = P[d.a], &b = P[d.b];
      const bool same = a.v == b.v && a.x == b.x;
      set1(d, (d.op == D_CEQ) == same);
      return;
    }
    case D_LT: case D_GT: case D_LE: case D_GE: {
      const DNode &a = P[d.a], &b = P[d.b];
      if (anyX(a) || anyX(b)) { set1(d, 2); return; }
      int c;
      const bool na = d.s && negative(a.v, a.w), nb = d.s && negative(b.v, b.w);
      if (na != nb) c = na ? -1 : 1;
      else c = cmpU(a.v, b.v);
      const bool r = d.op == D_LT ? c < 0 : d.op == D_GT ? c > 0 : d.op == D_LE ? c <= 0 : c >= 0;
      set1(d, r);
      return;
    }
    case D_ADD: case D_SUB: {
      const DNode &a = P[d.a], &b = P[d.b];
      if (anyX(a) || anyX(b)) { allX(d); return; }
      unsigned __int128 carry = d.op == D_SUB ? 1 : 0;  // a - b = a + ~b + 1
      for (uint32_t j = 0; j < d.nw; j++) {
        const uint64_t q = d.op == D_SUB ? ~b.v[j] : b.v[j];
        const unsigned __int128 s = (unsigned __int128)a.v[j] + q + carry;
        d.v[j] = (uint64_t)s;
        d.x[j] = 0;
        carry = s >> 64;
      }
      maskTop(d);
      return;
    }
    case D_MUL: {  // the low w bits are the same signed or unsigned
      const DNode &a = P[d.a], &b = P[d.b];
      if (anyX(a) || anyX(b)) { allX(d); return; }
      clearNode(d);
      for (uint32_t ii = 0; ii < d.nw; ii++) {
        if (!a.v[ii]) continue;
        unsigned __int128 carry = 0;
        for (uint32_t j = 0; ii + j < d.nw; j++) {
          const unsigned __int128 p = (unsigned __int128)a.v[ii] * b.v[j] + d.v[ii + j] + carry;
          d.v[ii + j] = (uint64_t)p;
          carry = p >> 64;
        }
      }
      maskTop(d);
      return;
    }
    case D_DIV: case D_MOD: {
      const DNode &a = P[d.a], &b = P[d.b];
      if (anyX(a) || anyX(b) || isZero(b.v)) { allX(d); return; }
      std::vector<uint64_t> p = a.v, q = b.v, quo, rem;
      const bool na = d.s && negative(p, d.w), nb = d.s && negative(q, d.w);
      if (na) negate(p, d.w);
      if (nb) negate(q, d.w);
      divmodU(p, q, d.w, quo, rem);
      if (d.op == D_DIV) { if (na != nb) negate(quo, d.w); d.v = quo; }
      else { if (na) negate(rem, d.w); d.v = rem; }
      std::fill(d.x.begin(), d.x.end(), 0);
      maskTop(d);
      return;
    }
    case D_SHL: case D_SHR: case D_ASHR: {
      const DNode &a = P[d.a], &b = P[d.b];
      if (anyX(b)) { allX(d); return; }
      uint64_t amt = b.v[0];
      for (uint32_t j = 1; j < b.nw; j++) if (b.v[j]) amt = UINT64_MAX;
      if (amt > d.w) amt = d.w;
      clearNode(d);
      if (d.op == D_SHL) {
        copyRange(d, amt, a, 0, d.w - amt);
      } else {
        copyRange(d, 0, a, (int64_t)amt, d.w - amt);
        if (d.op == D_ASHR && amt) {
          const int top = bitOf(a, a.w - 1);
          if (top) fillRange(d, d.w - amt, amt, top);
        }
      }
      return;
    }
    case D_TERN: {
      const int t = truth(P[d.a]);
      const DNode &p = P[d.b], &q = P[d.c];
      for (uint32_t j = 0; j < d.nw; j++) {
        if (t == 1) { d.v[j] = p.v[j]; d.x[j] = p.x[j]; }
        else if (t == 0) { d.v[j] = q.v[j]; d.x[j] = q.x[j]; }
        else {
          d.x[j] = p.x[j] | q.x[j] | (p.v[j] ^ q.v[j]);
          d.v[j] = p.v[j] & ~d.x[j];
        }
      }
      maskTop(d);
      return;
    }
  }
}

// The addon doesn't trust programs: every index points backwards, every width
// is within the cap and consistent with its op, operands exist and match.
// Returns "" or an error. opBits[k] = bit width of operand k.
static std::string validateProgram(const std::vector<DNode> &P, const std::vector<uint32_t> &opBits) {
  if (P.empty()) return "empty program";
  if (P.size() > kMaxProgramNodes) return "program too long";
  uint64_t words = 0;
  for (size_t i = 0; i < P.size(); i++) {
    const DNode &d = P[i];
    const std::string at = " (node " + std::to_string(i) + ")";
    if (d.op < 0 || d.op >= D_COUNT) return "bad op" + at;
    if (d.w < 1 || d.w > kMaxExprBits) return "width out of range" + at;
    words += (d.w + 63) / 64;
    if (words > kMaxProgramWords) return "expression too large";
    auto ref = [&](int r) { return r >= 0 && (size_t)r < i; };
    auto W = [&](int r) { return P[r].w; };
    switch (d.op) {
      case D_SIG:
        if (d.k < 0 || (size_t)d.k >= opBits.size() || opBits[d.k] != d.w) return "bad operand reference" + at;
        break;
      case D_CONST: break;
      case D_SEL:
        if (!ref(d.a) || d.lo < -(int64_t)kMaxExprBits || d.lo > (int64_t)kMaxExprBits) return "bad select" + at;
        break;
      case D_EXT: if (!ref(d.a)) return "bad operand" + at; break;
      case D_CONCAT: {
        uint64_t sum = 0;
        if (d.args.empty()) return "empty concatenation" + at;
        for (int r : d.args) { if (!ref(r)) return "bad operand" + at; sum += W(r); }
        if (sum != d.w) return "concatenation width mismatch" + at;
        break;
      }
      case D_REPL:
        if (!ref(d.a) || d.n < 1 || (uint64_t)d.n * W(d.a) != d.w) return "replication width mismatch" + at;
        break;
      case D_NOT:
        if (!ref(d.a) || W(d.a) != d.w) return "width mismatch" + at;
        break;
      case D_AND: case D_OR: case D_XOR: case D_ADD: case D_SUB: case D_MUL: case D_DIV: case D_MOD:
        if (!ref(d.a) || !ref(d.b) || W(d.a) != d.w || W(d.b) != d.w) return "width mismatch" + at;
        break;
      case D_SHL: case D_SHR: case D_ASHR:
        if (!ref(d.a) || !ref(d.b) || W(d.a) != d.w) return "width mismatch" + at;
        break;
      case D_EQ: case D_NE: case D_CEQ: case D_CNE: case D_LT: case D_GT: case D_LE: case D_GE:
        if (!ref(d.a) || !ref(d.b) || W(d.a) != W(d.b) || d.w != 1) return "width mismatch" + at;
        break;
      case D_LAND: case D_LOR:
        if (!ref(d.a) || !ref(d.b) || d.w != 1) return "bad operand" + at;
        break;
      case D_RAND: case D_ROR: case D_RXOR: case D_LNOT: case D_BOOL:
        if (!ref(d.a) || d.w != 1) return "bad operand" + at;
        break;
      case D_TERN:
        if (!ref(d.a) || !ref(d.b) || !ref(d.c) || W(d.b) != d.w || W(d.c) != d.w) return "width mismatch" + at;
        break;
    }
  }
  return "";
}

// Size node planes and load constants (bits: MSB-first '0'/'1'/'x', exactly w chars).
static std::string prepareNode(DNode &d, const std::string &bits) {
  d.nw = (d.w + 63) / 64;
  d.v.assign(d.nw, 0);
  d.x.assign(d.nw, 0);
  if (d.op == D_CONST) {
    if (bits.size() != d.w) return "constant width mismatch";
    for (uint32_t j = 0; j < d.w; j++) {
      const char ch = bits[d.w - 1 - j];
      if (ch == '1') d.v[j >> 6] |= 1ull << (j & 63);
      else if (ch != '0') d.x[j >> 6] |= 1ull << (j & 63);
    }
  }
  if (d.op == D_SIG) { for (uint32_t j = 0; j < d.nw; j++) d.x[j] = ~0ull; maskTop(d); }  // all x before the first change
  return "";
}

// Per-step cost estimate in word operations (for the up-front budget check).
static uint64_t programCost(const std::vector<DNode> &P) {
  uint64_t c = 0;
  for (const DNode &d : P) {
    const uint64_t nw = (d.w + 63) / 64;
    switch (d.op) {
      case D_MUL: c += nw * nw; break;
      case D_DIV: case D_MOD: c += nw == 1 ? 1 : (uint64_t)d.w * nw; break;
      case D_REPL: c += (uint64_t)d.n * ((P[d.a].w + 63) / 64 + 1) + nw; break;
      case D_CONCAT: c += d.args.size() * 2 + nw; break;
      default: c += nw + 1;
    }
  }
  return c;
}

static std::string nodeString(const DNode &d) {  // MSB first
  std::string s(d.w, '0');
  for (uint32_t j = 0; j < d.w; j++) { const int b = bitOf(d, j); s[d.w - 1 - j] = b == 2 ? 'x' : (char)('0' + b); }
  return s;
}
