#!/bin/bash
# cmux driver tracing, the Verdi engine's launcher (ours; it runs the host's installed Verdi and
# ships nothing of it). cmux sends this script and serve.tcl over SSH into a private scratch
# folder and runs `bash -l verdi-trace.sh <scratch> <dump.fsdb> [<simv>.daidir]`; stdin and stdout
# are serve.tcl's JSON lines. The KDB is the first daidir next to the FSDB (by name, in C order)
# that holds kdb.elab++ (vcs -kdb), unless one is named. Without the FSDB, a KDB, Verdi, or a Verdi licence seat, it prints
# {"id":0,"ready":false,"error":"noFile"|"noKDB"|"noVerdi"|"licence"|"start","message":...}.
# Verdi's banner and logs stay in the scratch folder, removed when the session ends. While Verdi
# waits for a licence seat it says "cmux-verdi: waiting for a Verdi licence" on stderr, and when
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
    if [ -z "$said" ] && grep -qiE 'licen[cs]e is not available|waiting for .*licen[cs]e' "$W/verdi.out" 2>/dev/null; then
      echo "cmux-verdi: waiting for a Verdi licence" >&2
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
  # (C order whatever the locale: the same KDB as npi-model.sh's)
  DAIDIR=$(LC_ALL=C; for d in "$(dirname "$FSDB")"/*.daidir; do
    if [ -d "$d/kdb.elab++" ]; then printf '%s' "$d"; break; fi
  done)
fi
{ [ -n "$DAIDIR" ] && [ -d "$DAIDIR/kdb.elab++" ]; } || fail noKDB "$(dirname "$FSDB")"
if ! command -v verdi >/dev/null 2>&1 && type module >/dev/null 2>&1; then
  module load Synopsys_x86-64 >/dev/null 2>&1
fi
command -v verdi >/dev/null 2>&1 || fail noVerdi ""
CMUX_VERDI_COMPILE_DIR=$(cd "$(dirname "$DAIDIR")" && pwd)
export CMUX_VERDI_COMPILE_DIR
# cmux's requests reach serve.tcl through this relay, which also ends the session (serve.tcl ends at
# stdin's end) once nothing has asked for CMUX_VERDI_IDLE_SECONDS (default 30 min). A connection
# whose client slept or vanished without closing (no EOF, sshd lingering) would otherwise keep
# Verdi, its memory and a licence seat for as long as TCP takes to notice. cmux starts the session
# again on the next trace.
IDLE=${CMUX_VERDI_IDLE_SECONDS:-1800}
case $IDLE in ''|*[!0-9]*) IDLE=1800 ;; esac
relay() {
  local line part idle=0 status began pid
  trap '' PIPE
  while :; do
    began=$SECONDS
    if IFS= read -r -t 1 part; then
      printf '%s\n' "$line$part" || return 0
      line= idle=0
    else
      status=$?
      # A timeout keeps what came of a line; stdin's end returns at once. bash 4+ says a timeout
      # with a status over 128; bash 3.2 (macOS) says 1 for both, so a read that took its second
      # is a timeout too (an end misjudged at a second's boundary is seen at the next read).
      [ "$status" -gt 128 ] || [ $((SECONDS - began)) -ge 1 ] || return 0
      line=$line$part
      idle=$((idle + 1))
      [ "$idle" -lt "$IDLE" ] || return 0
      # Verdi ended by itself (no licence seat, a crash): so does the relay, at once, so that the
      # launcher reports why instead of holding the pipeline open until the idle limit.
      pid=$(cat "$W/verdi.pid" 2>/dev/null)
      [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null || return 0
    fi
  done
}
# Only serve.tcl's lines reach cmux; the rest is kept for the failure message.
# Verdi runs in the background (its pid for the relay) on the relay's output: fd 4, since an
# asynchronous command's stdin is otherwise /dev/null.
rm -f "$W/verdi.pid"
relay | {
  exec 4<&0
  nice -n 10 verdi -nogui -dbdir "$DAIDIR" -ssf "$FSDB" -play "$W/serve.tcl" <&4 4<&- 2>&1 &
  echo $! > "$W/verdi.pid"
  exec 4<&-
  wait $!
} | tee -a "$W/verdi.out" | grep --line-buffered '^{"id":'
if ! grep -q '^{"id":0,"ready":true' "$W/verdi.out"; then
  if grep -qi 'could not checkout.*licen[cs]e' "$W/verdi.out"; then
    fail licence "$(grep -i 'could not checkout' "$W/verdi.out" | tail -1)"
  fi
  fail start "$(grep -v '^ ' "$W/verdi.out" | grep -v '^$' | tail -3 | tr '\n' ' ')"
fi
