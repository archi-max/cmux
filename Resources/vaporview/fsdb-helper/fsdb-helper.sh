#!/bin/bash
# Starts cmux's FSDB helper on the host that holds the dumps.
# Protocol replies go to fd 3 (the ssh channel); Verdi's FsdbReader prints to
# stdout, so fd 1 is sent to stderr where it cannot corrupt the protocol.
# helper.env (written by build.sh) names the Node.js and Verdi it was built for.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helper.env"
export VERDI_HOME
export LD_LIBRARY_PATH="$VERDI_HOME/share/FsdbReader/linux64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "${TMPDIR:-/tmp}" || exit 1   # FsdbReader writes its logDir here, keep it off an NFS home
exec "$NODE" "$HERE/fsdb-helper.js" 3>&1 1>&2
