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
#   ./run.sh fsdb <ssh-host> <remote.fsdb> <signal.path>...
#                                        open a remote FSDB through the helper
#                                        (built on the host on first use) and
#                                        print per-signal timings and memory
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ASSETS="$ROOT/Resources/vaporview"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-waveform-checks.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
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
  fsdb)
    shift
    swiftc -O "$HERE/fsdb/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/fsdb"
    host="$1" file="$2"; shift 2
    "$OUT/fsdb" "$ASSETS" "$ASSETS/fsdb-helper" "$host" "$file" "$OUT/fsdb.png" "$@"
    ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
