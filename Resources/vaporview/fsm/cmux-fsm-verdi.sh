#!/bin/bash
# cmux: the Verdi engine of the waveform viewer's state machine view. Written for cmux (GPL-3.0,
# like cmux). It runs on the host that has the dump, with the user's own Verdi installation,
# under the user's own licence. cmux ships no Synopsys code, headers or documentation, and
# nothing built against Verdi: this script only calls Verdi's own tools at run time.
#
# Usage: cmux-fsm-verdi.sh <fsdb> <scope> <signal> [<kdb>]
#   fsdb    the dump (absolute path on this host)
#   scope   the dump scope of the state register, dotted (tb.dut.u_ctl)
#   signal  its name in that scope (state)
#   kdb     a VCS -kdb database (<simv>.daidir); looked for next to the dump when left out
#
# Prints lines starting with "cmux-fsm: " (the protocol, read by WaveformFSMEngines.swift):
#   cmux-fsm: unavailable <reason> [detail]   reason: no-verdi | no-kdb | no-python | licence | no-fsm | failed
#   cmux-fsm: kdb <path>
#   cmux-fsm: instance <Verdi FSM instance name>
#   cmux-fsm: report-begin
#   ...Verdi's FSM analysis report (fsmAnalyzeFSM), as Verdi writes it...
#   cmux-fsm: report-end
# The exit status is 0 whenever one of those lines says what happened.
set -u
FSDB=$1
SCOPE=$2
SIGNAL=$3
KDB=${4:-}
say() { printf 'cmux-fsm: %s\n' "$*"; }

# Verdi: on PATH, else in $VERDI_HOME/bin, else after CMUX_VERDI_SETUP (a command the user sets,
# e.g. their site's module load). No site default.
if ! command -v verdi >/dev/null 2>&1 && [ -n "${VERDI_HOME:-}" ] && [ -x "$VERDI_HOME/bin/verdi" ]; then
  PATH=$VERDI_HOME/bin:$PATH
fi
if ! command -v verdi >/dev/null 2>&1 && [ -n "${CMUX_VERDI_SETUP:-}" ]; then
  eval "$CMUX_VERDI_SETUP" >/dev/null 2>&1
fi
command -v verdi >/dev/null 2>&1 || { say "unavailable no-verdi"; exit 0; }
if [ -z "${VERDI_HOME:-}" ]; then
  VERDI_HOME=$(dirname "$(dirname "$(command -v verdi)")")
  export VERDI_HOME
fi
[ -d "$VERDI_HOME/share/NPI/python" ] || { say "unavailable no-python NPI"; exit 0; }
command -v python3 >/dev/null 2>&1 || { say "unavailable no-python python3"; exit 0; }

# The KDB: the newest <name>.daidir/kdb.elab++ in the dump's folder or the one above it.
if [ -z "$KDB" ]; then
  D=$(dirname "$FSDB")
  KDB=$(find "$D" "$D/.." -maxdepth 3 -type d -name 'kdb.elab++' -path '*.daidir/*' -printf '%T@ %h\n' 2>/dev/null \
    | sort -rn | head -n 1 | cut -d' ' -f2-)
fi
[ -n "$KDB" ] && [ -d "$KDB" ] || { say "unavailable no-kdb"; exit 0; }
say "kdb $KDB"

W=$(mktemp -d "${TMPDIR:-/tmp}/cmux-fsm.XXXXXX") || { say "unavailable failed mktemp"; exit 0; }
trap 'rm -rf "$W"' EXIT
cd "$W" || exit 0

# Verdi's netlist model with FSM recognition (Python NPI): the FSM whose ports include the signal.
cat > find.py <<'PY'
import os, re, sys
sys.path.append(os.path.join(os.environ["VERDI_HOME"], "share", "NPI", "python"))
from pynpi import npisys, netlist
kdb, scope, signal = sys.argv[1], sys.argv[2], sys.argv[3]
# RecogFSM goes to init (load_design ignores it).
npisys.init(["cmux", "-npi_nl_rtl_opt", "RecogFSM+GenBlock"])
if not npisys.load_design(["cmux", "-dbdir", kdb]):
    print("cmux-fsm: unavailable failed load_design"); sys.exit(0)
found = None
inst = netlist.get_inst(scope)
for child in (inst.inst_list() if inst else None) or []:
    if child.inst_type() != "npiNlFSMInst":
        continue
    names = [re.sub(r"\[.*\]$", "", p.name()) for p in (child.instport_list() or [])]
    if signal in names:
        found = scope + "." + child.name()
        break
print("cmux-fsm: instance " + found if found else "cmux-fsm: unavailable no-fsm")
npisys.end()
PY
timeout 300 python3 find.py "$KDB" "$SCOPE" "$SIGNAL" > find.out 2> find.err
LINE=$(grep '^cmux-fsm: ' find.out | tail -n 1)
if [ -z "$LINE" ]; then
  if grep -qi 'licen' find.err find.out 2>/dev/null; then say "unavailable licence"; else say "unavailable failed npi $(tail -n 1 find.err)"; fi
  exit 0
fi
echo "$LINE"
case "$LINE" in "cmux-fsm: instance "*) ;; *) exit 0 ;; esac
INSTANCE=${LINE#cmux-fsm: instance }

# nState's batch analysis over the dump (states, transitions with conditions, counts).
printf 'fsmAnalyzeFSM -instance {%s} -fsdb {%s} -output {%s}\ndebExit\n' "$INSTANCE" "$FSDB" "$W/report.txt" > run.tcl
timeout 600 verdi -nogui -dbdir "$KDB" -ssf "$FSDB" -play run.tcl > verdi.out 2>&1 < /dev/null
if [ ! -s report.txt ]; then
  if grep -qiE 'licen[cs]e.*(not available|fail|denied|unable)|no such feature|checkout' verdi.out; then
    say "unavailable licence"
  else
    say "unavailable failed verdi $(tail -n 1 verdi.out)"
  fi
  exit 0
fi
say "report-begin"
cat report.txt
say "report-end"
exit 0
