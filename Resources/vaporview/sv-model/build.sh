#!/bin/sh
# Builds cmux-sv-model, driver tracing's design model sidecar, on the machine that holds the
# design (the Mac for a local folder, the SSH host for a remote one), for the user running it.
#
# cmux-sv-model (sv_model.cpp) is built on slang (https://github.com/MikePopoloski/slang, MIT),
# the same SystemVerilog front end slang-server uses, at the pinned release below. cmux ships
# only these sources; this script fetches slang and its header-only dependencies as release
# tarballs, checks their SHA-256, and compiles them here:
#
#   sh build.sh <this folder> <install dir>
#
# Needs CMake 3.20 or later, a C++20 compiler (GCC 11+, Clang 16+) and Python 3 (slang's build
# generates sources with it). Offline hosts: put the four tarballs in $CMUX_SV_MODEL_TARBALLS.
# An installed slang of the same release can be used instead of building one:
# CMUX_SLANG_DIR=<prefix>/lib/cmake/slang. Builds run under nice with $CMUX_SV_MODEL_JOBS jobs
# (default 4), in a temporary folder on local /tmp.
#
# Exit codes cmux maps to messages: 20 no CMake 3.20+, 21 no C++20 compiler, 22 no Python 3,
# 23 a download failed, 24 a download's checksum is wrong, 25 configure failed, 26 compile
# failed, 27 the built program does not run, 28 installing failed. Progress goes to stderr, with
# machine-read lines for cmux's progress panel: "cmux-sv-model-build: stage <fetch|configure|compile|
# install>" and, while compiling, "cmux-sv-model-build: progress <percent>" from cmake's "[ NN%]"
# (Makefiles) or "[N/M]" (Ninja) lines.
set -u
SRC=${1:?source folder}
DEST=${2:?install folder}
say() { printf 'cmux-sv-model-build: %s\n' "$*" >&2; }
stage() { printf 'cmux-sv-model-build: stage %s\n' "$1" >&2; }
SV_MODEL_PROGRESS_AWK='BEGIN { last = -1 } { p = -1; if (match($0, /^\[ *[0-9]+%\]/)) { s = substr($0, 2, RLENGTH - 3); gsub(/ /, "", s); p = s + 0 } else if (match($0, /^\[[0-9]+\/[0-9]+\]/)) { split(substr($0, 2, RLENGTH - 2), a, "/"); if (a[2] > 0) p = int(a[1] * 100 / a[2]) } if (p >= 0 && p != last) { printf "cmux-sv-model-build: progress %d\n", p; fflush(); last = p } }'

SLANG_VERSION=12.1
SLANG_URL=https://github.com/MikePopoloski/slang/archive/refs/tags/v12.1.tar.gz
SLANG_SHA=e7454393956ef0f3e9bbcac27f7de473e11e1fd7be125c3009f1f2bfeddf0358
FMT_URL=https://github.com/fmtlib/fmt/archive/refs/tags/12.2.0.tar.gz
FMT_SHA=8b852bb5aa6e7d8564f9e81394055395dd1d1936d38dfd3a17792a02bebd7af0
REGEX_URL=https://github.com/MikePopoloski/regex/archive/refs/tags/boost-1.91.0.tar.gz
REGEX_SHA=b159cea3bf570394dd19f5fed7320005290809ba53fea15c630c3a6c2685db75
TOML_URL=https://github.com/marzer/tomlplusplus/archive/refs/tags/v3.4.0.tar.gz
TOML_SHA=8517f65938a4faae9ccf8ebb36631a38c1cadfb5efa85d9a72e15b9e97d25155

# ---- tools ----
find_cmake() {
  for c in "${CMUX_CMAKE:-}" "$(command -v cmake 2>/dev/null)" /opt/homebrew/bin/cmake /usr/local/bin/cmake \
      "$HOME/.local/bin/cmake" /Applications/CMake.app/Contents/bin/cmake; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    v=$("$c" --version 2>/dev/null | sed -n 's/^cmake version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
    set -- $v
    [ $# -eq 2 ] || continue
    if [ "$1" -gt 3 ] || { [ "$1" -eq 3 ] && [ "$2" -ge 20 ]; }; then echo "$c"; return 0; fi
  done
  return 1
}
CMAKE=$(find_cmake) || { say "CMake 3.20 or later not found (set CMUX_CMAKE)"; exit 20; }
PY=$(command -v python3 2>/dev/null) || { say "Python 3 not found"; exit 22; }

# Build on node-local /tmp, never on an NFS home.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmux-sv-model-build.XXXXXX") || exit 25
trap 'rm -rf "$WORK"' EXIT

find_cxx() {
  for c in "${CXX:-}" "$(command -v c++ 2>/dev/null)" "$(command -v g++ 2>/dev/null)" "$(command -v clang++ 2>/dev/null)"; do
    [ -n "$c" ] || continue
    printf '#include <span>\n#include <concepts>\n#include <bit>\nint main() { int a[2] = {}; std::span<int> s(a); return std::popcount(unsigned(s.size())) - 1; }\n' > "$WORK/t.cpp"
    if "$c" -std=c++20 "$WORK/t.cpp" -o "$WORK/t" >/dev/null 2>&1 && "$WORK/t"; then echo "$c"; return 0; fi
  done
  return 1
}
CXX=$(find_cxx) || { say "no C++20 compiler found (GCC 11+ or Clang 16+; set CXX)"; exit 21; }
say "CMake: $CMAKE; C++: $CXX ($("$CXX" --version 2>/dev/null | head -1))"

# ---- sources ----
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
fetch() {  # fetch <name> <url> <sha> -> unpacks into $WORK/<name>
  f="$WORK/$1.tar.gz"
  if [ -n "${CMUX_SV_MODEL_TARBALLS:-}" ] && [ -f "$CMUX_SV_MODEL_TARBALLS/$1.tar.gz" ]; then
    cp "$CMUX_SV_MODEL_TARBALLS/$1.tar.gz" "$f"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 -o "$f" "$2" || { say "download failed: $2"; exit 23; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$f" "$2" || { say "download failed: $2"; exit 23; }
  else
    say "neither curl nor wget is installed"; exit 23
  fi
  [ "$(sha256 "$f")" = "$3" ] || { say "checksum mismatch for $2"; exit 24; }
  mkdir -p "$WORK/$1" && tar -xzf "$f" -C "$WORK/$1" --strip-components=1 || { say "cannot unpack $1"; exit 23; }
}

if [ -n "${CMUX_SLANG_DIR:-}" ]; then
  say "using the installed slang at $CMUX_SLANG_DIR"
  set -- -Dslang_DIR="$CMUX_SLANG_DIR"
else
  stage fetch
  say "fetching slang $SLANG_VERSION"
  fetch slang "$SLANG_URL" "$SLANG_SHA"
  fetch fmt "$FMT_URL" "$FMT_SHA"
  fetch regex "$REGEX_URL" "$REGEX_SHA"
  fetch toml "$TOML_URL" "$TOML_SHA"
  set -- -DSV_MODEL_SLANG_SOURCE="$WORK/slang" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DFETCHCONTENT_SOURCE_DIR_FMT="$WORK/fmt" -DFETCHCONTENT_SOURCE_DIR_BOOST_REGEX="$WORK/regex" \
    -DFETCHCONTENT_SOURCE_DIR_TOMLPLUSPLUS="$WORK/toml"
fi

# ---- build ----
mkdir -p "$WORK/src" && cp "$SRC/CMakeLists.txt" "$SRC/sv_model.cpp" "$WORK/src/" || exit 25
stage configure
say "configuring"
"$CMAKE" -S "$WORK/src" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER="$CXX" \
  -DPython_EXECUTABLE="$PY" -DPython3_EXECUTABLE="$PY" "$@" > "$WORK/configure.log" 2>&1 \
  || { tail -20 "$WORK/configure.log" >&2; say "configure failed"; exit 25; }
stage compile
say "compiling (a few minutes, once)"
# The build's output goes to build.log; its percent lines go on to stderr (the pipe loses the
# build's exit code, so it is kept in build.rc).
{ nice -n 10 "$CMAKE" --build "$WORK/build" --target cmux-sv-model -j "${CMUX_SV_MODEL_JOBS:-4}" 2>&1; echo $? > "$WORK/build.rc"; } \
  | tee "$WORK/build.log" | awk "$SV_MODEL_PROGRESS_AWK" >&2
[ "$(cat "$WORK/build.rc" 2>/dev/null)" = 0 ] \
  || { grep -E 'error|Error' "$WORK/build.log" | head -20 >&2; tail -5 "$WORK/build.log" >&2; say "compile failed"; exit 26; }
BIN="$WORK/build/cmux-sv-model"
reply=$(printf '{"id":1,"cmd":"version"}\n' | "$BIN" 2>/dev/null | sed -n 2p)
case "$reply" in *'"ok":true'*) ;; *) say "the built cmux-sv-model does not run: $reply"; exit 27 ;; esac

# ---- install ----
stage install
mkdir -p "$DEST" || exit 28
cp "$BIN" "$DEST/cmux-sv-model.new" && mv -f "$DEST/cmux-sv-model.new" "$DEST/cmux-sv-model" \
  && cp "$SRC/sv-model.sh" "$DEST/sv-model.sh" || { say "installing failed"; exit 28; }
printf 'slang=%s\n' "$SLANG_VERSION" > "$DEST/installed" || exit 28
say "installed in $DEST"
