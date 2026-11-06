#!/bin/bash
# run.sh fsdb-values: string, real and event variables through the real FSDB helper v2 on an
# SSH host (needs Verdi's FSDB reader and writer libraries, Node.js and g++ there). In a
# scratch folder under <remote-dir>: build.sh builds the helper as cmux does, the fixture
# is written with the host's FSDB writer (make-values-fsdb.cpp), and values-check.js
# drives the helper over its protocol. Nothing is copied back.
# Optional, a real dump on the host as well (no defaults: set both or neither):
#   FSDB_VALUES_DUMP=<remote.fsdb> FSDB_VALUES_EXPECT=<var path>=<its value at time 0>
# The check runs under rss-guard.sh (1.5 GB per process, 2 GB in all) with one worker per
# helper, one helper at a time, and doesn't start when the host has under 4 GB available.
# Usage: check.sh <helper-v2 folder> <this folder> <ssh-host> <remote-dir>
set -u
SRC=$1 HERE=$2 HOST=$3 RDIR=$4
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
remote() { ssh -o BatchMode=yes -T "$HOST" "$@" 2>&1 | grep -v -e bashrc -e 'not a valid identifier'; }
tarball() { (cd "$1" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --format ustar -cf - .); }

H="$RDIR/home" D="$RDIR/home/.cache/cmux/fsdb-helper-v2/check"
avail=$(ssh -o BatchMode=yes -T "$HOST" "free -m" 2>/dev/null | awk '/^Mem:/ {print $7}')
if [ -z "$avail" ] || [ "$avail" -lt 4096 ]; then echo "FSDB VALUES CHECKS FAILED: the host has ${avail:-?} MB available (needs 4096)"; exit 1; fi
remote "rm -rf $(q "$RDIR") && mkdir -p $(q "$H") $(q "$RDIR/src") $(q "$RDIR/check") && chmod 700 $(q "$RDIR") $(q "$H")"
tarball "$SRC" | ssh -o BatchMode=yes -T "$HOST" "tar -xf - -C $(q "$RDIR/src")"
tarball "$HERE" | ssh -o BatchMode=yes -T "$HOST" "tar -xf - -C $(q "$RDIR/check")"
echo "building the helper on the host"
remote "HOME=$(q "$H"); export HOME; nice sh $(q "$RDIR/src/build.sh") $(q "$RDIR/src") $(q "$D") >$(q "$RDIR/build.log") 2>&1; echo build=\$?" | tail -1 | grep -q '^build=0$' \
  || { remote "tail -20 $(q "$RDIR/build.log")"; echo "FSDB VALUES CHECKS FAILED: build"; exit 1; }
# The writer next to the reader the build found.
remote "cd $(q "$RDIR/check") && . $(q "$D/helper.env") && W=\"\$VERDI_HOME/share/FsdbWriter\" && nice g++ -O1 -I\"\$W\" -o mkvalues make-values-fsdb.cpp -L\"\$W/linux64\" -lnffw -Wl,-rpath,\"\$W/linux64\" -lpthread -ldl -lz >mk.log 2>&1 && ./mkvalues values.fsdb >>mk.log 2>&1 && ./mkvalues cap.fsdb >>mk.log 2>&1 && ./mkvalues big.fsdb big >>mk.log 2>&1; echo mk=\$?" | tail -1 | grep -q '^mk=0$' \
  || { remote "tail -20 $(q "$RDIR/check/mk.log")"; echo "FSDB VALUES CHECKS FAILED: fixture"; exit 1; }
envs=""
if [ -n "${FSDB_VALUES_DUMP:-}" ] && [ -n "${FSDB_VALUES_EXPECT:-}" ]; then
  envs="FSDB_VALUES_DUMP=$(q "$FSDB_VALUES_DUMP") FSDB_VALUES_EXPECT=$(q "$FSDB_VALUES_EXPECT")"
fi
out=$(remote "HOME=$(q "$H"); export HOME; . $(q "$D/helper.env"); cd /tmp && $envs nice bash $(q "$RDIR/check/rss-guard.sh") 1500 2000 \"\$NODE\" $(q "$RDIR/check/values-check.js") $(q "$D") $(q "$RDIR/check/values.fsdb") $(q "$RDIR/check/big.fsdb") $(q "$RDIR/check/cap.fsdb")")
echo "$out"
remote "rm -rf $(q "$RDIR")"
echo "$out" | grep -q '^FSDB VALUES CHECKS PASSED'
