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
# editor server's node deleted, or another node of a shared NFS home).
HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/helper.env" 2>/dev/null || exit 87
[ -x "$NODE" ] && [ -f "$VERDI_HOME/share/FsdbReader/linux64/libnffr.so" ] || exit 87
# The helper runs code from this folder: refuse one that anyone else could change.
bad="$(find "$HERE" \( ! -user "$(id -u)" -o -perm -g+w -o -perm -o+w \) ! -type l -print -quit 2>/dev/null)"
if [ -n "$bad" ]; then echo "cmux-helper-v2: refusing to run, $bad is not private to $(id -un)" >&2; exit 1; fi
export VERDI_HOME
export LD_LIBRARY_PATH="$VERDI_HOME/share/FsdbReader/linux64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# FsdbReader writes its logDir into the working directory: give it a private
# one on node-local /tmp (not a shared, world-writable folder, not NFS home).
RUN=$(mktemp -d "${TMPDIR:-/tmp}/cmux-fsdb-run.XXXXXX") || exit 1
trap 'rm -rf "$RUN"' EXIT
trap 'exit 1' HUP INT TERM
cd "$RUN" || exit 1
nice -n 10 "$NODE" "$HERE/helper.js" "$@" 3>&1 1>&2
