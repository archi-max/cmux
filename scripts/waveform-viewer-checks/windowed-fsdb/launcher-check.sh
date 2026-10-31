#!/bin/bash
# run.sh windowed-launcher: the real fsdb-helper-v2 build.sh and cmux-helper-v2.sh on an
# SSH host (needs Verdi's FsdbReader, Node.js and g++ there), in a scratch HOME under
# <remote-dir> so nothing touches the real ~/.cache/cmux:
#   build, launch and answer; the launcher refuses (86, running nothing) an install with a
#   group-writable helper.env, launcher or ~/.cache/cmux, or a folder it can't read; exits
#   87 when its Node.js is gone; build.sh rebuilds a non-private install; a build whose
#   ssh went away stops.
# Usage: launcher-check.sh <helper-v2 folder> <ssh-host> <remote-dir>
set -u
SRC=$1 HOST=$2 RDIR=$3
fails=0
check() { if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (got $1, want $2)"; fails=$((fails + 1)); fi; }
remote() { ssh -o BatchMode=yes -T "$HOST" "$@" 2>&1 | grep -v -e bashrc -e 'not a valid identifier'; }
tarball() { (cd "$SRC" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --format ustar -cf - .); }

H="$RDIR/home"
D="$H/.cache/cmux/fsdb-helper-v2/check"
remote "rm -rf '$RDIR' && mkdir -p '$H' && chmod 700 '$RDIR' '$H'"
# The build, as cmux runs it (sources on stdin).
build() {
  tarball | ssh -o BatchMode=yes -T "$HOST" "HOME='$H'; export HOME; S=\$(mktemp -d /tmp/cmux-fsdb-src.XXXXXX) && tar -xf - -C \"\$S\" && nice sh \"\$S/build.sh\" \"\$S\" '$D'; rc=\$?; rm -rf \"\$S\"; exit \$rc" >/dev/null 2>&1
  echo $?
}
# One stats request through the launcher; prints its exit code and whether it answered.
launch() {
  remote "HOME='$H'; export HOME; echo '{\"id\":1,\"cmd\":\"stats\"}' | timeout 60 bash '$D/cmux-helper-v2.sh' --workers 1 2>/dev/null | grep -c '\"id\":1,\"result\"'; echo rc=\${PIPESTATUS[1]}"
}

check "$(build)" 0 "build.sh builds and installs"
out=$(launch)
check "$(echo "$out" | head -1)" 1 "the launcher starts the helper and it answers"

remote "chmod g+w '$D/helper.env'"
out=$(launch)
check "$(echo "$out" | tail -1)" rc=86 "a group-writable helper.env is refused (86)"
check "$(echo "$out" | head -1)" 0 "... and nothing answers"
remote "chmod g-w '$D/helper.env'; chmod o+w '$D/cmux-helper-v2.sh'"
check "$(launch | tail -1)" rc=86 "a world-writable launcher is refused"
remote "chmod o-w '$D/cmux-helper-v2.sh'; chmod g+w '$H/.cache/cmux'"
check "$(launch | tail -1)" rc=86 "a group-writable ~/.cache/cmux is refused"
remote "chmod g-w '$H/.cache/cmux'; mkdir -m 000 '$D/addon/locked'"
check "$(launch | tail -1)" rc=86 "a folder the check can't read is refused"
remote "rmdir '$D/addon/locked'; cp '$D/helper.env' '$RDIR/env.bak'; echo \"NODE='/nonexistent/node'\" > '$D/helper.env'; echo \"VERDI_HOME='/nonexistent'\" >> '$D/helper.env'"
check "$(launch | tail -1)" rc=87 "an install whose Node.js is gone exits 87 (rebuild)"
remote "cp '$RDIR/env.bak' '$D/helper.env'"
check "$(launch | head -1)" 1 "restored, it runs again"

# build.sh doesn't keep a working but non-private install: it rebuilds it private.
remote "chmod g+w '$D/helper.js'"
check "$(build)" 0 "build.sh over a non-private install succeeds"
check "$(remote "find '$D' -perm -g+w | wc -l" | tr -d ' ')" 0 "... and the new install is private"
check "$(launch | head -1)" 1 "... and runs"

# A build whose ssh goes away stops (heartbeat): no compiler or build.sh left after ~10 s.
remote "rm -rf '$D'"
tarball | ssh -o BatchMode=yes -T "$HOST" "HOME='$H'; export HOME; S=\$(mktemp -d /tmp/cmux-fsdb-src.XXXXXX) && tar -xf - -C \"\$S\" && echo \"\$S\" > '$RDIR/src-dir' && nice sh \"\$S/build.sh\" \"\$S\" '$D'" >/dev/null 2>&1 &
SSHPID=$!
# Kill the ssh once the compiler proper (cc1plus) runs, so the check covers it.
seen=no
for _ in $(seq 1 60); do
  sleep 1
  n=$(remote "S=\$(cat '$RDIR/src-dir' 2>/dev/null); [ -n \"\$S\" ] || exit 0; P=\$(echo \"\$S\" | sed 's,/tmp/c,/tmp/[c],'); pgrep -u \$(id -u) -f \"cc1plus.*\$P\" | wc -l" | tr -d ' ')
  if [ "${n:-0}" -gt 0 ]; then seen=yes; break; fi
done
check "$seen" yes "the build reached the compiler (cc1plus)"
kill "$SSHPID" 2>/dev/null; wait "$SSHPID" 2>/dev/null
sleep 12
# The folder's name with its first letter bracketed, so pgrep doesn't find its own shell.
left=$(remote "S=\$(cat '$RDIR/src-dir'); P=\$(echo \"\$S\" | sed 's,/tmp/c,/tmp/[c],'); pgrep -u \$(id -u) -f \"\$P\" | wc -l" | tr -d ' ')
check "$left" 0 "a build whose ssh was killed stops, cc1plus included"
remote "S=\$(cat '$RDIR/src-dir' 2>/dev/null); [ -n \"\$S\" ] && rm -rf \"\$S\"; rm -rf '$RDIR'"
if [ "$fails" -eq 0 ]; then echo "WINDOWED LAUNCHER CHECKS PASSED"; else echo "WINDOWED LAUNCHER CHECKS FAILED: $fails"; exit 1; fi
