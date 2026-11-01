#!/bin/bash
# gen-verilog.sh <VexRiscv-checkout> <workdir>: generate VexRiscv.v for the FormalSimple demo config
# (src/main/scala/vexriscv/demo/FormalSimple.scala: 5 stages, FormalPlugin RVFI port, no bypassing,
# DYNAMIC_TARGET branch prediction, HaltOnException). Copies only build.sbt/project/src/main of the
# checkout; downloads an sbt launcher and keeps every sbt/coursier cache under <workdir>, so nothing
# is written to ~/.sbt, ~/.ivy2 or ~/.cache. sbt.version is overridden to 1.10.7 (the repo pins 1.6.0,
# which predates JDK 21). Delete <workdir> afterwards (~260 MB of caches).
set -euo pipefail
SRC="$1"; W="$2"; mkdir -p "$W/VexRiscv/src"
cp -R "$SRC/build.sbt" "$SRC/project" "$W/VexRiscv/"; cp -R "$SRC/src/main" "$W/VexRiscv/src/"
[ -x "$W/sbt-home/sbt/bin/sbt" ] || { mkdir -p "$W/sbt-home"; curl -sL https://github.com/sbt/sbt/releases/download/v1.10.7/sbt-1.10.7.tgz | tar xz -C "$W/sbt-home"; }
cd "$W/VexRiscv"
export COURSIER_CACHE="$W/cs-cache"
export SBT_OPTS="-Dsbt.global.base=$W/sbt-global -Dsbt.ivy.home=$W/ivy -Dsbt.boot.directory=$W/sbt-boot -Dsbt.version=1.10.7"
nice "$W/sbt-home/sbt/bin/sbt" -batch -Dsbt.server.autostart=false "runMain vexriscv.demo.FormalSimple"
ls -la "$W/VexRiscv/VexRiscv.v"
