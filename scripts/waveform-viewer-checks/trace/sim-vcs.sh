#!/bin/bash
# Simulates the trace fixtures with VCS (FSDB +all and VCD), plain and with X-propagation:
# -xprop=flowctrl alone, -xprop=tmerge, and "course" (an xprop.config of merge=tmerge,
# xindex_select_method=resolution, xpropOn for the dut instance, plus -xprop=flowctrl, the way
# typical course flows build), for the checks in this folder. Run it on a host with VCS,
# in a scratch folder holding designs/:   bash sim-vcs.sh <scratch dir> (DESIGNS="f" for some only)
# Outputs <scratch>/out/<design>.<variant>.{fsdb,vcd}.
set -eu
W=${1:?scratch dir}
cd "$W"
module load Synopsys_x86-64 >/dev/null 2>&1 || true
mkdir -p out
for d in ${DESIGNS:-a b c e f g h}; do
  src=$(ls designs/${d}_*.sv)
  for variant in plain flowctrl tmerge course; do
    case $variant in
      plain) X= ;;
      flowctrl) X=-xprop=flowctrl ;;
      tmerge) X=-xprop=tmerge ;;
      course)
        printf 'merge=tmerge;\nxindex_select_method=resolution;\ninstance {tb_%s.dut} {xpropOn};\n' "$d" > "xprop_$d.config"
        X="-xprop=$PWD/xprop_$d.config -xprop=flowctrl" ;;
    esac
    rm -rf "sim_$d.$variant"; mkdir "sim_$d.$variant"; cd "sim_$d.$variant"
    nice -n 10 vcs -full64 -sverilog -debug_access+all -kdb -lca $X +define+FSDB -top tb_$d \
      "../$src" "../designs/tb_$d.sv" -o simv -l comp.log >/dev/null 2>&1 || { tail -30 comp.log; exit 1; }
    nice -n 10 ./simv -l run.log >/dev/null 2>&1 || { tail -30 run.log; exit 1; }
    cp "$d.fsdb" "../out/$d.$variant.fsdb"; cp "$d.vcd" "../out/$d.$variant.vcd"
    cd ..
  done
done
ls -la out
