#!/bin/bash
# cmux driver tracing, the Verdi engine's launcher (ours; it runs the host's installed Verdi and
# ships nothing of it). cmux sends this script and serve.tcl over SSH into a private scratch
# folder and runs `bash -l verdi-trace.sh <scratch> <dump.fsdb> [<simv>.daidir]`; stdin and stdout
# are serve.tcl's JSON lines. The KDB is the daidir next to the FSDB that holds kdb.elab++ (vcs
# -kdb), unless one is named. Without the FSDB, a KDB or Verdi, or when Verdi does not start, it prints
# {"id":0,"ready":false,"error":"noFile"|"noKDB"|"noVerdi"|"start","message":...}.
# Verdi's banner and logs stay in the scratch folder, removed when the session ends. While Verdi
# is not ready after CMUX_VERDI_SLOW_S seconds (default 20) it says "cmux-verdi: Verdi is still
# starting" on stderr, and when
# cmux's session goes (it gave up, or the viewer closed) Verdi is ended with it.
W=$1
FSDB=$2
DAIDIR=${3:-}
WATCH=
trap '[ -n "$WATCH" ] && kill "$WATCH" 2>/dev/null; rm -rf "$W"' EXIT
trap 'exit 1' TERM HUP INT
cd "$W" || exit 1
# The watchdog. cmux's session is gone when the parent is (ps, not kill -0: sshd's session may be
# another user's) or, over a shared connection (ControlMaster), when only the channel closed:
# sshd's session lingers but stdout has no reader, which a newline (cmux drops blank lines) shows.
# That probe runs until the ready line only: no JSON line can be split then, and afterwards
# serve.tcl ends at stdin's end itself.
SESSION=$PPID
LAUNCHER=$$
end_tree() {
  local c
  for c in $(pgrep -P "$1"); do
    [ "$c" = "$ME" ] && continue
    end_tree "$c"
    kill "$c" 2>/dev/null
  done
}
(
  # This subshell (bash 3 has no BASHPID): skipped when ending the launcher's processes.
  ME=${BASHPID:-$(exec sh -c 'echo $PPID')}
  exec 3>&1 >/dev/null
  said=
  trap '' PIPE
  while ps -p "$LAUNCHER" >/dev/null 2>&1; do
    if ! ps -p "$SESSION" >/dev/null 2>&1 || [ "$(ps -o ppid= -p "$LAUNCHER" | tr -d ' ')" != "$SESSION" ] \
      || { ! grep -q '^{"id":0,' "$W/verdi.out" 2>/dev/null && ! printf '\n' >&3 2>/dev/null; }; then
      end_tree "$LAUNCHER"
      kill "$LAUNCHER" 2>/dev/null
      exit 0
    fi
    if [ -z "$said" ] && [ "$SECONDS" -ge "${CMUX_VERDI_SLOW_S:-20}" ] && ! grep -q '^{"id":0,' "$W/verdi.out" 2>/dev/null; then
      echo "cmux-verdi: Verdi is still starting" >&2
      said=1
    fi
    sleep 1
  done
) &
WATCH=$!
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
  fail start "$(grep -v '^ ' "$W/verdi.out" | grep -v '^$' | tail -3 | tr '\n' ' ')"
fi
