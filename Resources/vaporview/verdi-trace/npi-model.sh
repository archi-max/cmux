#!/bin/bash
# cmux driver tracing, the KDB design model's launcher (ours; it runs the host's installed Verdi and
# ships nothing of it). cmux sends this script and npi-model.py over SSH into a private scratch
# folder and runs `bash -l npi-model.sh <scratch> <simv>.daidir <out.json>`. It prints npi-model.py's
# one JSON line ({"ok": true, "seconds", "instances", "signals"} or {"ok": false, "error", ...}) and
# "peakRSS" in MB. The export holds a Verdi licence seat for its load and walk only (seconds); it is
# not retried here when the seat is denied. Guards: the host's MemAvailable (CMUX_NPI_MIN_AVAILABLE_MB,
# default 5120), the exporter's RSS (CMUX_NPI_RSS_MB, default 2900) and time (CMUX_NPI_SECONDS, 120).
W=$1
DAIDIR=$2
OUT=$3
cd "$W" || exit 1
say() { printf '{"ok":false,"error":"%s","message":"%s"}\n' "$1" "$(printf '%s' "$2" | tr -d '"\\' | tr '\000-\037' ' ' | cut -c1-400)"; exit 0; }
num() { case $1 in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
MIN_MB=$(num "${CMUX_NPI_MIN_AVAILABLE_MB:-}" 5120)
RSS_MB=$(num "${CMUX_NPI_RSS_MB:-}" 2900)
SECONDS_CAP=$(num "${CMUX_NPI_SECONDS:-}" 120)
[ -d "$DAIDIR/kdb.elab++" ] || say noKDB "$DAIDIR"
if ! command -v verdi >/dev/null 2>&1 && type module >/dev/null 2>&1; then
  module load Synopsys_x86-64 >/dev/null 2>&1
fi
command -v verdi >/dev/null 2>&1 || say noVerdi ""
VERDI_HOME=${VERDI_HOME:-$(cd "$(dirname "$(command -v verdi)")/.." && pwd)}
export VERDI_HOME
available=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null)
[ -n "$available" ] && [ "$available" -lt "$MIN_MB" ] && say memory "MemAvailable ${available} MB"
( ulimit -v $(( (RSS_MB + 4096) * 1024 )); exec nice -n 10 python3 npi-model.py "$DAIDIR" "$OUT" ) > npi.out 2> npi.err &
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
echo "$line"
echo "peakRSS $((peak / 1024))"
