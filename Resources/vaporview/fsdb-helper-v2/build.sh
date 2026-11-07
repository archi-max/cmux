#!/bin/sh
# Part of cmux's FSDB helper v2. GPL-3.0, as VaporView (see ../LICENSE).
# Builds cmux's FSDB helper v2 (windowed viewing, protocol 2) on
# the remote host, for the user running it.
#
# The FSDB reader addon links Synopsys Verdi's FsdbReader libraries, which are
# proprietary, so it is compiled here, against the host's own Verdi install,
# and never shipped. cmux uploads this folder to a temporary directory and runs
#
#   sh build.sh <this folder> <install dir>
#
# which compiles VaporView's addon/fsdb_reader.cpp plus cmux's additions
# (packed.cpp.inc, window.cpp.inc, deval.h, derive.cpp.inc) into
# addon/build/Release/fsdb_reader.node, and addon/clockseg.cpp into clockseg,
# and installs them with helper.js,
# worker.js, expr.js, text.js, formats.js, tree.js, clockdesc.js, cmux-helper-v2.sh and a
# helper.env naming the Node.js and Verdi it was built for. The install is
# private to the user (the launcher refuses to run one that others can write).
#
# Exit codes cmux maps to messages (as the v1 helper's build.sh): 10 no Verdi
# FsdbReader, 11 no Node.js, 12 no C++ compiler, 13 compile failed, 14 the
# built addon does not load, 15 installing failed. Progress and errors go to stderr.
set -u
SRC=${1:?source folder}
DEST=${2:?install folder}
say() { printf 'cmux-fsdb-build: %s\n' "$*" >&2; }

has_reader() { [ -n "$1" ] && [ -f "$1/share/FsdbReader/linux64/libnffr.so" ] && [ -f "$1/share/FsdbReader/ffrAPI.h" ]; }

# ---- Verdi: $VERDI_HOME, then verdi on PATH, then after CMUX_VERDI_SETUP (a command the user
# sets, e.g. their site's module load; run in a subshell so nothing leaks into the build).
# No site defaults: no guessed modules or install roots.
from_path() {
  command -v verdi >/dev/null 2>&1 || return 1
  d=$(dirname "$(dirname "$(command -v verdi)")")
  has_reader "$d" && echo "$d"
}
find_verdi() {
  if has_reader "${VERDI_HOME:-}"; then echo "$VERDI_HOME"; return 0; fi
  from_path && return 0
  if [ -n "${CMUX_VERDI_SETUP:-}" ]; then
    d=$( (eval "$CMUX_VERDI_SETUP" >/dev/null 2>&1; if has_reader "${VERDI_HOME:-}"; then echo "$VERDI_HOME"; else from_path; fi) )
    if [ -n "$d" ]; then echo "$d"; return 0; fi
  fi
  return 1
}

# ---- Node.js >= 18 (Node-API 8): $CMUX_FSDB_NODE, PATH, then user installs and editor servers.
node_ok() { [ -x "$1" ] && "$1" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' >/dev/null 2>&1; }
find_node() {
  for n in "${CMUX_FSDB_NODE:-}" "$(command -v node 2>/dev/null)" "$HOME/.local/node/bin/node" "$HOME/.local/bin/node" \
      $(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -r) \
      $(ls -d "$HOME"/.local/opt/code-server/lib/node 2>/dev/null) \
      $(ls -td "$HOME"/.vscode-server/bin/*/node "$HOME"/.vscode-server/cli/servers/*/server/node 2>/dev/null) \
      $(ls -td "$HOME"/.cursor-server/bin/*/node "$HOME"/.cursor-server/cli/servers/*/server/node 2>/dev/null); do
    if [ -n "$n" ] && node_ok "$n"; then echo "$n"; return 0; fi
  done
  return 1
}

VERDI=$(find_verdi) || { say "Verdi FsdbReader not found: set VERDI_HOME, or CMUX_VERDI_SETUP (a command that puts verdi on PATH)"; exit 10; }
NODE=$(find_node) || { say "Node.js 18 or later not found (set CMUX_FSDB_NODE)"; exit 11; }
CXX=${CXX:-$(command -v g++ || command -v c++ || command -v clang++)} || true
[ -n "$CXX" ] || { say "no C++ compiler (g++) found"; exit 12; }
say "Verdi: $VERDI"
say "Node.js: $NODE ($("$NODE" --version))"
LIBS="$VERDI/share/FsdbReader/linux64"

# Build on node-local /tmp, never on an NFS home.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmux-fsdb-build.XXXXXX") || exit 13
trap 'rm -rf "$WORK"' EXIT
# A build whose cmux went away (the viewer closed, the loading setting changed)
# stops: once the ssh channel is gone, writing to stderr fails, and the
# heartbeat (an empty line every 5 s, which cmux's log ignores) ends the build.
# The compiler runs in its own session (setsid, util-linux), so stopping it
# stops cc1plus and the linker too, not only the g++ driver.
# (`kill -s TERM -- -PID`: dash rejects `--` after `-TERM`.)
trap 'kill -s TERM -- "-$CC" 2>/dev/null || kill "$CC" 2>/dev/null; exit 1' TERM HUP
CC=
BUILD=$$
# The sleep gets its own descriptors: when the build ends it is orphaned, and
# holding stderr would keep the ssh channel (and cmux's wait) open up to 5 s.
( trap '' PIPE; while sleep 5 </dev/null >/dev/null 2>&1; do printf '\n' >&2 2>/dev/null || { kill -TERM "$BUILD" 2>/dev/null; exit 0; }; done ) &
WATCH=$!
trap 'kill "$WATCH" 2>/dev/null; rm -rf "$WORK"' EXIT

# The cmux additions go in before Init(), and their functions into its exports.
"$NODE" -e '
  const fs = require("fs");
  const [src, out, ...incs] = process.argv.slice(1);
  let s = fs.readFileSync(src, "utf8");
  const anchor = "Napi::Object Init(Napi::Env env, Napi::Object exports) {";
  if (!s.includes(anchor)) { console.error("fsdb_reader.cpp: Init() not found"); process.exit(1); }
  const names = ["getValueChangesPacked", "traverseOnly", "cacheLoad", "cacheWindow", "cacheRecords",
    "cacheValueAt", "cacheEdge", "cacheSearch", "cacheFree", "cacheSetLimit", "cacheStats", "cacheWalkSlice",
    "cacheAdopt", "cacheExport", "cacheDerive", "signalInfo", "searchScan", "handleBits", "bgBegin", "bgEnd",
    "indexWrite", "indexSearch", "readerProbe", "coldValueAt", "cacheWindowCold", "cacheSetBounds",
    "cacheAdoptIndex", "cacheWriteIndex", "cacheEvict", "cacheLastChange", "coldValueNear", "readerNavOnce", "warmLoad", "warmWindow", "warmNear", "cacheTextScan", "bgPoll"];
  const add = incs.map((f) => fs.readFileSync(f, "utf8").replace("#pragma once", "")).join("\n");
  const exp = names.map((n) => `\n  exports.Set(Napi::String::New(env, "${n}"), Napi::Function::New(env, ${n}));`).join("");
  s = s.replace(anchor, add + "\n" + anchor + exp);
  fs.writeFileSync(out, "#include <cstring>\n#include <new>\n#include <vector>\n" + s);
' "$SRC/addon/fsdb_reader.cpp" "$WORK/fsdb_reader.cpp" "$SRC/addon/packed.cpp.inc" "$SRC/addon/window.cpp.inc" \
  "$SRC/addon/deval.h" "$SRC/addon/derive.cpp.inc" || exit 13

say "compiling the FSDB reader (one or two minutes, first open only)"
# The flags node-gyp uses for this addon, without -static-libstdc++.
# In the background, so the TERM trap above runs (and ends the compiler) at once.
SETSID=$(command -v setsid 2>/dev/null) || SETSID=
$SETSID nice -n 10 "$CXX" -std=gnu++17 -O2 -fPIC -shared -pthread \
  -DNAPI_VERSION=8 -DNAPI_DISABLE_CPP_EXCEPTIONS -DBUILDING_NODE_EXTENSION \
  -I"$SRC/third_party/node-addon-api" -I"$SRC/third_party/node-api-headers" -I"$SRC/addon" -I"$VERDI/share/FsdbReader" \
  "$WORK/fsdb_reader.cpp" -o "$WORK/fsdb_reader.node" \
  -L"$LIBS" -Wl,-rpath,"$LIBS" -lnffr -lnsys -ldl -lz >"$WORK/build.log" 2>&1 &
CC=$!
wait "$CC" || { tail -20 "$WORK/build.log" >&2; say "compile failed"; exit 13; }
CC=

# clockseg: one segment of a clock descriptor's verify as its own native process (helper.js
# "clock descriptors", off unless FSDB_CLOCK_DESC=1). Optional: without it a verify job aborts.
$SETSID nice -n 10 "$CXX" -std=gnu++17 -O2 -pthread -I"$VERDI/share/FsdbReader" \
  "$SRC/addon/clockseg.cpp" -o "$WORK/clockseg" \
  -L"$LIBS" -Wl,-rpath,"$LIBS" -lnffr -lnsys -ldl -lz >"$WORK/clockseg.log" 2>&1 &
CC=$!
wait "$CC" || { tail -5 "$WORK/clockseg.log" >&2; say "clockseg did not compile (clock descriptors unavailable)"; rm -f "$WORK/clockseg"; }
CC=

LD_LIBRARY_PATH="$LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$NODE" -e '
  const a = require(process.argv[1]);
  if (typeof a.cacheWindow !== "function" || typeof a.cacheDerive !== "function" || typeof a.openFsdb !== "function") { process.exit(1); }
' "$WORK/fsdb_reader.node" >/dev/null 2>&1 || { say "the built FSDB reader does not load"; exit 14; }

# Install next to DEST, then rename into place so a half-written folder is
# never used.
PARENT=$(dirname "$DEST")
mkdir -p "$PARENT" && chmod 700 "$PARENT" 2>/dev/null
# The launcher refuses an install below a folder others can write (~/.cache/cmux too).
chmod go-w "$(dirname "$PARENT")" 2>/dev/null
# Leftovers of builds that died mid-install.
find "$PARENT" -mindepth 1 -maxdepth 1 \( -name '.install.*' -o -name '.stale.*' -o -name '*.lock' \) -mmin +1440 \
  -exec rm -rf {} + 2>/dev/null
# The checks the launcher and cmux-helper-v2.sh make before they run an install.
ME=$(id -u)
# Every entry ours and not group/world writable; a folder find can't read is not clean.
private() {
  out=$(find "$1" \( ! -user "$ME" -o -perm -g+w -o -perm -o+w \) ! -type l -print 2>&1) || return 1
  [ -z "$out" ]
}
usable() {
  private "$1" || return 1
  [ -f "$1/addon/build/Release/fsdb_reader.node" ] && [ -f "$1/cmux-helper-v2.sh" ] && [ -f "$1/helper.js" ] \
    && [ -f "$1/worker.js" ] && [ -f "$1/expr.js" ] && [ -f "$1/text.js" ] && [ -f "$1/formats.js" ] && [ -f "$1/tree.js" ] && [ -f "$1/clockdesc.js" ] || return 1
  ( . "$1/helper.env" 2>/dev/null && [ -x "$NODE" ] && [ -f "$VERDI_HOME/share/FsdbReader/linux64/libnffr.so" ] )
}
# NFS can refuse to remove a folder whose files it is still closing.
discard() { rm -rf "$1" 2>/dev/null || { sleep 1; rm -rf "$1" 2>/dev/null; } || true; }
# Another build (a second viewer, window or Mac on the same home) got there
# first: use its install, never replace one that works.
if usable "$DEST"; then say "installed in $DEST"; exit 0; fi
STAGE=$(mktemp -d "$PARENT/.install.XXXXXX") || exit 15
trap 'kill "$WATCH" 2>/dev/null; rm -rf "$WORK"; discard "$STAGE"' EXIT
mkdir -p "$STAGE/addon/build/Release" \
  && cp "$WORK/fsdb_reader.node" "$STAGE/addon/build/Release/" \
  && cp "$SRC/helper.js" "$SRC/worker.js" "$SRC/expr.js" "$SRC/text.js" "$SRC/formats.js" "$SRC/tree.js" "$SRC/clockdesc.js" "$SRC/cmux-helper-v2.sh" "$STAGE/" || exit 15
if [ -f "$WORK/clockseg" ]; then cp "$WORK/clockseg" "$STAGE/" || exit 15; fi
# Live simulation (optional; sim.js says so when it is missing): the simctl VPI library, compiled
# against this host's own VCS headers ($VCS_HOME/include, never shipped with cmux), and the stub a
# simulator names at elaboration (-load <stub>:simctl_register), at a path that outlives versions.
# The worker's testbench helper (tb.js), the build-manifest tool, and the testbench pieces a user compiles in
# (simctl_tb.sv: simctl_cfg/simctl_port; simctl_hold.sv: the apply hold; simctl_saver.sv: fork-save).
cp "$SRC/sim.js" "$STAGE/" && mkdir -p "$STAGE/simctl" && cp "$SRC/simctl/sim-worker.js" "$SRC/simctl/tb.js" "$SRC/simctl/simctl-manifest.js" "$SRC/simctl/LICENSE" \
  "$SRC/simctl/simctl_saver.sv" "$SRC/simctl/simctl_tb.sv" "$SRC/simctl/simctl_hold.sv" "$STAGE/simctl/" || exit 15
build_simctl() {
  vcs_home=${VCS_HOME:-}
  if [ -z "$vcs_home" ] && v=$(command -v vcs 2>/dev/null); then vcs_home=$(cd "$(dirname "$v")/.." && pwd); fi
  [ -n "$vcs_home" ] && [ -f "$vcs_home/include/vpi_user.h" ] || { say "live simulation: no VCS headers (set VCS_HOME, or put vcs on PATH); skipped"; return 0; }
  cc=$(command -v gcc 2>/dev/null || command -v cc 2>/dev/null) || { say "live simulation: no C compiler; skipped"; return 0; }
  nice -n 10 "$cc" -O2 -fPIC -shared -Wall -Wno-unused-parameter -I"$vcs_home/include" \
    -o "$STAGE/simctl/libsimctl.so" "$SRC/simctl/simctl_vpi.c" >>"$WORK/build.log" 2>&1 \
    || { rm -f "$STAGE/simctl/libsimctl.so"; say "live simulation: the VPI library did not compile; skipped"; return 0; }
  stubdir=$HOME/.cache/cmux/simctl
  mkdir -p "$stubdir" && chmod 700 "$stubdir" || return 0
  "$cc" -O2 -fPIC -shared -Wall -I"$vcs_home/include" -o "$WORK/libsimctl_stub.so" "$SRC/simctl/simctl_stub.c" -ldl >>"$WORK/build.log" 2>&1 \
    || { say "live simulation: the stub did not compile; skipped"; return 0; }
  # A simulator built against the stub loads it on every run: replace it only when it differs, by rename.
  cmp -s "$WORK/libsimctl_stub.so" "$stubdir/libsimctl_stub.so" \
    || { cp "$WORK/libsimctl_stub.so" "$stubdir/.stub.$$" && chmod 755 "$stubdir/.stub.$$" && mv -f "$stubdir/.stub.$$" "$stubdir/libsimctl_stub.so"; }
  cp "$SRC/simctl/LICENSE" "$stubdir/LICENSE" 2>/dev/null || true   # the stub's licence notice, next to it
  say "live simulation: built (stub: $stubdir/libsimctl_stub.so)"
}
build_simctl
# Single-quoted for the shell that sources it; a ' in a path becomes '\''.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
printf 'NODE=%s\nVERDI_HOME=%s\n' "$(quote "$NODE")" "$(quote "$VERDI")" > "$STAGE/helper.env"
chmod -R go-w "$STAGE" && chmod 755 "$STAGE/cmux-helper-v2.sh"
chmod 700 "$STAGE"
# Check and replace under a lock (mkdir is atomic on NFS too), so a build
# never moves aside the install a concurrent one just made. A lock older
# than ten minutes belongs to a build that died.
LOCK="$DEST.lock"
tries=0
until mkdir "$LOCK" 2>/dev/null; do
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null; continue; fi
  tries=$((tries + 1))
  [ "$tries" -le 120 ] || { say "could not lock $DEST"; exit 15; }
  sleep 1
done
trap 'kill "$WATCH" 2>/dev/null; rm -rf "$WORK"; discard "$STAGE"; rmdir "$LOCK" 2>/dev/null' EXIT
if ! usable "$DEST"; then
  # What is left at DEST is broken, so it is moved aside rather than built
  # into. mv -T never moves STAGE inside an existing DEST.
  if [ -e "$DEST" ]; then
    OLD=$(mktemp -d "$PARENT/.stale.XXXXXX") && mv -T "$DEST" "$OLD/old" 2>/dev/null
    discard "${OLD:-/nonexistent}"
  fi
  mv -T "$STAGE" "$DEST" 2>/dev/null || { say "could not install into $DEST"; exit 15; }
fi
say "installed in $DEST"
