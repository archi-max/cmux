// Part of cmux's FSDB helper v2, written for cmux. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), whose addon it extends; see ../../LICENSE.
// ---- cmux additions: packed value changes without per-change JS objects ----

static inline uint8_t fsdbBitChar(byte_T b) {
  switch (b) {
    case FSDB_BT_VCD_0: return '0';
    case FSDB_BT_VCD_1: return '1';
    case FSDB_BT_VCD_X: return 'x';
    case FSDB_BT_VCD_Z: return 'z';
    default: return 'u';
  }
}

static fsdbVarIdcode argIdcode(const Napi::CallbackInfo &info) {
#ifdef FSDB_USE_32B_IDCODE
  return info[0].As<Napi::Number>().Int32Value();
#else
  return info[0].As<Napi::Number>().Int64Value();
#endif
}

// Value changes in the viewer's record layout: [u64 LE delta time][bitSize chars]
// per change, as one Buffer. Only 1-byte-per-bit (4-state) signals; returns
// undefined for real/float signals so the caller can fall back.
Napi::Value getValueChangesPacked(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 1) || !CHECK_NUMBER(env, info[0])) return env.Undefined();
  ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(argIdcode(info));
  if (!h) return env.Undefined();
  if (FALSE == h->ffrHasIncoreVC()) { h->ffrFree(); return Napi::Buffer<uint8_t>::New(env, 0); }
  if (h->ffrGetBytesPerBit() != FSDB_BYTES_PER_BIT_1B) { h->ffrFree(); return env.Undefined(); }
  const uint_T bits = h->ffrGetBitSize();
  const size_t rec = 8 + bits;
  std::vector<uint8_t> out;
  out.reserve(rec * 65536);
  fsdbTag64 time;
  h->ffrGetMinXTag((void *)&time);
  h->ffrGotoXTag((void *)&time);
  uint64_t prev = 0;
  do {
    byte_T *vc;
    h->ffrGetXTag(&time);
    h->ffrGetVC(&vc);
    const uint64_t t = combineTime(time.H, time.L);
    const uint64_t delta = t - prev;
    prev = t;
    const size_t o = out.size();
    out.resize(o + rec);
    memcpy(&out[o], &delta, 8);
    for (uint_T i = 0; i < bits; i++) out[o + 8 + i] = fsdbBitChar(vc[i]);
  } while (FSDB_RC_SUCCESS == h->ffrGotoNextVC());
  h->ffrFree();
  return Napi::Buffer<uint8_t>::Copy(env, out.data(), out.size());
}

// Benchmark: walk a loaded signal through the reader without building anything.
Napi::Value traverseOnly(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 1) || !CHECK_NUMBER(env, info[0])) return env.Undefined();
  ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(argIdcode(info));
  if (!h || FALSE == h->ffrHasIncoreVC()) { if (h) h->ffrFree(); return Napi::Number::New(env, 0); }
  fsdbTag64 time;
  h->ffrGetMinXTag((void *)&time);
  h->ffrGotoXTag((void *)&time);
  double count = 0;
  uint64_t sink = 0;
  do {
    byte_T *vc;
    h->ffrGetXTag(&time);
    h->ffrGetVC(&vc);
    sink += vc[0] + time.L;
    count++;
  } while (FSDB_RC_SUCCESS == h->ffrGotoNextVC());
  h->ffrFree();
  return Napi::Number::New(env, count + (sink == 1 ? 0.5 : 0));
}
