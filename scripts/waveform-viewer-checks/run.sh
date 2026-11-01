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
#   ./run.sh enum                        enum member names (cmux-enum.js): rows
#                                        get their enum's alias table as a default,
#                                        undo, user formats, raw valuesAt
#   ./run.sh enum-link                   the app's enum type wiring (the real
#                                        WaveformEnumLink.swift on a scripted
#                                        session): saves, slang's reports, reloads,
#                                        refused reads; and its call sites
#   ./run.sh debugger                    the waveform debugger (cmux-debugger.js):
#                                        clock, stepping, play, Locals, highlights
#   ./run.sh debugger-fsdb <ssh-host> <remote.fsdb> <scope.path>
#                                        the debugger on a remote FSDB (helper
#                                        under nice): clock, steps, Locals
#   ./run.sh debugger-editor             the debugger's editor highlights
#                                        (WaveformDebuggerEditorHighlights.swift)
#                                        on a windowless NSTextView
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
#   ./run.sh fsdb-locals                 FSDB inline values of pinned signals
#                                        while the debugger's Locals shows,
#                                        refills and removes the same signals
#                                        (helper stand-in, no host)
#   ./run.sh windowed                    windowed FSDB viewing (protocol v2) with a mock
#                                        helper run locally through the real
#                                        WaveformFSDBHelper (sh in place of ssh):
#                                        relay partial/cancel/fallback, page
#                                        windowing, hybrid, edges, values, debugger;
#                                        needs node
#   ./run.sh windowed-fsdb <ssh-host> <remote-home> <remote.fsdb> <scopes> <signals> [runs]
#                                        ship gate: windowed (helper v2) vs whole
#                                        (helper v1) on a real dump, side by side:
#                                        first draw, pan in the first 5 s, pan,
#                                        zoom, jumps, next edge, peak RSS. Helpers
#                                        install under <remote-home> on the host;
#                                        scopes/signals are comma-separated paths
#   ./run.sh windowed-launcher <ssh-host> <remote-dir>
#                                        the real fsdb-helper-v2 build.sh and
#                                        cmux-helper-v2.sh on the host, in a
#                                        scratch HOME under <remote-dir>: build,
#                                        launch, privacy refusals (86), 87,
#                                        rebuild of a non-private install, a
#                                        build stopping when its ssh goes away
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
  enum)
    swiftc -O "$HERE/enum/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/enum"
    "$OUT/enum" "$ASSETS" "$HERE/enum/fsm.vcd" "$OUT/enum.png" | tee "$OUT/enum.log"
    grep -q '^ENUM CHECKS PASSED' "$OUT/enum.log"
    ;;
  link)
    swiftc -O "$HERE/link/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/link"
    "$OUT/link" "$ASSETS" "$HERE/link/link.vcd" "$OUT/link.png" | tee "$OUT/link.log"
    grep -q '^LINK CHECKS PASSED' "$OUT/link.log"
    ;;
  enum-link)
    L="$ROOT/Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient"
    # One module here: the package import goes, and SlangEnumTypes.swift's session extension
    # (slang requests) is replaced by the scripted session in stubs.swift.
    sed '/^import CmuxSyntaxHighlighting$/d' "$ROOT/Sources/Panels/WaveformEnumLink.swift" > "$OUT/enum-link.swift"
    awk '/^extension LanguageServerSession \{/ { skip = 1 } !skip { print } skip && /^}$/ { skip = 0 }' "$L/SlangEnumTypes.swift" > "$OUT/enum-types.swift"
    swiftc -swift-version 6 -O "$HERE/enum-link/main.swift" "$HERE/enum-link/stubs.swift" "$OUT/enum-link.swift" "$OUT/enum-types.swift" \
      "$L/JSONValue.swift" "$L/LSPTypes.swift" "$L/LSPResponseDecoding.swift" "$L/HierarchyPathMapping.swift" -o "$OUT/enum-link"
    "$OUT/enum-link" "$ROOT" | tee "$OUT/enum-link.log"
    grep -q '^ENUM LINK CHECKS PASSED' "$OUT/enum-link.log"
    ;;
  debugger-editor)
    L="$ROOT/Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient"
    # One module here: the package import goes, and SlangDriverCone.swift's session extension is stubbed.
    sed '/^import CmuxSyntaxHighlighting$/d' "$ROOT/Sources/Panels/WaveformDebuggerEditorHighlights.swift" > "$OUT/highlights.swift"
    sed '/^import CmuxSyntaxHighlighting$/d' "$ROOT/Sources/Panels/WaveformDebuggerRTLStatus.swift" > "$OUT/rtl-status.swift"
    sed '/^extension LanguageServerSession/,$d' "$L/SlangDriverCone.swift" > "$OUT/cone.swift"
    swiftc -swift-version 6 -O "$HERE/debugger-editor/main.swift" "$HERE/debugger-editor/stubs.swift" "$OUT/highlights.swift" "$OUT/rtl-status.swift" "$OUT/cone.swift" \
      "$L/SystemVerilogInlineScan.swift" "$L/HierarchyPathMapping.swift" "$L/WaveformCycleHighlights.swift" "$L/LSPTypes.swift" \
      -o "$OUT/debugger-editor"
    "$OUT/debugger-editor"
    ;;
  debugger-fsdb)
    shift
    if [ $# -lt 3 ]; then echo "debugger-fsdb: needs <ssh-host> <remote.fsdb> <locals.scope.path>"; exit 2; fi
    swiftc -O "$HERE/debugger-fsdb/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/debugger-fsdb"
    "$OUT/debugger-fsdb" "$ASSETS" "$ASSETS/fsdb-helper" "$1" "$2" "$3" "$OUT/debugger-fsdb.png" | grep -v '^\[log\]' | tee "$OUT/debugger-fsdb.log"
    grep -q '^DEBUGGER FSDB CHECKS PASSED' "$OUT/debugger-fsdb.log"
    ;;
  fsdb-locals)
    swiftc -O "$HERE/fsdb-locals/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/fsdb-locals"
    "$OUT/fsdb-locals" "$ASSETS" "$OUT/fsdb-locals.png" | grep -v '^\[log\]' | tee "$OUT/fsdb-locals.log"
    grep -q '^FSDB LOCALS CHECKS PASSED' "$OUT/fsdb-locals.log"
    ;;
  windowed)
    command -v node >/dev/null || { echo "windowed: needs node"; exit 2; }
    # The app builds these in Swift 6 mode; the harness itself is built in 5.
    swiftc -swift-version 6 -typecheck "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift"
    swiftc -O "$HERE/windowed/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/windowed"
    "$OUT/windowed" "$ASSETS" "$ASSETS/fsdb-helper-v2" "$ASSETS/fsdb-helper" "$HERE/windowed/mock-helper-v2.cjs" \
      "$OUT" "$OUT/windowed.png" | grep -v '^\[log\]' | tee "$OUT/windowed.log"
    grep -q '^WINDOWED CHECKS PASSED' "$OUT/windowed.log"
    # The real build.sh and cmux-helper-v2.sh, against the mock, on a scratch HOME.
    bash "$HERE/windowed/scripts-check.sh" "$ASSETS/fsdb-helper-v2" "$HERE/windowed/mock-helper-v2.cjs" "$OUT/scripts-check"
    ;;
  windowed-launcher)
    shift
    if [ $# -lt 2 ]; then echo "windowed-launcher: needs <ssh-host> <remote-dir>"; exit 2; fi
    bash "$HERE/windowed-fsdb/launcher-check.sh" "$ASSETS/fsdb-helper-v2" "$1" "$2"
    ;;
  windowed-fsdb)
    shift
    if [ $# -lt 5 ]; then echo "windowed-fsdb: needs <ssh-host> <remote-home> <remote.fsdb> <scopes> <signals> [runs]"; exit 2; fi
    swiftc -O "$HERE/windowed-fsdb/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/windowed-fsdb"
    "$OUT/windowed-fsdb" "$ASSETS" "$ASSETS/fsdb-helper-v2" "$ASSETS/fsdb-helper" "$HERE/windowed-fsdb/bench.js" \
      "$1" "$2" "$3" "$4" "$5" "${6:-1}" "${GATE_OUT:-$OUT/windowed-fsdb.json}" | grep -v '^\[log\]'
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
