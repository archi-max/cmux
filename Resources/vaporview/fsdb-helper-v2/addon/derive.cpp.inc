// Part of cmux's FSDB helper v2, written for cmux. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), whose addon it extends; see ../../LICENSE.
// ---- cmux additions (helper v2): derived signals ----
//
// A derived signal is an expression over stored signals, compiled by
// helper.js into a flat program (operands before users, last node = result)
// and materialized here into a normal SigStore: a k-way merge walks the union
// of the operands' change times, evaluates the program once per distinct time
// (after all changes at that time) and appends a record when the result
// differs from the previous one.
//
// Values are 4-state bit vectors, bit 0 = LSB, as two word planes: v (value)
// and x (unknown); z is read as x, and v & x == 0 always. Operators follow
// SystemVerilog (see deval.h); sizing and signedness are applied by expr.js.
// Limits: the result may use at most `budgetBytes` (default half the worker's
// store limit) and the merge at most `deadlineMs`; the up-front cost estimate
// (steps x per-step word ops) must stay under kMaxDeriveWork.

// The evaluator (DOp, DNode, evalNode, validateProgram) is addon/deval.h,
// inlined before this file by build.sh.

// Store rows hold char i (0 = MSB) at bit i&7 of byte i>>3; nodes hold bit
// j = w-1-i. Byte b of a row is therefore bits [w-8-8b, w-8b) bit-reversed.
static uint8_t g_rev8[256];
static bool g_rev8Init = [] { for (int i = 0; i < 256; i++) { int r = 0; for (int q = 0; q < 8; q++) if (i >> q & 1) r |= 1 << (7 - q); g_rev8[i] = (uint8_t)r; } return true; }();
static inline void orByteAt(std::vector<uint64_t> &w, int base, uint8_t byte) {
  if (!byte) return;
  if (base < 0) { byte = (uint8_t)(byte >> -base); base = 0; }
  const uint32_t wi = (uint32_t)base >> 6, sh = (uint32_t)base & 63;
  w[wi] |= (uint64_t)byte << sh;
  if (sh > 56 && wi + 1 < w.size()) w[wi + 1] |= (uint64_t)byte >> (64 - sh);
}
static inline uint8_t byteAt(const std::vector<uint64_t> &w, int base) {
  uint64_t r;
  if (base < 0) {
    r = w[0] << -base;
  } else {
    const uint32_t wi = (uint32_t)base >> 6, sh = (uint32_t)base & 63;
    r = w[wi] >> sh;
    if (sh > 56 && wi + 1 < w.size()) r |= w[wi + 1] << (64 - sh);
  }
  return (uint8_t)r;
}

// Load change k of store s into d (char 0 = MSB -> bit w-1), z read as x.
static inline void loadRecord(const SigStore *s, size_t k, DNode &d) {
  clearNode(d);
  const uint8_t *v = &s->val[k * s->stride];
  const uint8_t *x = s->xz.empty() ? nullptr : &s->xz[k * s->stride];
  const int B = (int)s->bits;
  for (uint32_t b = 0; b < s->stride; b++) {
    const int base = B - 8 - 8 * (int)b;
    const uint8_t xb = x ? x[b] : 0;
    orByteAt(d.v, base, g_rev8[(uint8_t)(v[b] & ~xb)]);
    if (xb) orByteAt(d.x, base, g_rev8[xb]);
  }
}

// readStoreFile / writeStoreFile: window.cpp.inc.

// cacheExport(id, path): write a stored signal to a file for another worker.
Napi::Value cacheExport(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 2) || !CHECK_STRING(env, info[1])) return env.Undefined();
  SigStore *s = storeGet(env, info[0]);
  if (!s) return env.Undefined();
  if (s->kind != kBits) {  // (store files hold bit planes only)
    Napi::Error::New(env, std::string("a ") + kindName(s->kind) + " signal can't be an expression operand").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  if (!writeStoreFile(s, info[1].As<Napi::String>().Utf8Value())) {
    Napi::Error::New(env, "cannot write export").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  return Napi::Number::New(env, (double)s->times.size());
}

// cacheDerive(id, program[], operands[{id, path?}], evict = true, {budgetBytes?, deadlineMs?})
//   -> {count, bits, bytes, steps, ms}. Operands with a path are read from that
//   file (and not kept); others must be in this process's store. The program
//   is validated (deval.h) before anything is allocated for it.
static const double kMaxDeriveWork = 4e10;  // word operations, ~30-60 s

Napi::Value cacheDerive(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 3) || !CHECK_ARRAY(env, info[1]) || !CHECK_ARRAY(env, info[2])) return env.Undefined();
  const auto t0 = std::chrono::steady_clock::now();
  const int64_t id = argI64(info[0]);
  const bool evict = info.Length() < 4 || info[3].ToBoolean().Value();
  size_t budget = g_limit / 2;
  double deadlineMs = 60000;
  if (info.Length() > 4 && info[4].IsObject()) {
    Napi::Object opt = info[4].As<Napi::Object>();
    if (opt.Has("budgetBytes") && opt.Get("budgetBytes").IsNumber()) budget = (size_t)std::max(0.0, opt.Get("budgetBytes").As<Napi::Number>().DoubleValue());
    if (opt.Has("deadlineMs") && opt.Get("deadlineMs").IsNumber()) deadlineMs = opt.Get("deadlineMs").As<Napi::Number>().DoubleValue();
  }
  auto fail = [&](const std::string &m) { Napi::Error::New(env, m).ThrowAsJavaScriptException(); return env.Undefined(); };
  // Program first (cheap to reject), with every number range-checked here and
  // the structure checked by validateProgram.
  Napi::Array prog = info[1].As<Napi::Array>();
  if (prog.Length() == 0 || prog.Length() > kMaxProgramNodes) return fail("bad program length");
  std::vector<DNode> P(prog.Length());
  std::vector<std::string> bits(prog.Length());
  for (uint32_t i = 0; i < prog.Length(); i++) {
    if (!prog.Get(i).IsObject()) return fail("bad program node");
    Napi::Object o = prog.Get(i).As<Napi::Object>();
    DNode &d = P[i];
    auto num = [&](const char *k, double dflt, double lo, double hi, bool &ok) -> double {
      if (!o.Has(k) || o.Get(k).IsUndefined()) return dflt;
      if (!o.Get(k).IsNumber()) { ok = false; return dflt; }
      const double v = o.Get(k).As<Napi::Number>().DoubleValue();
      if (!(v >= lo && v <= hi) || v != std::floor(v)) ok = false;
      return v;
    };
    bool ok = true;
    d.op = (int)num("op", -1, 0, D_COUNT - 1, ok);
    d.w = (uint32_t)num("w", 0, 1, kMaxExprBits, ok);
    d.a = (int)num("a", -1, -1, kMaxProgramNodes, ok);
    d.b = (int)num("b", -1, -1, kMaxProgramNodes, ok);
    d.c = (int)num("c", -1, -1, kMaxProgramNodes, ok);
    d.k = (int)num("k", -1, -1, 1 << 20, ok);
    d.s = num("s", 0, 0, 1, ok) != 0;
    d.lo = (int64_t)num("lo", 0, -(double)kMaxExprBits, kMaxExprBits, ok);
    d.n = (uint32_t)num("n", 0, 0, kMaxExprBits, ok);
    if (!ok) return fail("bad program node " + std::to_string(i));
    if (o.Has("args")) {
      if (!o.Get("args").IsArray()) return fail("bad program node " + std::to_string(i));
      Napi::Array a = o.Get("args").As<Napi::Array>();
      if (a.Length() > kMaxExprBits) return fail("bad program node " + std::to_string(i));
      for (uint32_t j = 0; j < a.Length(); j++) {
        const double r = a.Get(j).IsNumber() ? a.Get(j).As<Napi::Number>().DoubleValue() : -1;
        if (!(r >= 0 && r < i)) return fail("bad program node " + std::to_string(i));
        d.args.push_back((int)r);
      }
    }
    if (d.op == D_CONST) {
      if (!o.Get("bits").IsString()) return fail("bad constant");
      bits[i] = o.Get("bits").As<Napi::String>().Utf8Value();
    }
  }
  // Operands.
  Napi::Array opsArr = info[2].As<Napi::Array>();
  if (opsArr.Length() == 0) return fail("expression has no signals");
  std::vector<SigStore *> ops;
  std::vector<SigStore *> temps;
  auto cleanup = [&]() { for (SigStore *t : temps) delete t; temps.clear(); };
  for (uint32_t i = 0; i < opsArr.Length(); i++) {
    Napi::Object o = opsArr.Get(i).As<Napi::Object>();
    if (o.Has("path") && o.Get("path").IsString()) {
      std::string err;
      SigStore *s = readStoreFile(o.Get("path").As<Napi::String>().Utf8Value(), err);
      if (!s) { cleanup(); return fail(err); }
      temps.push_back(s);
      ops.push_back(s);
    } else {
      auto it = g_store.find(argI64(o.Get("id")));
      if (it == g_store.end()) { cleanup(); return fail("operand not loaded"); }
      if (it->second->kind != kBits) { cleanup(); return fail(std::string("a ") + kindName(it->second->kind) + " signal can't be an expression operand"); }
      it->second->lastUsed = ++g_clock;
      ops.push_back(it->second);
    }
  }
  std::vector<uint32_t> opBits;
  for (const SigStore *o : ops) opBits.push_back(o->bits);
  std::string err = validateProgram(P, opBits);
  for (size_t i = 0; err.empty() && i < P.size(); i++) err = prepareNode(P[i], bits[i]);
  if (!err.empty()) { cleanup(); return fail(err); }
  // Up-front limits: work and result size.
  double stepsMax = 0;
  for (const SigStore *o : ops) stepsMax += (double)o->times.size();
  if (stepsMax * (double)programCost(P) > kMaxDeriveWork) {
    cleanup();
    return fail("expression too expensive for these signals (about " + std::to_string((long long)(stepsMax * programCost(P) / 1e9)) + "G word ops)");
  }
  std::vector<std::vector<int>> sigNodes(ops.size());
  for (size_t i = 0; i < P.size(); i++) if (P[i].op == D_SIG) sigNodes[P[i].k].push_back((int)i);
  DNode &R = P.back();
  SigStore *out = new SigStore();
  out->bits = R.w;
  out->stride = (R.w + 7) / 8;
  const size_t perRecord = 8 + 2 * (size_t)out->stride;
  size_t most = 0;  // the result changes at most once per union time; usually about the busiest operand
  for (const SigStore *o : ops) most = std::max(most, o->times.size());
  most = std::min(most, budget / perRecord + 1);
  out->times.reserve(most);
  out->val.reserve(most * out->stride);
  // Normalized output (as normalizeStore): before the first change the result
  // is all x, and a record is kept only when the value changes.
  std::vector<uint64_t> prevV(R.nw, 0), prevX(R.nw, 0);
  for (uint32_t i = 0; i < R.w; i++) prevX[i >> 6] |= 1ull << (i & 63);
  std::vector<size_t> idx(ops.size(), 0);
  size_t steps = 0;
  std::string abort;
  for (;;) {
    uint64_t t = UINT64_MAX;
    bool any = false;
    for (size_t k = 0; k < ops.size(); k++)
      if (idx[k] < ops[k]->times.size() && ops[k]->times[idx[k]] <= t) { t = ops[k]->times[idx[k]]; any = true; }
    if (!any) break;
    for (size_t k = 0; k < ops.size(); k++) {
      const SigStore *s = ops[k];
      if (idx[k] >= s->times.size() || s->times[idx[k]] != t) continue;
      while (idx[k] < s->times.size() && s->times[idx[k]] == t) idx[k]++;
      if (sigNodes[k].empty()) continue;
      DNode &d0 = P[sigNodes[k][0]];
      loadRecord(s, idx[k] - 1, d0);
      for (size_t j = 1; j < sigNodes[k].size(); j++) { P[sigNodes[k][j]].v = d0.v; P[sigNodes[k][j]].x = d0.x; }
    }
    for (size_t i = 0; i < P.size(); i++) evalNode(P, i);
    steps++;
    if ((steps & 1023) == 0 && std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() > deadlineMs) {
      abort = "derive took longer than " + std::to_string((long long)(deadlineMs / 1000)) + " s";
      break;
    }
    if (R.v == prevV && R.x == prevX) continue;
    prevV = R.v;
    prevX = R.x;
    // Append in store order: char i = bit w-1-i.
    const size_t kk = out->times.size();
    if ((kk + 1) * perRecord > budget) { abort = "derived signal larger than " + std::to_string(budget >> 20) + " MB"; break; }
    out->times.push_back(t);
    out->val.resize((kk + 1) * out->stride, 0);
    const bool hasX = anyX(R);
    if (hasX || !out->xz.empty()) out->xz.resize((kk + 1) * out->stride, 0);
    uint8_t *ov = &out->val[kk * out->stride];
    uint8_t *ox = out->xz.empty() ? nullptr : &out->xz[kk * out->stride];
    const int RW = (int)R.w;
    const uint8_t lastMask = (R.w & 7) ? (uint8_t)((1 << (R.w & 7)) - 1) : 0xff;
    for (uint32_t b = 0; b < out->stride; b++) {
      const int base = RW - 8 - 8 * (int)b;
      const uint8_t m = b + 1 == out->stride ? lastMask : 0xff;
      ov[b] = g_rev8[byteAt(R.v, base)] & m;
      if (ox) ox[b] = g_rev8[byteAt(R.x, base)] & m;
    }
  }
  cleanup();
  if (!abort.empty()) { delete out; return fail(abort); }
  out->times.shrink_to_fit();
  out->val.shrink_to_fit();
  out->xz.shrink_to_fit();
  storeFree(id);
  out->lastUsed = ++g_clock;
  g_store[id] = out;
  g_bytes += out->bytes();
  if (evict) storeEvict({id});
  Napi::Object o = Napi::Object::New(env);
  o.Set("count", Napi::Number::New(env, (double)out->times.size()));
  o.Set("bits", Napi::Number::New(env, out->bits));
  o.Set("xz", Napi::Boolean::New(env, !out->xz.empty()));
  o.Set("bytes", Napi::Number::New(env, (double)out->bytes()));
  o.Set("steps", Napi::Number::New(env, (double)steps));
  o.Set("ms", Napi::Number::New(env, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count()));
  return o;
}

// signalInfo(id) -> {bits, byteCount, bytesPerBit, varType, count, first: [bytes]}
// (diagnostics: what the reader's traverse handle reports for a signal)
Napi::Value signalInfo(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  const fsdbVarIdcode id = (fsdbVarIdcode)argI64(info[0]);
  fsdb_obj->ffrAddToSignalList(id);
  fsdb_obj->ffrLoadSignals();
  fsdb_obj->ffrResetSignalList();
  ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(id);
  Napi::Object o = Napi::Object::New(env);
  if (!h) return o;
  o.Set("bits", Napi::Number::New(env, h->ffrGetBitSize()));
  o.Set("byteCount", Napi::Number::New(env, h->ffrGetByteCount()));
  o.Set("bytesPerBit", Napi::Number::New(env, (int)h->ffrGetBytesPerBit()));
  o.Set("varType", Napi::Number::New(env, (int)h->ffrGetVarType()));
  o.Set("count", Napi::Number::New(env, (double)fsdb_obj->ffrGetVCCount(id)));
  if (h->ffrHasIncoreVC()) {
    fsdbTag64 time;
    h->ffrGetMinXTag((void *)&time);
    h->ffrGotoXTag((void *)&time);
    for (int k = 0; k < 3000 && FSDB_RC_SUCCESS == h->ffrGotoNextVC(); k++) {}
    byte_T *vc;
    h->ffrGetVC(&vc);
    Napi::Array a = Napi::Array::New(env);
    for (uint32_t i = 0; i < 40; i++) a.Set(i, Napi::Number::New(env, vc[i]));
    o.Set("sample", a);
  }
  h->ffrFree();
  fsdb_obj->ffrUnloadSignals(id);
  return o;
}

// handleBits(ids[]) -> bit size per signal from a traverse handle, without
// loading the signals (diagnostics / cheap pre-filter).
Napi::Value handleBits(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  Napi::Array ids = info[0].As<Napi::Array>();
  Napi::Array out = Napi::Array::New(env);
  for (uint32_t i = 0; i < ids.Length(); i++) {
    ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle((fsdbVarIdcode)argI64(ids.Get(i)));
    out.Set(i, Napi::Number::New(env, h ? (double)h->ffrGetBitSize() : -1));
    if (h) h->ffrFree();
  }
  return out;
}
