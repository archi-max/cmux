#!/bin/bash
# Rebuilds Resources/vaporview/filehandler.wasm: VaporView's src/wellen_parser at 59107c6 (tag 1.6.1-beta) with
# wellen 0.25.7 + Resources/vaporview/wellen-0.25.7-split-bit-start.patch. Paths are remapped (the work dir to
# /build, CARGO_HOME to /cargo), so the output is the same from any directory and any user.
# Usage: build-wasm.sh <VaporView git checkout that has 59107c6> <work dir> [--unpatched]
# Needs: Rust 1.93.1 with the wasm32-unknown-unknown target; wellen 0.25.7 and the crates in Cargo.lock in
# cargo's registry (or network). Prints the wasm's path and SHA-1. Run it under nice.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VV="${1:?VaporView checkout}"; WORK="${2:?work dir}"; MODE="${3:-}"
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
rm -rf "$WORK"; mkdir -p "$WORK/vaporview"
WORK="$(cd "$WORK" && pwd -P)"
git -C "$VV" archive 59107c60c9ee5eefa95750b95369753736b77ca4 Cargo.toml Cargo.lock src/wellen_parser | tar -x -C "$WORK/vaporview"
# Every crate vendored (cargo's directory source in place of crates.io), wellen patched in place there: the
# package keeps its crates.io identity, so nothing in the build depends on where the work dir is. (A path
# dependency's package id carries its absolute path into the crate hashes, and so into the code.)
(cd "$WORK/vaporview" && cargo vendor --locked --versioned-dirs vendor > /dev/null)
mkdir -p "$WORK/vaporview/.cargo"
printf '[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' > "$WORK/vaporview/.cargo/config.toml"
if [ "$MODE" != "--unpatched" ]; then
  (cd "$WORK/vaporview/vendor/wellen-0.25.7" && patch -p1 < "$ROOT/Resources/vaporview/wellen-0.25.7-split-bit-start.patch")
  # The patched files no longer match the vendored checksums; the package checksum (Cargo.lock's) stays.
  python3 - "$WORK/vaporview/vendor/wellen-0.25.7/.cargo-checksum.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["files"] = {}; json.dump(d, open(p, "w"))
PY
fi
export RUSTFLAGS="--remap-path-prefix=$WORK=/build --remap-path-prefix=$CARGO_HOME=/cargo"
(cd "$WORK/vaporview" && CARGO_TARGET_DIR="$WORK/target" cargo build -j 4 --locked --offline --target wasm32-unknown-unknown --release)
OUTWASM="$WORK/target/wasm32-unknown-unknown/release/filehandler.wasm"
echo "$OUTWASM"
shasum "$OUTWASM"
