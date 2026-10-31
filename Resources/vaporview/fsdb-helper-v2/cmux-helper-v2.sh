#!/bin/bash
# Part of cmux's FSDB helper v2. GPL-3.0, as VaporView (see ../LICENSE).
# Starts cmux's FSDB helper v2 on the host that holds the dumps.
# Usage: cmux-helper-v2.sh [--workers N]
# Protocol replies go to fd 3 (the ssh channel); Verdi's FsdbReader prints to
# stdout (coordinator and workers), so fd 1 is sent to stderr where it cannot
# corrupt the protocol. helper.env (written by build.sh) names the Node.js and
# Verdi it was built for.
#
# Exits 87, which makes cmux rebuild, when that Node.js or Verdi is gone (an
# editor server's node deleted, or another node of a shared NFS home), and 86
# when the install is not private (cmux then shows an error and runs nothing).
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ME="$(id -u)"
# The helper runs code from this folder, and helper.env names the Node.js and
# libraries it loads: refuse (exit 86, before reading anything here) an install
# anyone else could have changed. Every entry must be ours and not group/world
# writable (a folder find can't read counts as changed), and so must the two
# folders above it (~/.cache/cmux/fsdb-helper-v2 and ~/.cache/cmux), which
# build.sh makes private.
refuse() { echo "cmux-helper-v2: refusing to run, $1 is not private to $(id -un)" >&2; exit 86; }
out=$(find "$HERE" \( ! -user "$ME" -o -perm -g+w -o -perm -o+w \) ! -type l -print 2>&1) || refuse "$HERE"
[ -z "$out" ] || refuse "$(printf '%s' "$out" | head -1)"
for d in "$(dirname "$HERE")" "$(dirname "$(dirname "$HERE")")"; do
  [ -n "$(find "$d" -maxdepth 0 -user "$ME" ! -perm -g+w ! -perm -o+w 2>/dev/null)" ] || refuse "$d"
done
. "$HERE/helper.env" 2>/dev/null || exit 87
[ -x "$NODE" ] && [ -f "$VERDI_HOME/share/FsdbReader/linux64/libnffr.so" ] || exit 87
export VERDI_HOME
export LD_LIBRARY_PATH="$VERDI_HOME/share/FsdbReader/linux64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# FsdbReader writes its logDir into the working directory: give it a private
# one on node-local /tmp (not a shared, world-writable folder, not NFS home).
RUN=$(mktemp -d "${TMPDIR:-/tmp}/cmux-fsdb-run.XXXXXX") || exit 1
trap 'rm -rf "$RUN"' EXIT
trap 'exit 1' HUP INT TERM
cd "$RUN" || exit 1
nice -n 10 "$NODE" "$HERE/helper.js" "$@" 3>&1 1>&2
