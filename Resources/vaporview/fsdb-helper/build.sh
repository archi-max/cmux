#!/bin/sh
# Builds cmux's FSDB helper on the remote host, for the user running it.
#
# The FSDB reader addon links Synopsys Verdi's FsdbReader libraries, which are
# proprietary, so it is compiled here, against the host's own Verdi install,
# and never shipped. cmux uploads this folder to a temporary directory and runs
#
#   sh build.sh <this folder> <install dir>
#
# which compiles VaporView's fsdb_reader.cpp (plus packed.cpp.inc) into
# fsdb_reader.node and installs it with fsdb-helper.js, fsdb-helper.sh and a
# helper.env naming the Node.js and Verdi it was built for.
#
# Exit codes cmux maps to messages: 10 no Verdi FsdbReader, 11 no Node.js,
# 12 no C++ compiler, 13 compile failed, 14 the built addon does not load,
# 15 installing failed. Progress and errors go to stderr.
set -u
SRC=${1:?source folder}
DEST=${2:?install folder}
say() { printf 'cmux-fsdb-build: %s\n' "$*" >&2; }

has_reader() { [ -n "$1" ] && [ -f "$1/share/FsdbReader/linux64/libnffr.so" ] && [ -f "$1/share/FsdbReader/ffrAPI.h" ]; }

# ---- Verdi: $VERDI_HOME, then `module load` of a Synopsys/Verdi module, then common install roots.
find_verdi() {
  if has_reader "${VERDI_HOME:-}"; then echo "$VERDI_HOME"; return 0; fi
  if command -v verdi >/dev/null 2>&1; then
    d=$(dirname "$(dirname "$(command -v verdi)")")
    if has_reader "$d"; then echo "$d"; return 0; fi
  fi
  # Environment modules (Lmod or Tcl modules) are not loaded in a batch ssh
  # session; load them in a subshell so nothing leaks into the build.
  for init in /etc/profile.d/modules.sh /usr/share/lmod/lmod/init/sh /usr/share/Modules/init/sh; do
    [ -f "$init" ] || continue
    for mod in $( (. "$init" >/dev/null 2>&1; module -t avail 2>&1) | grep -i -E '^(synopsys|verdi)[^/]*/?$' | sed 's,/$,,'); do
      d=$( (. "$init" >/dev/null 2>&1; module load "$mod" >/dev/null 2>&1; printf '%s' "${VERDI_HOME:-}") )
      if has_reader "$d"; then echo "$d"; return 0; fi
    done
  done
  for d in $(ls -d /software/*ynopsys*/verdi/* /opt/synopsys/verdi/* /usr/synopsys/verdi/* /tools/synopsys/verdi/* 2>/dev/null | sort -r); do
    if has_reader "$d"; then echo "$d"; return 0; fi
  done
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

VERDI=$(find_verdi) || { say "Verdi FsdbReader not found (set VERDI_HOME)"; exit 10; }
NODE=$(find_node) || { say "Node.js 18 or later not found (set CMUX_FSDB_NODE)"; exit 11; }
CXX=${CXX:-$(command -v g++ || command -v c++ || command -v clang++)} || true
[ -n "$CXX" ] || { say "no C++ compiler (g++) found"; exit 12; }
say "Verdi: $VERDI"
say "Node.js: $NODE ($("$NODE" --version))"
LIBS="$VERDI/share/FsdbReader/linux64"

# Build on node-local /tmp, never on an NFS home.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmux-fsdb-build.XXXXXX") || exit 13
trap 'rm -rf "$WORK"' EXIT

"$NODE" -e '
  const fs = require("fs");
  const [src, inc, out] = process.argv.slice(1);
  let s = fs.readFileSync(src, "utf8");
  const anchor = "Napi::Object Init(Napi::Env env, Napi::Object exports) {";
  if (!s.includes(anchor)) { console.error("fsdb_reader.cpp: Init() not found"); process.exit(1); }
  s = s.replace(anchor, fs.readFileSync(inc, "utf8") + "\n" + anchor +
    "\n  exports.Set(Napi::String::New(env, \"getValueChangesPacked\"), Napi::Function::New(env, getValueChangesPacked));");
  fs.writeFileSync(out, "#include <cstring>\n#include <new>\n#include <vector>\n" + s);
' "$SRC/fsdb_reader.cpp" "$SRC/packed.cpp.inc" "$WORK/fsdb_reader.cpp" || exit 13

say "compiling the FSDB reader (about a minute, first open only)"
# The flags node-gyp uses for this addon, without -static-libstdc++.
nice -n 10 "$CXX" -std=gnu++17 -O2 -fPIC -shared -pthread \
  -DNAPI_VERSION=8 -DNAPI_DISABLE_CPP_EXCEPTIONS -DBUILDING_NODE_EXTENSION \
  -I"$SRC/third_party/node-addon-api" -I"$SRC/third_party/node-api-headers" -I"$VERDI/share/FsdbReader" \
  "$WORK/fsdb_reader.cpp" -o "$WORK/fsdb_reader.node" \
  -L"$LIBS" -Wl,-rpath,"$LIBS" -lnffr -lnsys -ldl -lz >"$WORK/build.log" 2>&1 \
  || { tail -20 "$WORK/build.log" >&2; say "compile failed"; exit 13; }

LD_LIBRARY_PATH="$LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$NODE" -e '
  const a = require(process.argv[1]);
  if (typeof a.getValueChangesPacked !== "function" || typeof a.openFsdb !== "function") { process.exit(1); }
' "$WORK/fsdb_reader.node" >/dev/null 2>&1 || { say "the built FSDB reader does not load"; exit 14; }

# Install next to DEST, then rename into place so a half-written folder is
# never used.
PARENT=$(dirname "$DEST")
mkdir -p "$PARENT" && chmod 700 "$PARENT" 2>/dev/null
# Leftovers of builds that died mid-install.
find "$PARENT" -mindepth 1 -maxdepth 1 \( -name '.install.*' -o -name '.stale.*' -o -name '*.lock' \) -mmin +1440 \
  -exec rm -rf {} + 2>/dev/null
# The checks the launcher and fsdb-helper.sh make before they run an install.
usable() {
  [ -f "$1/fsdb_reader.node" ] && [ -f "$1/fsdb-helper.sh" ] && [ -f "$1/fsdb-helper.js" ] || return 1
  ( . "$1/helper.env" 2>/dev/null && [ -x "$NODE" ] && [ -f "$VERDI_HOME/share/FsdbReader/linux64/libnffr.so" ] )
}
# NFS can refuse to remove a folder whose files it is still closing.
discard() { rm -rf "$1" 2>/dev/null || { sleep 1; rm -rf "$1" 2>/dev/null; } || true; }
# Another build (a second viewer, window or Mac on the same home) got there
# first: use its install, never replace one that works.
if usable "$DEST"; then say "installed in $DEST"; exit 0; fi
STAGE=$(mktemp -d "$PARENT/.install.XXXXXX") || exit 15
trap 'rm -rf "$WORK"; discard "$STAGE"' EXIT
cp "$WORK/fsdb_reader.node" "$SRC/fsdb-helper.js" "$SRC/fsdb-helper.sh" "$STAGE/" || exit 15
# Single-quoted for the shell that sources it; a ' in a path becomes '\''.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
printf 'NODE=%s\nVERDI_HOME=%s\n' "$(quote "$NODE")" "$(quote "$VERDI")" > "$STAGE/helper.env"
chmod 755 "$STAGE/fsdb-helper.sh"
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
trap 'rm -rf "$WORK"; discard "$STAGE"; rmdir "$LOCK" 2>/dev/null' EXIT
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
