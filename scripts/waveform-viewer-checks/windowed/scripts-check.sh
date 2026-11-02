#!/bin/bash
# run.sh windowed, part 2: the real fsdb-helper-v2 build.sh and cmux-helper-v2.sh, here,
# on a scratch HOME, with a stand-in toolchain (no Verdi or g++ needed): a fake Verdi
# folder, a "compiler" that writes the addon file (and can run a child, like cc1plus),
# and a node that runs the mock helper in place of helper.js. GNU-only `mv -T` and
# util-linux `setsid` get small stand-ins on macOS.
#   build as cmux runs it, launch and answer, the launcher's privacy refusals (86, running
#   nothing), 87 when its Node.js is gone, 14 when the addon doesn't load, build.sh
#   rebuilding a non-private install, the build's stderr closing when it ends (the
#   heartbeat's sleep must not hold it), and a build stopping, compiler child included,
#   when its reader goes away.
# Usage: scripts-check.sh <helper-v2 folder> <mock-helper-v2.cjs> <scratch dir>
set -u
SRC=$1 MOCK=$2 T=$3
fails=0
check() { if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (got $1, want $2)"; fails=$((fails + 1)); fi; }
ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }

rm -rf "$T" && mkdir -p "$T" && chmod 700 "$T"
T=$(cd "$T" && pwd -P)
H="$T/home" FAKE="$T/bin" VERDI="$T/verdi"
D="$H/.cache/cmux/fsdb-helper-v2/check"
mkdir -p "$H" "$FAKE" "$VERDI/share/FsdbReader/linux64"
: > "$VERDI/share/FsdbReader/linux64/libnffr.so"; : > "$VERDI/share/FsdbReader/ffrAPI.h"
REAL_NODE=$(command -v node)
cat > "$FAKE/node" <<EOF
#!/bin/sh
# helper.js -> the mock; the addon load check -> \$FAKE_LOAD_RC; the rest -> real node.
case "\$1" in
  */helper.js) shift; exec "$REAL_NODE" "$MOCK" --latency 1 --jitter 0 "\$@" ;;
  -e) case "\$2" in *'require(process.argv[1])'*) exit "\${FAKE_LOAD_RC:-0}" ;; esac ;;
esac
exec "$REAL_NODE" "\$@"
EOF
cat > "$FAKE/c++" <<'EOF'
#!/bin/sh
# Writes the -o file; with FAKE_CC_SECONDS, first runs a child for that long (cc1plus).
out=
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
if [ -n "${FAKE_CC_SECONDS:-}" ]; then sleep "$FAKE_CC_SECONDS" & wait $!; fi
printf 'addon' > "$out"
EOF
if ! mv -T /dev/null /dev/null 2>/dev/null && ! command -v gmv >/dev/null; then
  cat > "$FAKE/mv" <<'EOF'
#!/bin/bash
a=(); for x in "$@"; do [ "$x" = -T ] || a+=("$x"); done; exec /bin/mv "${a[@]}"
EOF
fi
command -v setsid >/dev/null || printf '#!/bin/sh\nexec perl -MPOSIX -e '\''POSIX::setsid(); exec @ARGV or die'\'' "$@"\n' > "$FAKE/setsid"
chmod 755 "$FAKE"/*
ENV=(HOME="$H" PATH="$FAKE:$PATH" VERDI_HOME="$VERDI" CMUX_FSDB_NODE="$FAKE/node" CXX="$FAKE/c++")

# The build as cmux runs it (sources as a tar on stdin, unpacked into a temporary folder).
BUILD_SCRIPT='S=$(mktemp -d "${TMPDIR:-/tmp}/cmux-fsdb-src.XXXXXX") && tar -xf - -C "$S" && echo "$S" > "$SRCDIR_NOTE" && ${BUILD_SH:-sh} "$S/build.sh" "$S" "$DEST"; rc=$?; rm -rf "$S"; exit $rc'
tarball() { (cd "$SRC" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -cf - .) 2>/dev/null || (cd "$SRC" && tar -cf - .); }
build() { tarball | env "${ENV[@]}" "$@" SRCDIR_NOTE="$T/src-dir" DEST="$D" sh -c "$BUILD_SCRIPT"; }
# One stats request through the launcher: "<answered> rc=<exit>".
launch() {
  local rc
  { echo '{"id":1,"cmd":"stats"}'; sleep 1; } | env "${ENV[@]}" bash "$D/cmux-helper-v2.sh" --workers 1 >"$T/launch.out" 2>/dev/null
  rc=$?
  echo "$(grep -c '"id":1,"result"' "$T/launch.out") rc=$rc"
}

# Build: rc 0, and the build's output closes with it (no 5 s heartbeat sleep holding it).
build >/dev/null 2>"$T/build.err" | cat
rc=${PIPESTATUS[0]}
t1=$(ms)
check "$rc" 0 "build.sh builds and installs (stand-in toolchain)"
check "$(cd "$D" && "$REAL_NODE" -e 'const t = require("./text.js"); process.stdout.write(String(t.FORMATS.has("riscv") && typeof require("./formats.js").formatRiscvBinaryString))' 2>&1)" "function" \
  "the install has searchText's text.js and formats.js, and they load"
build 2>&1 >/dev/null | cat >/dev/null
t2=$(ms)
check "$(( t2 - t1 < 3500 ))" 1 "the build's stderr closes when it ends ($(( t2 - t1 )) ms; a held heartbeat sleep keeps it ~5 s)"
check "$(launch)" "1 rc=0" "the launcher starts the (mock) helper and it answers"

chmod g+w "$D/helper.env"
check "$(launch)" "0 rc=86" "a group-writable helper.env is refused (86) and nothing answers"
chmod g-w "$D/helper.env"; chmod o+w "$D/cmux-helper-v2.sh"
check "$(launch)" "0 rc=86" "a world-writable launcher is refused"
chmod o-w "$D/cmux-helper-v2.sh"; chmod g+w "$H/.cache/cmux"
check "$(launch)" "0 rc=86" "a group-writable ~/.cache/cmux is refused"
chmod g-w "$H/.cache/cmux"; mkdir -m 000 "$D/addon/locked"
check "$(launch)" "0 rc=86" "a folder the check can't read is refused"
rmdir "$D/addon/locked"
cp "$D/helper.env" "$T/env.bak"; printf "NODE='/nonexistent/node'\nVERDI_HOME='%s'\n" "$VERDI" > "$D/helper.env"
check "$(launch)" "0 rc=87" "an install whose Node.js is gone exits 87 (rebuild)"
cp "$T/env.bak" "$D/helper.env"
check "$(launch)" "1 rc=0" "restored, it runs again"

# build.sh doesn't keep a working but non-private install: it rebuilds it private.
chmod g+w "$D/helper.js"
build >/dev/null 2>&1
check "$?" 0 "build.sh over a non-private install succeeds"
check "$(find "$D" -perm -g+w | wc -l | tr -d ' ')" 0 "... and the new install is private"
check "$(launch)" "1 rc=0" "... and runs"

# An addon that doesn't load: 14.
rm -rf "$D"
build FAKE_LOAD_RC=1 >/dev/null 2>&1
check "$?" 14 "a built addon that doesn't load exits 14"

# A build whose reader goes away (ssh closed) stops, its compiler's child too: under
# the host's sh as it may be (bash, or dash as on Debian/Ubuntu).
cancel_check() {
  local shell=$1
  rm -rf "$D" "$T/err"
  mkfifo "$T/err"
  (exec cat "$T/err" >/dev/null) &
  READER=$!
  disown "$READER" 2>/dev/null
  build BUILD_SH="$shell" FAKE_CC_SECONDS=97.31 >/dev/null 2>"$T/err" &
  BUILDER=$!
  sleep 2
  kill "$READER" 2>/dev/null
  for _ in $(seq 1 24); do kill -0 "$BUILDER" 2>/dev/null || break; sleep 0.5; done
  check "$(kill -0 "$BUILDER" 2>/dev/null && echo running || echo stopped)" stopped "($shell) a build whose reader went away stops"
  sleep 0.5
  check "$(pgrep -f '^sleep 97[.]31' | wc -l | tr -d ' ')" 0 "($shell) ... and so does the compiler's child (cc1plus)"
  pkill -f '^sleep 97[.]31' 2>/dev/null; kill "$BUILDER" 2>/dev/null; wait "$BUILDER" 2>/dev/null
  S=$(cat "$T/src-dir" 2>/dev/null); [ -n "$S" ] && rm -rf "$S"
}
cancel_check sh
if command -v dash >/dev/null; then cancel_check dash; else echo "skip (no dash here) cancel under dash"; fi
S=$(cat "$T/src-dir" 2>/dev/null); [ -n "$S" ] && rm -rf "$S"
chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"
if [ "$fails" -eq 0 ]; then echo "SCRIPT CHECKS PASSED"; else echo "SCRIPT CHECKS FAILED: $fails"; exit 1; fi
