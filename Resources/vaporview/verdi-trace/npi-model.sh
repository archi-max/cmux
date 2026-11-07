#!/bin/bash
# cmux driver tracing, the KDB design model's launcher (ours; it runs the host's installed Verdi and
# ships nothing of it). cmux sends this script and npi-model.py over SSH into a private scratch
# folder and runs `bash -l npi-model.sh <scratch> <dump.fsdb | simv.daidir> [--print]`. The KDB is
# the daidir named, or the one next to the dump that holds kdb.elab++ (vcs -kdb), as verdi-trace.sh
# finds it. It prints one JSON line: {"ok": true, "cached", "seconds"?, "instances"?, "signals"?,
# "peakMB"?} or {"ok": false, "error": "noFile"|"noKDB"|"noVerdi"|"licence"|"memory"|"time"|"start"|
# "walk", "message"}; with --print, the model's JSON (one line) follows an ok line.
#
# Models are kept in a cache of the user's own (CMUX_KDB_CACHE, default ~/.cache/cmux/kdb-model, the
# newest 8), keyed by the KDB's path, its FILES' newest mtime and total size, and the exporter: a
# model already there costs no licence seat. Not the kdb.elab++ folder's own mtime: load_design
# creates and removes an entry there (the user's daidir is otherwise left as it was), which would
# invalidate the key on every export. A daidir the user can't write to may not load. An export holds a Verdi seat for its load and walk only
# (seconds); it is not retried here when the seat is denied. Guards: the host's MemAvailable
# (CMUX_NPI_MIN_AVAILABLE_MB, default 5120), the exporter's RSS (CMUX_NPI_RSS_MB, default 2900) and
# time (CMUX_NPI_SECONDS, default 120).
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
  DAIDIR=
  for d in "$(dirname "$TARGET")"/*.daidir; do
    if [ -d "$d/kdb.elab++" ]; then DAIDIR=$d; break; fi
  done
  [ -n "$DAIDIR" ] || say noKDB "$(dirname "$TARGET")"
fi
DAIDIR=$(cd "$DAIDIR" && pwd -P) || say noKDB "$TARGET"

# The cache key: the KDB's path, its files' newest mtime and total size, and this exporter.
stamp=$(find "$DAIDIR/kdb.elab++" -type f -printf '%T@ %s\n' 2>/dev/null | awk '{ if ($1 > m) m = $1; s += $2 } END { printf "%s %d", m, s }')
[ -n "$stamp" ] || say noKDB "$DAIDIR"
hash() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else cksum; fi; }
KEY=$( { printf '%s\n%s\n' "$DAIDIR" "$stamp"; cat npi-model.py; } | hash | cut -c1-32 | tr -d ' ')
MODEL="$CACHE/$KEY.json"

emit() {
  echo "$1"
  if [ "$PRINT" = "--print" ]; then cat "$MODEL"; echo; fi
  exit 0
}
if [ -s "$MODEL" ]; then
  touch "$MODEL" 2>/dev/null
  emit '{"ok":true,"cached":true}'
fi

if ! command -v verdi >/dev/null 2>&1 && type module >/dev/null 2>&1; then
  module load Synopsys_x86-64 >/dev/null 2>&1
fi
command -v verdi >/dev/null 2>&1 || say noVerdi ""
VERDI_HOME=${VERDI_HOME:-$(cd "$(dirname "$(command -v verdi)")/.." && pwd)}
export VERDI_HOME
available=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null)
[ -n "$available" ] && [ "$available" -lt "$MIN_MB" ] && say memory "MemAvailable ${available} MB"
mkdir -p "$CACHE" || say start "no cache folder $CACHE"
( ulimit -v $(( (RSS_MB + 4096) * 1024 )); exec nice -n 10 python3 npi-model.py "$DAIDIR" "$W/model.json" ) > npi.out 2> npi.err &
P=$!
trap 'kill "$P" 2>/dev/null' EXIT TERM HUP INT
peak=0
ticks=0
while kill -0 "$P" 2>/dev/null; do
  rss=$(ps -o rss= -p "$P" 2>/dev/null | tr -d ' ')
  rss=${rss:-0}
  [ "$rss" -gt "$peak" ] && peak=$rss
  if [ "$rss" -gt $((RSS_MB * 1024)) ]; then kill "$P"; say memory "the exporter passed ${RSS_MB} MB"; fi
  ticks=$((ticks + 1))
  if [ "$ticks" -gt $((SECONDS_CAP * 5)) ]; then kill "$P"; say time "the exporter ran past ${SECONDS_CAP} s"; fi
  sleep 0.2
done
wait "$P"
line=$(grep '^{' npi.out | tail -1)
[ -n "$line" ] || say start "$(grep -i -m1 -E 'error|licen' npi.err)"
case $line in
  '{"ok": true'*) ;;
  *)
    # Verdi's own words (a licence failure's) go with the exporter's error.
    why=$(grep -i -m1 -E 'licen[cs]e|error' npi.err | tr -d '"\\' | tr '\000-\037' ' ' | cut -c1-300)
    if [ -n "$why" ]; then echo "$line" | sed "s/\"message\": \"\([^\"]*\)\"/\"message\": \"\1 (Verdi: $(printf '%s' "$why" | sed 's/[&/|]/ /g'))\"/"; else echo "$line"; fi
    exit 0 ;;
esac
mv -f "$W/model.json" "$MODEL.tmp" && mv -f "$MODEL.tmp" "$MODEL" || say start "could not keep the model in $CACHE"
# The newest 8 models stay.
ls -1t "$CACHE"/*.json 2>/dev/null | tail -n +9 | while read -r old; do rm -f "$old"; done
emit "$(printf '%s' "$line" | sed 's/^{"ok": true, /{"ok": true, "cached": false, /; s/}$//'), \"peakMB\": $((peak / 1024))}"
