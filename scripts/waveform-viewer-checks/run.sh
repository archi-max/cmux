#!/bin/bash
# Checks for the waveform viewer that run outside the app: the bundled page
# (Resources/vaporview) in an off-screen WKWebView through the app's own
# scheme handler and FSDB helper sources. Needs Xcode's swiftc; no window is
# shown.
#
#   ./run.sh xss                         markup in VCD signal names stays inert,
#                                        the CSP blocks inline handlers, and
#                                        range/router/FrameParser unit checks
#   ./run.sh link                        the SystemVerilog editor's source link
#                                        API (link.* in host.js) on link.vcd
#   ./run.sh debugger                    the waveform debugger (cmux-debugger.js):
#                                        clock, stepping, play, Locals, highlights
#   ./run.sh fsdb-values <ssh-host> <shown> <unshown> <over-cap> <mid1> <mid2> <mid3>
#                                        inline values from a remote FSDB (dump
#                                        paths of: a signal to show, one not
#                                        shown, one over 1M changes, three under
#                                        1M that pass 2M together); the file is
#                                        CMUX_FSDB_VALUES_FILE. Skipped without
#                                        it or when the host can't be reached
#   ./run.sh fsdb <ssh-host> <remote.fsdb> <signal.path>...
#                                        open a remote FSDB through the helper
#                                        (built on the host on first use) and
#                                        print per-signal timings and memory
#   ./run.sh parity                      terminal-link matcher (50k-char lines),
#                                        link misses fall through, settings
#                                        clamps, no page-named save path,
#                                        missing-signal rows, double reload
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ASSETS="$ROOT/Resources/vaporview"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-waveform-checks.XXXXXX")"
trap '[ -n "${KEEP_OUT:-}" ] || rm -rf "$OUT"' EXIT
case "${1:-}" in
  xss)
    swiftc -O "$HERE/xss/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/xss"
    "$OUT/xss" "$ASSETS" "$HERE/xss-signal-names.vcd" "$OUT/xss.png"
    ;;
  link)
    swiftc -O "$HERE/link/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/link"
    "$OUT/link" "$ASSETS" "$HERE/link/link.vcd" "$OUT/link.png" | tee "$OUT/link.log"
    grep -q '^LINK CHECKS PASSED' "$OUT/link.log"
    ;;
  debugger)
    swiftc -O "$HERE/debugger/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/debugger"
    python3 "$HERE/debugger/make-vcd.py" "$OUT"
    for dump in small stepping; do
      "$OUT/debugger" "$ASSETS" "$OUT/$dump.vcd" "$OUT/$dump.png" | tee "$OUT/$dump.log"
      grep -q '^DEBUGGER CHECKS PASSED' "$OUT/$dump.log"
    done
    ;;
  fsdb-values)
    shift
    if [ $# -lt 7 ] || [ -z "${CMUX_FSDB_VALUES_FILE:-}" ]; then
      echo "fsdb-values: skipped (needs <ssh-host> and six signal paths, and CMUX_FSDB_VALUES_FILE)"; exit 0
    fi
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$1" true 2>/dev/null; then
      echo "fsdb-values: skipped ($1 not reachable)"; exit 0
    fi
    swiftc -O "$HERE/fsdb-values/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/fsdb-values"
    host="$1"; shift
    "$OUT/fsdb-values" "$ASSETS" "$ASSETS/fsdb-helper" "$host" "$CMUX_FSDB_VALUES_FILE" "$OUT/fsdb-values.png" "$@" \
      | grep -v '^\[log\]' | tee "$OUT/fsdb-values.log"
    grep -q '^FSDB VALUE CHECKS PASSED' "$OUT/fsdb-values.log"
    ;;
  fsdb)
    shift
    swiftc -O "$HERE/fsdb/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/fsdb"
    host="$1" file="$2"; shift 2
    "$OUT/fsdb" "$ASSETS" "$ASSETS/fsdb-helper" "$host" "$file" "$OUT/fsdb.png" "$@"
    ;;
  parity)
    swiftc -O "$HERE/parity/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" \
      "$ROOT/Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/LinkRouting/WaveformTerminalLink.swift" \
      -o "$OUT/parity"
    "$OUT/parity" "$ASSETS" "$HERE/parity/parity.vcd"
    ;;
  *) sed -n "2,$(( $(grep -n '^set -euo' "$0" | cut -d: -f1) - 1 ))p" "$0"; exit 2 ;;
esac
