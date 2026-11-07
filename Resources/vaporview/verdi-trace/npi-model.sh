#!/bin/bash
# cmux driver tracing, the KDB design model's launcher (ours; it runs the host's installed Verdi and
# ships nothing of it). cmux sends this script and npi-model.py over SSH into a private scratch
# folder and runs `bash -l npi-model.sh <scratch> <dump.fsdb | simv.daidir> [--print]`. The KDB is
# the daidir named, or the first next to the dump (by name, in C order) that holds kdb.elab++
# (vcs -kdb), as verdi-trace.sh finds it. It prints one JSON line: {"ok": true, "cached", "seconds"?, "instances"?, "signals"?,
# "peakMB"?} or {"ok": false, "error": "noFile"|"noKDB"|"noVerdi"|"licence"|"memory"|"time"|"start"|
# "walk"|"tried"|"busy", "message"}; with --print, the model's JSON (one line) follows an ok line.
#
# Models are kept in a cache of the user's own (CMUX_KDB_CACHE, default ~/.cache/cmux/kdb-model, the
# newest 8), keyed by the KDB's path, its FILES' newest mtime and total size, and the exporter: a
# model already there costs no licence seat. Not the kdb.elab++ folder's own mtime: load_design
# creates and removes an entry there (the user's daidir is otherwise left as it was), which would
# invalidate the key on every export. A daidir the user can't write to loads too (run.sh trace-kdb
# checks a read-only copy). An export holds a Verdi seat for its load and walk only (seconds), one
# per KDB at a time: an ask for a KDB that is being exported waits for it (flock on $KEY.lock, at
# most the time cap and a minute; then "busy") and is answered from the cache. An export that fails once the exporter ran (a seat denied, a guard, Verdi's error) is
# not run again for that KDB: the cache keeps the failure ($KEY.failed) and later asks are answered
# {"error": "tried", "message": "<the failure's code>: <its message>"} without Verdi, until the KDB
# changes (a new key) or CMUX_KDB_RETRY=1. Guards: the host's MemAvailable
# (CMUX_NPI_MIN_AVAILABLE_MB, default 5120), the exporter's RSS (CMUX_NPI_RSS_MB, default 2900) and
# time (CMUX_NPI_SECONDS, default 120); its address space and time stay bounded without this launcher.
W=$1
TARGET=$2
PRINT=${3:-}
cd "$W" || exit 1
umask 077
say() { printf '{"ok":false,"error":"%s","message":"%s"}\n' "$1" "$(printf '%s' "$2" | tr -d '"\\' | tr '\000-\037' ' ' | cut -c1-400)"; exit 0; }
num() { case $1 in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
MIN_MB=$(num "${CMUX_NPI_MIN_AVAILABLE_MB:-}" 5120)
RSS_MB=$(num "${CMUX_NPI_RSS_MB:-}" 2900)
SECONDS_CAP=$(num "${CMUX_NPI_SECONDS:-}" 120)
CACHE=${CMUX_KDB_CACHE:-$HOME/.cache/cmux/kdb-model}

if [ -d "$TARGET/kdb.elab++" ]; then
  DAIDIR=$TARGET
else
  [ -r "$TARGET" ] || say noFile "$TARGET"
  # (C order whatever the locale: the same KDB as verdi-trace.sh's)
  DAIDIR=$(LC_ALL=C; for d in "$(dirname "$TARGET")"/*.daidir; do
    if [ -d "$d/kdb.elab++" ]; then printf '%s' "$d"; break; fi
  done)
  [ -n "$DAIDIR" ] || say noKDB "$(dirname "$TARGET")"
fi
DAIDIR=$(cd "$DAIDIR" && pwd -P) || say noKDB "$TARGET"

# The cache key: the KDB's path, its files' newest mtime and total size, and this exporter.
stamp=$(find "$DAIDIR/kdb.elab++" -type f -printf '%T@ %s\n' 2>/dev/null | awk '{ if ($1 > m) m = $1; s += $2 } END { printf "%s %d", m, s }')
[ -n "$stamp" ] || say noKDB "$DAIDIR"
hash() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else cksum; fi; }
KEY=$( { printf '%s\n%s\n' "$DAIDIR" "$stamp"; cat npi-model.py; } | hash | cut -c1-32 | tr -d ' ')
MODEL="$CACHE/$KEY.json"
FAILED="$CACHE/$KEY.failed"
# The exporter ran and failed: kept, so this KDB holds no seat again (then said as `say` does).
fail() {
  mkdir -p "$CACHE" 2>/dev/null && printf '%s: %s\n' "$1" "$2" | tr -d '"\\' | tr '\000-\037' ' ' | cut -c1-400 > "$FAILED" 2>/dev/null
  ls -1t "$CACHE"/*.failed 2>/dev/null | tail -n +9 | while read -r old; do rm -f "$old"; done
  say "$@"
}

emit() {
  echo "$1"
  if [ "$PRINT" = "--print" ]; then cat "$MODEL"; echo; fi
  exit 0
}
if [ -s "$MODEL" ]; then
  touch "$MODEL" 2>/dev/null
  emit '{"ok":true,"cached":true}'
fi
if [ -s "$FAILED" ] && [ "${CMUX_KDB_RETRY:-}" != 1 ]; then
  say tried "$(cat "$FAILED")"
fi
# One export of a KDB at a time (two viewers opening a new KDB: one seat); the one that waited is
# answered from what the other left.
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$CACHE" || say start "no cache folder $CACHE"
  exec 9> "$CACHE/$KEY.lock"
  flock -w $((SECONDS_CAP + 60)) 9 || say busy "another export of this KDB is still running"
  if [ -s "$MODEL" ]; then
    touch "$MODEL" 2>/dev/null
    emit '{"ok":true,"cached":true}'
  fi
  if [ -s "$FAILED" ] && [ "${CMUX_KDB_RETRY:-}" != 1 ]; then
    say tried "$(cat "$FAILED")"
  fi
fi

# Verdi: on PATH, else in $VERDI_HOME/bin, else after CMUX_VERDI_SETUP (a command the user sets in
# their shell startup file, e.g. their site's module load). No site default.
if ! command -v verdi >/dev/null 2>&1 && [ -n "${VERDI_HOME:-}" ] && [ -x "$VERDI_HOME/bin/verdi" ]; then
  PATH=$VERDI_HOME/bin:$PATH
fi
if ! command -v verdi >/dev/null 2>&1 && [ -n "${CMUX_VERDI_SETUP:-}" ]; then
  eval "$CMUX_VERDI_SETUP" >/dev/null 2>&1
fi
command -v verdi >/dev/null 2>&1 || say noVerdi "Verdi is not on PATH: set VERDI_HOME, or CMUX_VERDI_SETUP (a command that puts verdi on PATH), in the shell startup file"
VERDI_HOME=${VERDI_HOME:-$(cd "$(dirname "$(command -v verdi)")/.." && pwd)}
export VERDI_HOME
available=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null)
[ -n "$available" ] && [ "$available" -lt "$MIN_MB" ] && say memory "MemAvailable ${available} MB"
mkdir -p "$CACHE" || say start "no cache folder $CACHE"
# The exporter's own bounds outlive this launcher (a kill -9 of it, or of the ssh it runs under):
# its address space (ulimit -v) and its time (timeout: TERM a few seconds past the cap, then KILL),
# so an orphan holds the seat and the lock no longer than that.
LIMIT=
command -v timeout >/dev/null 2>&1 && LIMIT="timeout -k 5 $((SECONDS_CAP + 5))"
( ulimit -v $(( (RSS_MB + 4096) * 1024 )); exec $LIMIT nice -n 10 python3 npi-model.py "$DAIDIR" "$W/model.json" ) > npi.out 2> npi.err &
P=$!
trap 'pkill -P "$P" 2>/dev/null; kill "$P" 2>/dev/null' EXIT TERM HUP INT
peak=0
ticks=0
while kill -0 "$P" 2>/dev/null; do
  # The exporter's RSS: under timeout it is timeout's child.
  rss=$(ps -o rss= -p "$P" --ppid "$P" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
  rss=${rss:-0}
  [ "$rss" -gt "$peak" ] && peak=$rss
  if [ "$rss" -gt $((RSS_MB * 1024)) ]; then kill "$P"; fail memory "the exporter passed ${RSS_MB} MB"; fi
  ticks=$((ticks + 1))
  if [ "$ticks" -gt $((SECONDS_CAP * 5)) ]; then kill "$P"; fail time "the exporter ran past ${SECONDS_CAP} s"; fi
  sleep 0.2
done
wait "$P"
line=$(grep '^{' npi.out | tail -1)
[ -n "$line" ] || fail start "$(grep -i -m1 -E 'error|licen' npi.err)"
case $line in
  '{"ok": true'*) ;;
  *)
    # Verdi's own words (a licence failure's) go with the exporter's error.
    why=$(grep -i -m1 -E 'licen[cs]e|error' npi.err | tr -d '"\\' | tr '\000-\037' ' ' | cut -c1-300)
    code=$(printf '%s' "$line" | sed -n 's/.*"error": *"\([^"]*\)".*/\1/p')
    said=$(printf '%s' "$line" | sed -n 's/.*"message": *"\([^"]*\)".*/\1/p')
    mkdir -p "$CACHE" 2>/dev/null && printf '%s: %s%s\n' "${code:-walk}" "$said" "${why:+ (Verdi: $why)}" | tr -d '"\\' | cut -c1-400 > "$FAILED" 2>/dev/null
    if [ -n "$why" ]; then echo "$line" | sed "s/\"message\": \"\([^\"]*\)\"/\"message\": \"\1 (Verdi: $(printf '%s' "$why" | sed 's/[&/|]/ /g'))\"/"; else echo "$line"; fi
    exit 0 ;;
esac
rm -f "$FAILED"
mv -f "$W/model.json" "$MODEL.tmp" && mv -f "$MODEL.tmp" "$MODEL" || say start "could not keep the model in $CACHE"
# The newest 8 models stay.
ls -1t "$CACHE"/*.json 2>/dev/null | tail -n +9 | while read -r old; do rm -f "$old"; done
ls -1t "$CACHE"/*.lock 2>/dev/null | tail -n +17 | while read -r old; do rm -f "$old"; done
emit "$(printf '%s' "$line" | sed 's/^{"ok": true, /{"ok": true, "cached": false, /; s/}$//'), \"peakMB\": $((peak / 1024))}"
