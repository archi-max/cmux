#!/bin/bash
# wellen 0.25.7's split-bit merge with and without cmux's patch (Resources/vaporview/wellen-0.25.7-split-bit-start.patch).
# Usage: check.sh <work dir>. Unpacks the crate from cargo's registry (fetch it first with any build that uses it),
# runs split_bits_late_start.rs on the unpatched crate (expected: FAIL) and the patched one (expected: pass, and
# wellen's own --lib tests). Run it under nice: nice -n 10 check.sh /tmp/wellen-check
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="${1:?work dir}"
SRC="$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/wellen-0.25.7 | head -1)"
rm -rf "$WORK"; mkdir -p "$WORK"
for v in unpatched patched; do
  cp -R "$SRC" "$WORK/$v"
  mkdir -p "$WORK/$v/tests"; cp "$HERE/split_bits_late_start.rs" "$WORK/$v/tests/"
  printf '\n[[test]]\nname = "split_bits_late_start"\npath = "tests/split_bits_late_start.rs"\n' >> "$WORK/$v/Cargo.toml"
done
(cd "$WORK/patched" && patch -p1 < "$ROOT/Resources/vaporview/wellen-0.25.7-split-bit-start.patch")
if (cd "$WORK/unpatched" && CARGO_TARGET_DIR="$WORK/target-unpatched" cargo test -j 4 --test split_bits_late_start); then
  echo "UNEXPECTED: the unpatched crate passes"; exit 1
fi
(cd "$WORK/patched" && CARGO_TARGET_DIR="$WORK/target-patched" cargo test -j 4 --test split_bits_late_start && CARGO_TARGET_DIR="$WORK/target-patched" cargo test -j 4 --lib)
echo "WELLEN SPLIT-BIT CHECKS PASSED (red unpatched, green patched)"
