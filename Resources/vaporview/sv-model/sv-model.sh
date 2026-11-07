#!/bin/sh
# Starts cmux-sv-model (driver tracing's design model; see build.sh) for cmux. Requests and
# replies are JSON lines on stdin/stdout; slang's own messages go to stderr. Runs under nice: an
# elaboration of a large design is CPU-heavy and shares the host.
# Exits 87, which makes cmux rebuild, when the installed program is missing or does not start.
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -x "$HERE/cmux-sv-model" ] || exit 87
# The build cmux-sv-model says in its ready line: the install folder, named by the hash of its
# sources (a design's fingerprint includes it, so another build is another design).
CMUX_SV_MODEL_BUILD="$(basename "$HERE")"
export CMUX_SV_MODEL_BUILD
exec nice -n 10 "$HERE/cmux-sv-model"
