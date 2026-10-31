// cmux addition to VaporView's FSDB addon (src/fsdb_reader.cpp@59107c6):
// getValueChangesPacked. build.sh splices this file in front of Init() and
// exports the function, so a signal's value changes leave C++ as one Buffer
// instead of one JS array per change.
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
// per change, as one Buffer that owns the packed bytes (no second copy), with
// a `bitSize` property so the caller never has to trust a width. Only
// 1-byte-per-bit (4-state) signals; returns undefined for real/float signals
// so the caller can fall back to getValueChanges. Throws, instead of returning
// undefined, when no file is open or the signal has no traverse handle: the
// base getValueChanges would dereference that null handle.
Napi::Value getValueChangesPacked(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (!CHECK_LENGTH(env, info, 1) || !CHECK_NUMBER(env, info[0])) return env.Undefined();
  if (fsdb_obj == nullptr) {
    Napi::Error::New(env, "No FSDB file is open.").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  ffrVCTrvsHdl h = fsdb_obj->ffrCreateVCTraverseHandle(argIdcode(info));
  if (!h) {
    Napi::Error::New(env, "Unknown signal.").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  if (h->ffrGetBytesPerBit() != FSDB_BYTES_PER_BIT_1B) { h->ffrFree(); return env.Undefined(); }
  const uint_T bits = h->ffrGetBitSize();
  Napi::Buffer<uint8_t> result;
  if (FALSE == h->ffrHasIncoreVC()) {
    h->ffrFree();
    result = Napi::Buffer<uint8_t>::New(env, 0);
  } else {
    const size_t rec = 8 + bits;
    auto *out = new (std::nothrow) std::vector<uint8_t>();
    bool failed = out == nullptr;
    if (!failed) {
      try {
        // Grows geometrically; a fixed large reserve wastes memory on wide, rarely changing signals.
        out->reserve(rec * 1024);
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
          const size_t o = out->size();
          out->resize(o + rec);
          memcpy(&(*out)[o], &delta, 8);
          for (uint_T i = 0; i < bits; i++) (*out)[o + 8 + i] = fsdbBitChar(vc[i]);
        } while (FSDB_RC_SUCCESS == h->ffrGotoNextVC());
      } catch (const std::bad_alloc &) {
        failed = true;
      }
    }
    h->ffrFree();
    if (failed) {
      delete out;
      Napi::Error::New(env, "Out of memory reading the signal.").ThrowAsJavaScriptException();
      return env.Undefined();
    }
    if (out->empty()) {
      delete out;
      result = Napi::Buffer<uint8_t>::New(env, 0);
    } else {
      result = Napi::Buffer<uint8_t>::New(env, out->data(), out->size(),
          [](Napi::Env, uint8_t *, std::vector<uint8_t> *owned) { delete owned; }, out);
    }
  }
  result.Set("bitSize", Napi::Number::New(env, bits));
  return result;
}
