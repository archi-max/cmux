#!/bin/bash
# cmux driver tracing, the Verdi engine's launcher (ours; it runs the host's installed Verdi and
# ships nothing of it). cmux sends this script and serve.tcl over SSH into a private scratch
# folder and runs `bash -l verdi-trace.sh <scratch> <dump.fsdb> [<simv>.daidir]`; stdin and stdout
# are serve.tcl's JSON lines. The KDB is the first daidir next to the FSDB (by name, in C order)
# that holds kdb.elab++ (vcs -kdb), unless one is named. Without the FSDB, a KDB or Verdi, or when
# Verdi does not start, it prints
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
  # (C order whatever the locale: the same KDB as npi-model.sh's)
  DAIDIR=$(LC_ALL=C; for d in "$(dirname "$FSDB")"/*.daidir; do
    if [ -d "$d/kdb.elab++" ]; then printf '%s' "$d"; break; fi
  done)
fi
{ [ -n "$DAIDIR" ] && [ -d "$DAIDIR/kdb.elab++" ]; } || fail noKDB "$(dirname "$FSDB")"
num() { case $1 in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
# CMUX_VERDI_SETUP runs in a subshell under a time cap (CMUX_VERDI_SETUP_SECONDS, default 30 s), so a
# setup that hangs (a module system's lock) ends there, with all it started; what it exported (PATH,
# the tool's environment) is read back into this shell, through a file of this run's own ($SETUP_ENV,
# made by mktemp in $W, so runs that share $W never read each other's). The setup runs under umask
# 077: what it writes is the user's only. 0 when it finished, 1 when it was ended at the cap, 2 when
# the file could not be made. The tree is what pgrep finds under the subshell when the cap is
# reached: a setup that double-forks (`(cmd &)`) leaves children already reparented to init, which
# outlive the cap.
verdi_setup() {
  local pid waited=0 cap=$1 tree more c
  SETUP_ENV=$(mktemp "$W/verdi-setup.XXXXXX") || return 2
  ( umask 077
    eval "$CMUX_VERDI_SETUP" < /dev/null > /dev/null 2>&1
    export -p > "$SETUP_ENV" ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((cap * 10)) ]; then
      # The whole tree, gathered before any of it is ended (so none is reparented out of reach).
      tree="$pid "
      while :; do
        more=$(for c in $tree; do echo "$c"; pgrep -P "$c"; done | sort -u | tr '\n' ' ')
        [ "$more" = "$tree" ] && break
        tree=$more
      done
      kill -9 $tree 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$SETUP_ENV"
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  return 0
}
# Verdi: on PATH, else in $VERDI_HOME/bin, else after CMUX_VERDI_SETUP (a command the user sets in
# their shell startup file, e.g. their site's module load). No site default.
if ! command -v verdi >/dev/null 2>&1 && [ -n "${VERDI_HOME:-}" ] && [ -x "$VERDI_HOME/bin/verdi" ]; then
  PATH=$VERDI_HOME/bin:$PATH
fi
if ! command -v verdi >/dev/null 2>&1 && [ -n "${CMUX_VERDI_SETUP:-}" ]; then
  SETUP_CAP=$(num "${CMUX_VERDI_SETUP_SECONDS:-}" 30)
  verdi_setup "$SETUP_CAP"
  case $? in
    1) fail noVerdi "CMUX_VERDI_SETUP did not finish in $SETUP_CAP s (CMUX_VERDI_SETUP_SECONDS sets the limit)" ;;
    2) fail start "cannot make a file in the scratch folder for CMUX_VERDI_SETUP" ;;
  esac
  # At the top level, so its declare -x lines stay global (read-only ones are refused, harmlessly).
  [ -s "$SETUP_ENV" ] && . "$SETUP_ENV" 2>/dev/null
  rm -f "$SETUP_ENV"
fi
command -v verdi >/dev/null 2>&1 || fail noVerdi "verdi is not on PATH, in VERDI_HOME/bin or after CMUX_VERDI_SETUP"
CMUX_VERDI_COMPILE_DIR=$(cd "$(dirname "$DAIDIR")" && pwd)
export CMUX_VERDI_COMPILE_DIR
# cmux's requests reach serve.tcl through this relay, which also ends the session (serve.tcl ends at
# stdin's end) once nothing has asked for CMUX_VERDI_IDLE_SECONDS (default 30 min). A connection
# whose client slept or vanished without closing (no EOF, sshd lingering) would otherwise keep
# Verdi and its memory for as long as TCP takes to notice. cmux starts the session
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
      # Verdi ended by itself (it could not start, a crash): so does the relay, at once, so that the
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
  fail start "$(grep -v '^ ' "$W/verdi.out" | grep -v '^$' | tail -3 | tr '\n' ' ')"
fi
