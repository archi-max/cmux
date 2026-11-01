#!/bin/bash
# Regenerates models/*.json with cmux-sv-model (paths made relative to designs/).
#   regen-models.sh <cmux-sv-model binary> [out dir, default models]
set -eu
M=${1:?cmux-sv-model binary}
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=${2:-$HERE/models}
mkdir -p "$OUT"
cd "$HERE/designs"
D="$(pwd -P)/"
gen() { "$M" --once '*' "$@" | tail -1 | sed "s|$D||g"; }
for d in ${DESIGNS:-a b c e f g h}; do
  gen --top tb_$d ${d}_*.sv tb_$d.sv > "$OUT/$d.json"
done
gen --top tb_c -D__ICARUS__ c_struct.sv tb_c.sv > "$OUT/c.icarus.json"
