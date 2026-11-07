#!/bin/bash
# Regenerates oracle-loads/*.json: Verdi's loads of every signal of each design (npi-loads.py,
# lang.trace_load2), from a VCS -kdb compile of designs/. Needs vcs on PATH and VERDI_HOME set
# (nothing guessed; run your site's setup first). Signals: every instance's signals in
# models/<design>.json (regenerate the models first). Compiles in a scratch folder.
#   regen-loads.sh <scratch dir> [out dir, default oracle-loads]   (DESIGNS="n" for some only)
# k is left out: VCS rejects it (an undefined system task, a driven variable input port).
set -eu
W=${1:?scratch dir}
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=${2:-$HERE/oracle-loads}
command -v vcs >/dev/null || { echo "regen-loads.sh: vcs is not on PATH" >&2; exit 2; }
[ -n "${VERDI_HOME:-}" ] || { echo "regen-loads.sh: VERDI_HOME is not set" >&2; exit 2; }
mkdir -p "$W" "$OUT"
for d in ${DESIGNS:-a b c e f g h i j l n}; do
  rm -rf "$W/$d"; mkdir -p "$W/$d"
  python3 -c 'import json,sys
m = json.load(open(sys.argv[1]))
print("".join(p + "." + s + "\n" for p, i in m["instances"].items() for s in i["signals"]), end="")' "$HERE/models/$d.json" > "$W/$d/signals.txt"
  (cd "$W/$d" && nice -n 10 vcs -full64 -sverilog -debug_access+all -kdb -lca +define+FSDB -top tb_$d \
     "$HERE"/designs/${d}_*.sv "$HERE/designs/tb_$d.sv" -o simv -l comp.log >/dev/null 2>&1) \
    || { tail -20 "$W/$d/comp.log" >&2; exit 1; }
  (cd "$W/$d" && nice -n 10 python3 "$HERE/npi-loads.py" simv.daidir signals.txt "$OUT/$d.json")
done
