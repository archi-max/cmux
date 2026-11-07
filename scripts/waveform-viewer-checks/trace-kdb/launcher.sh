#!/bin/bash
# trace-kdb-launcher's host side: npi-model.sh's seat rules with a stand-in Verdi and exporter (no
# Verdi, no seat, no design). Run as `bash launcher.sh <scratch> <npi-model.sh>` on a Linux host
# (npi-model.sh needs GNU find and /proc/meminfo); prints `ok`/`FAIL` lines and a verdict.
# - An export that fails once it ran (a seat denied, the time cap) is not run again for that KDB:
#   the next asks are answered `tried`, with the first failure's words, until the KDB changes.
# - A failure before the exporter ran (the host's memory too low) leaves no such mark.
# - CMUX_KDB_RETRY=1 runs it again regardless.
# - A model in the cache is answered from it (cached), without the exporter.
# - Two asks for a new KDB at once run the exporter once (one seat); the other waits and is
#   answered from the cache.
# - A launcher killed mid-export (kill -9: its watchdog is gone) leaves no exporter running past
#   the time cap and a few seconds (the exporter runs under timeout -k).
# - Of several KDBs next to the dump, the first by name in C order is taken, whatever the locale
#   (as verdi-trace.sh does).
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
import json, os, sys, time
open("$S/runs", "a").write("x")
open("$S/pid", "w").write(str(os.getpid()))
open("$S/daidir", "w").write(sys.argv[1])
if os.path.exists("$S/sleep"):
    time.sleep(float(open("$S/sleep").read()))
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

# Two at once, a new KDB: one export.
echo four > "$S/sim/simv.daidir/kdb.elab++/d.db"
echo 2 > "$S/sleep"
ask > "$S/one" & A=$!
sleep 0.5
ask > "$S/two" & B=$!
wait $A $B
rm -f "$S/sleep"
check "two at once: the first exports" "$(cat "$S/one")" '"ok": true, "cached": false' 5
check "two at once: the second waits for it, cached" "$(cat "$S/two")" '"ok":true,"cached":true' 5

# The launcher killed mid-export: the orphaned exporter still ends by the time cap (2 s) plus the
# kill grace (5 s), not when it finishes on its own (30 s).
echo five > "$S/sim/simv.daidir/kdb.elab++/e.db"
echo 30 > "$S/sleep"
rm -f "$S/pid"
PATH="$S/bin:$PATH" CMUX_KDB_CACHE="$S/cache" CMUX_NPI_SECONDS=2 bash "$S/w/npi-model.sh" "$S/w" "$S/sim/dump.fsdb" > /dev/null 2>&1 & L=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$S/pid" ] && break; sleep 0.2; done
kill -9 "$L" 2>/dev/null
wait "$L" 2>/dev/null
orphan=$(cat "$S/pid" 2>/dev/null)
left=gone
for _ in $(seq 1 60); do
  if [ -n "$orphan" ] && kill -0 "$orphan" 2>/dev/null; then left=running; sleep 0.2; else left=gone; break; fi
done
if [ -n "$orphan" ] && [ "$left" = gone ]; then
  echo "ok   a killed launcher's exporter ends by the time cap"
else
  echo "FAIL a killed launcher's exporter (pid ${orphan:-none}) still runs 12 s after the kill"
  pass=0
  [ -n "$orphan" ] && kill -9 "$orphan" 2>/dev/null
fi
rm -f "$S/sleep"

# Several KDBs next to the dump: the first in C order, in any locale.
mkdir -p "$S/sim/Simv_gl.daidir/kdb.elab++"
echo gl > "$S/sim/Simv_gl.daidir/kdb.elab++/a.db"
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ask > /dev/null
got=$(cat "$S/daidir" 2>/dev/null)
case $got in
  */Simv_gl.daidir) echo "ok   several KDBs: the first by name in C order ($got)" ;;
  *) echo "FAIL several KDBs: took $got, not Simv_gl.daidir"; pass=0 ;;
esac

[ "$pass" = 1 ] && echo "TRACE KDB LAUNCHER CHECKS PASSED" || echo "TRACE KDB LAUNCHER CHECKS FAILED"
