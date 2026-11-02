#!/bin/bash
# cmux: the Yosys engine of the waveform viewer's state machine view, for a design on another
# host (cmux runs Yosys itself when the design is on this Mac). Written for cmux (GPL-3.0, like
# cmux). It runs the user's own Yosys (https://yosyshq.net/yosys/, ISC; OSS CAD Suite ships one
# with sv-elab's read_slang); cmux ships no Yosys.
#
# Usage: cmux-fsm-yosys.sh <slang script> <native script> [<yosys>]
#   slang script   base64 of the Yosys script that reads the design with read_slang
#   native script  base64 of the same with read_verilog -sv (for a Yosys without read_slang)
#   yosys          the Yosys to run; looked for on PATH and in the usual OSS CAD Suite folders
#                  when empty
# Both scripts write fsm.json in the current folder (a private one this script makes).
#
# Prints lines starting with "cmux-fsm: " (read by YosysFsm.remoteOutcome):
#   cmux-fsm: unavailable <reason> [detail]   reason: no-yosys | failed
#   cmux-fsm: yosys <path> slang|native
#   cmux-fsm: json-begin
#   ...Yosys's write_json output...
#   cmux-fsm: json-end
set -u
SLANG=$1
NATIVE=$2
YOSYS=${3:-}
say() { printf 'cmux-fsm: %s\n' "$*"; }
# timeout(1) where there is one (not on macOS).
limit() { local seconds=$1; shift; if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"; else "$@"; fi; }

if [ -n "$YOSYS" ]; then
  [ -x "$YOSYS" ] || { say "unavailable no-yosys $YOSYS"; exit 0; }
else
  YOSYS=$(command -v yosys 2>/dev/null)
  for d in "$HOME/oss-cad-suite/bin" "/opt/oss-cad-suite/bin" "/usr/local/oss-cad-suite/bin"; do
    [ -n "$YOSYS" ] && break
    [ -x "$d/yosys" ] && YOSYS="$d/yosys"
  done
  [ -n "$YOSYS" ] || { say "unavailable no-yosys"; exit 0; }
fi

W=$(mktemp -d "${TMPDIR:-/tmp}/cmux-fsm-yosys.XXXXXX") || { say "unavailable failed mktemp"; exit 0; }
trap 'rm -rf "$W"' EXIT
cd "$W" || exit 0

# read_slang is in OSS CAD Suite's Yosys and some builds from 0.67 on. Not -q: that hides help's
# answer; a missing command is answered "No such command".
if limit 60 "$YOSYS" -p 'help read_slang' 2>&1 | grep -q 'read_slang \[options\]'; then
  KIND=slang; SCRIPT=$SLANG
else
  KIND=native; SCRIPT=$NATIVE
fi
say "yosys $YOSYS $KIND"
printf '%s' "$SCRIPT" | base64 -d > fsm.ys 2>/dev/null || { say "unavailable failed the script could not be decoded"; exit 0; }
limit 300 nice -n 10 "$YOSYS" -q -s fsm.ys > yosys.out 2>&1 < /dev/null
STATUS=$?
if [ "$STATUS" -ne 0 ] || [ ! -s fsm.json ]; then
  LINE=$(grep -m 1 'ERROR' yosys.out)
  [ -n "$LINE" ] || LINE=$(grep -v '^[[:space:]]*$' yosys.out | tail -n 1)
  say "unavailable failed ${LINE:-yosys exited with $STATUS}"
  exit 0
fi
say "json-begin"
cat fsm.json
echo
say "json-end"
exit 0
