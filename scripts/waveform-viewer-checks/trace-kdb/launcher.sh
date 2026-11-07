#!/bin/bash
# trace-kdb-launcher's host side: npi-model.sh's seat rules with a stand-in Verdi and exporter (no
# Verdi, no seat, no design). Run as `bash launcher.sh <scratch> <npi-model.sh>` on a Linux host
# (npi-model.sh needs GNU find and /proc/meminfo); prints `ok`/`FAIL` lines and a verdict.
# - An export that fails once it ran (a seat denied, the time cap) is not run again for that KDB:
#   the next asks are answered `tried`, with the first failure's words, until the KDB changes.
# - A failure before the exporter ran (the host's memory too low) leaves no such mark.
# - CMUX_KDB_RETRY=1 runs it again regardless.
# - A model in the cache is answered from it (cached), without the exporter.
S=$1
LAUNCHER=$2
set -u
umask 077
mkdir -p "$S/bin" "$S/sim/simv.daidir/kdb.elab++" "$S/w" "$S/cache" || exit 1
: > "$S/sim/dump.fsdb"
echo one > "$S/sim/simv.daidir/kdb.elab++/a.db"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/verdi"
chmod +x "$S/bin/verdi"
# The stand-in exporter: counts its runs, and fails as $S/mode says (or writes an empty model).
cat > "$S/npi-model.py" <<EOF
import json, sys
open("$S/runs", "a").write("x")
mode = open("$S/mode").read().strip()
if mode == "ok":
    json.dump({"tops": [], "instances": {}}, open(sys.argv[2], "w"))
    print(json.dumps({"ok": True, "seconds": {"load": 0.1}}))
else:
    print(json.dumps({"ok": False, "error": mode, "message": "stand-in " + mode}))
EOF
cp "$LAUNCHER" "$S/w/npi-model.sh"
cp "$S/npi-model.py" "$S/w/npi-model.py"
pass=1
runs() { [ -f "$S/runs" ] && wc -c < "$S/runs" | tr -d ' ' || echo 0; }
ask() { PATH="$S/bin:$PATH" CMUX_KDB_CACHE="$S/cache" bash "$S/w/npi-model.sh" "$S/w" "$S/sim/dump.fsdb" | head -1; }
check() {
  # check <what> <line> <grep pattern> <runs expected>
  if printf '%s' "$2" | grep -q "$3" && [ "$(runs)" = "$4" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: $2 (exporter runs $(runs), expected $4)"
    pass=0
  fi
}

echo licence > "$S/mode"
check "a denied seat is reported" "$(ask)" '"error":"licence"\|"error": "licence"' 1
check "the same KDB is not tried again" "$(ask)" '"error":"tried".*licence' 1
check "nor on the next open" "$(ask)" '"error":"tried"' 1
check "CMUX_KDB_RETRY=1 tries it" "$(CMUX_KDB_RETRY=1 ask)" 'licence' 2

echo time > "$S/mode"
echo two > "$S/sim/simv.daidir/kdb.elab++/b.db"
check "a new KDB is tried (and times out)" "$(ask)" '"error": "time"\|"error":"time"' 3
check "the timed-out KDB is not tried again" "$(ask)" '"error":"tried".*time' 3

echo ok > "$S/mode"
echo three > "$S/sim/simv.daidir/kdb.elab++/c.db"
check "low memory before the export: reported" "$(CMUX_NPI_MIN_AVAILABLE_MB=999999999 ask)" '"error":"memory"' 3
check "and not marked: the next ask exports" "$(ask)" '"ok": true, "cached": false' 4
check "then the cache answers" "$(ask)" '"ok":true,"cached":true' 4

[ "$pass" = 1 ] && echo "TRACE KDB LAUNCHER CHECKS PASSED" || echo "TRACE KDB LAUNCHER CHECKS FAILED"
