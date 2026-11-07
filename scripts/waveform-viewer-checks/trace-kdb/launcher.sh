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
# - Verdi comes from PATH, $VERDI_HOME/bin or CMUX_VERDI_SETUP (the user's command) only: no
#   site default such as a `module load` of a guessed module name; without them, noVerdi says
#   which variables to set. CMUX_VERDI_SETUP is ended at its time cap (CMUX_VERDI_SETUP_SECONDS).
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

# Verdi with no site default: a `module` that would load one is not used unless CMUX_VERDI_SETUP
# says so; VERDI_HOME alone finds it.
mkdir -p "$S/bin2"
cp "$S/bin/verdi" "$S/bin2/verdi"
# (exported, so the path is written in: the launcher's shell has no $S; BASH_ENV unset, as a site's
# module system may set it to redefine module in every bash)
eval "module() { [ \"\$1\" = load ] && PATH=\"$S/bin2:\$PATH\"; return 0; }"
export -f module
plain() { env -u VERDI_HOME -u CMUX_VERDI_SETUP -u BASH_ENV CMUX_KDB_CACHE="$S/cache" "$@" bash "$S/w/npi-model.sh" "$S/w" "$S/sim/dump.fsdb" | head -1; }
echo six > "$S/sim/simv.daidir/kdb.elab++/f.db"
check "no Verdi on PATH, nothing set: noVerdi, not a guessed module" "$(plain)" '"error":"noVerdi".*VERDI_HOME.*CMUX_VERDI_SETUP' 6
check "CMUX_VERDI_SETUP finds it" "$(plain CMUX_VERDI_SETUP='module load anything')" '"ok": true, "cached": false' 7
echo seven > "$S/sim/simv.daidir/kdb.elab++/g.db"
check "VERDI_HOME finds it" "$(plain VERDI_HOME="$S")" '"ok": true, "cached": false' 8
# CMUX_VERDI_SETUP runs under a time cap (CMUX_VERDI_SETUP_SECONDS, default 30 s): a setup slower
# than the cap but within it still finds Verdi (what it sets is kept); one that hangs (a module
# system's lock) is ended at the cap, with an error that says so, and nothing of it is left running.
echo eight > "$S/sim/simv.daidir/kdb.elab++/h.db"
check "a CMUX_VERDI_SETUP within its time cap finds it" \
  "$(plain CMUX_VERDI_SETUP='sleep 1; module load anything' CMUX_VERDI_SETUP_SECONDS=5)" '"ok": true, "cached": false' 9
echo nine > "$S/sim/simv.daidir/kdb.elab++/i.db"
started=$(date +%s)
line=$(plain CMUX_VERDI_SETUP='sleep 23; module load anything' CMUX_VERDI_SETUP_SECONDS=2)
took=$(( $(date +%s) - started ))
check "a hung CMUX_VERDI_SETUP: noVerdi that names the cap" "$line" '"error":"noVerdi".*CMUX_VERDI_SETUP.*2 s.*CMUX_VERDI_SETUP_SECONDS' 9
if [ "$took" -le 6 ] && ! pgrep -u "$(id -u)" -f '^sleep 23$' >/dev/null; then
  echo "ok   the hung setup is ended at the cap ($took s) and nothing of it is left"
else
  echo "FAIL the hung setup: answered after $took s, left: $(pgrep -u "$(id -u)" -f '^sleep 23$' | tr '\n' ' ')"
  pass=0
  pkill -u "$(id -u)" -f '^sleep 23$' 2>/dev/null
fi
unset -f module

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
