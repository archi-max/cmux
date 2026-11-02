#!/bin/bash
# run.sh machine-mutants: each mutant in mutants.js applied to a copy of cmux-machine-core.js must fail
# the machine-core checks. Usage: mutants.sh <compiled machine-core> <assets> <checks dir> <out dir>
set -uo pipefail
BIN="$1"; ASSETS="$2"; HERE="$3"; OUT="$4"
n=$(node -e "eval(require('fs').readFileSync('$HERE/mutants.js','utf8')); console.log(MACHINE_MUTANTS.length)")
killed=0; survived=0
for ((i = 0; i < n; i++)); do
  name=$(node -e "eval(require('fs').readFileSync('$HERE/mutants.js','utf8')); const [m,a,b]=MACHINE_MUTANTS[$i]; const s=require('fs').readFileSync('$ASSETS/cmux-machine-core.js','utf8'); if(!s.includes(a)){console.log('NOTFOUND '+m);process.exit(0)} require('fs').writeFileSync('$OUT/mutant.js', s.replace(a,b)); console.log(m)")
  case "$name" in NOTFOUND*) echo "FAIL mutant text not found: ${name#NOTFOUND }"; survived=$((survived + 1)); continue ;; esac
  if "$BIN" "$HERE/fixtures" "$ASSETS/cmux-expr.js" "$OUT/mutant.js" "$HERE/make-rvfi-vcd.js" "$HERE/core-cases.js" > "$OUT/mutant.log" 2>&1; then
    echo "FAIL survived: $name"; survived=$((survived + 1))
  else
    echo "ok   killed: $name ($(grep -c '^FAIL' "$OUT/mutant.log") checks fail)"; killed=$((killed + 1))
  fi
done
echo "MUTANTS: $killed killed, $survived survived of $n"
[ "$survived" -eq 0 ]
