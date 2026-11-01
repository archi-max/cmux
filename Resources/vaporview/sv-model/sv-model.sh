#!/bin/sh
# Starts cmux-sv-model (driver tracing's design model; see build.sh) for cmux. Requests and
# replies are JSON lines on stdin/stdout; slang's own messages go to stderr. Runs under nice: an
# elaboration of a large design is CPU-heavy and shares the host.
# Exits 87, which makes cmux rebuild, when the installed program is missing or does not start.
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -x "$HERE/cmux-sv-model" ] || exit 87
exec nice -n 10 "$HERE/cmux-sv-model"
