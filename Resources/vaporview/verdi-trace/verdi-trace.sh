#!/bin/bash
# cmux driver tracing, the Verdi engine's launcher (ours; it runs the host's installed Verdi and
# ships nothing of it). cmux sends this script and serve.tcl over SSH into a private scratch
# folder and runs `bash -l verdi-trace.sh <scratch> <dump.fsdb> [<simv>.daidir]`; stdin and stdout
# are serve.tcl's JSON lines. The KDB is the daidir next to the FSDB that holds kdb.elab++ (vcs
# -kdb), unless one is named. Without the FSDB, a KDB, Verdi, or a Verdi licence seat, it prints
# {"id":0,"ready":false,"error":"noFile"|"noKDB"|"noVerdi"|"licence"|"start","message":...}.
# Verdi's banner and logs stay in the scratch folder, removed when the session ends.
W=$1
FSDB=$2
DAIDIR=${3:-}
trap 'rm -rf "$W"' EXIT
cd "$W" || exit 1
fail() {
  local message
  message=$(printf '%s' "$2" | tr -d '"\\' | tr '\000-\037' ' ' | cut -c1-400)
  printf '\n{"id":0,"ready":false,"error":"%s","message":"%s"}\n' "$1" "$message"
  exit 0
}
[ -r "$FSDB" ] || fail noFile "$FSDB"
if [ -z "$DAIDIR" ]; then
  for d in "$(dirname "$FSDB")"/*.daidir; do
    if [ -d "$d/kdb.elab++" ]; then DAIDIR=$d; break; fi
  done
fi
{ [ -n "$DAIDIR" ] && [ -d "$DAIDIR/kdb.elab++" ]; } || fail noKDB "$(dirname "$FSDB")"
if ! command -v verdi >/dev/null 2>&1 && type module >/dev/null 2>&1; then
  module load Synopsys_x86-64 >/dev/null 2>&1
fi
command -v verdi >/dev/null 2>&1 || fail noVerdi ""
CMUX_VERDI_COMPILE_DIR=$(cd "$(dirname "$DAIDIR")" && pwd)
export CMUX_VERDI_COMPILE_DIR
# Only serve.tcl's lines reach cmux; the rest is kept for the failure message.
nice -n 10 verdi -nogui -dbdir "$DAIDIR" -ssf "$FSDB" -play "$W/serve.tcl" 2>&1 | tee -a "$W/verdi.out" | grep --line-buffered '^{"id":'
if ! grep -q '^{"id":0,"ready":true' "$W/verdi.out"; then
  if grep -qi 'could not checkout.*licen[cs]e' "$W/verdi.out"; then
    fail licence "$(grep -i 'could not checkout' "$W/verdi.out" | tail -1)"
  fi
  fail start "$(grep -v '^ ' "$W/verdi.out" | grep -v '^$' | tail -3 | tr '\n' ' ')"
fi
