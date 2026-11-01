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
#   ./run.sh breakpoints                 debugger breakpoints: continue, reverse, landing, play stops, list
#   ./run.sh line-breakpoints            line breakpoints: F9, gutter, edits, instances, session
#   ./run.sh trace                       driver tracing's engine (cmux-trace.js): active drivers on the
#                                        trace fixtures' models and VCS/Icarus dumps, and the replay oracle
#   ./run.sh trace-ui                    driver tracing's page (cmux-trace-ui.js): Trace Driver from a
#                                        row and a path, the panel, fan-in clicks, Back/Forward, the row
#                                        menu, errors; the harness answers as cmux from trace/models
#   ./run.sh trace-smoke <model.json> <dump.vcd>
#                                        the replay oracle on one real design (cmux-sv-model --once '*'
#                                        output and its VCD): steps by trust, reasons, time per step
#   ./run.sh trace-fsdb <ssh-host> <remote.fsdb> <model.json> <instance> <time>
#                                        driver tracing on a remote FSDB through the helper: every signal
#                                        of <instance> at <time> and two levels of fan-in, with timings
#   ./run.sh sv-model [cmux-sv-model]    driver tracing's design model sidecar: built with its build.sh
#                                        (into ~/.cache/cmux/sv-model-check, once) unless a binary is
#                                        given; its models of the trace fixtures equal trace/models
#   ./run.sh expr                        the debugger's expression evaluator (cmux-expr.js) in JavaScriptCore
#                                        while the debugger's Locals shows,
#                                        refills and removes the same signals
#                                        (helper stand-in, no host)
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
  debugger-editor)
    L="$ROOT/Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient"
    # A sparse worktree may leave the package out (the default cone has no Packages/Shared).
    if [ ! -d "$L" ]; then
      echo "line-breakpoints needs Packages/Shared/CmuxSyntaxHighlighting in this checkout:" >&2
      echo "  git -C \"$ROOT\" sparse-checkout add Packages/Shared/CmuxSyntaxHighlighting" >&2
      exit 2
    fi
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
  expr)
    swiftc -swift-version 6 -O "$HERE/expr/main.swift" -o "$OUT/expr"
    "$OUT/expr" "$ASSETS/cmux-expr.js" "$HERE/expr/cases.js" "$HERE/expr/fuzz-regressions.js"
    ;;
  sv-model)
    BIN="${2:-}"
    if [ -z "$BIN" ]; then
      DEST="$HOME/.cache/cmux/sv-model-check/$(cat "$ASSETS/sv-model/"* | shasum -a 256 | cut -c1-16)"
      [ -x "$DEST/cmux-sv-model" ] || sh "$ASSETS/sv-model/build.sh" "$ASSETS/sv-model" "$DEST"
      BIN="$DEST/cmux-sv-model"
    fi
    bash "$HERE/trace/regen-models.sh" "$BIN" "$OUT/models"
    fails=0
    for f in "$HERE/trace/models/"*.json; do
      if cmp -s "$f" "$OUT/models/$(basename "$f")"; then echo "ok   $(basename "$f")"; else echo "FAIL $(basename "$f") differs"; fails=$((fails + 1)); fi
    done
    # The protocol: ready line, load, lookup, instance, an unknown path, a bad request.
    cd "$HERE/trace/designs"
    printf '%s\n' '{"id":1,"cmd":"load","args":["--top","tb_c","c_struct.sv","tb_c.sv"]}' \
      '{"id":2,"cmd":"lookup","path":"tb_c.dut.u_mid.u_sink.in"}' '{"id":3,"cmd":"instance","path":"tb_c.dut.u_src"}' \
      '{"id":4,"cmd":"instance","path":"tb_c.nope"}' 'not json' '{"id":5,"cmd":"version"}' '{"id":6,"cmd":"instances"}' | "$BIN" > "$OUT/protocol.log"
    check() { if grep -q "$1" "$OUT/protocol.log"; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
    check '^{"id":0,"ready":true' 'ready line'
    check '^{"id":1,"ok":true,"tops":\["tb_c"\],"errors":0' 'load'
    check '^{"id":2,"ok":true,"instance":"tb_c.dut.u_mid.u_sink","name":"in"}' 'lookup'
    check '^{"id":3,"ok":true,"model":{"version":1,"path":"tb_c.dut.u_src","module":"c_src"' 'instance'
    check '^{"id":4,"ok":false,"error":"noInstance"' 'unknown instance'
    check '^{"id":-1,"ok":false,"error":"badRequest"' 'bad request'
    check '^{"id":5,"ok":true,"model":1,"slang":"12.1"}' 'version'
    check '^{"id":6,"ok":true,"tops":\["tb_c"\],"instances":\["tb_c","tb_c.dut","tb_c.dut.u_mid","tb_c.dut.u_mid.u_sink","tb_c.dut.u_src"\]}' 'instances'
    # writers: the instances that write into an interface instance through modport ports.
    printf '%s\n' '{"id":1,"cmd":"load","args":["--top","tb_f","f_bus.sv","tb_f.sv"]}' \
      '{"id":2,"cmd":"writers","path":"tb_f.bus"}' '{"id":3,"cmd":"writers","path":"tb_f.dut"}' '{"id":4,"cmd":"writers","path":"tb_f.nope"}' \
      | "$BIN" > "$OUT/protocol.log"
    check '^{"id":2,"ok":true,"writers":\["tb_f.dut","tb_f.u_mem"\]}' 'writers of an interface instance'
    check '^{"id":3,"ok":true,"writers":\[\]}' 'writers: none'
    check '^{"id":4,"ok":false,"error":"noInstance"' 'writers of an unknown instance'
    [ "$fails" = 0 ] && echo "SV MODEL CHECKS PASSED" || { echo "SV MODEL CHECKS FAILED: $fails"; exit 1; }
    ;;
  trace-ui)
    swiftc -O "$HERE/trace-ui/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/trace-ui"
    "$OUT/trace-ui" "$ASSETS" "$HERE/trace" "$OUT/trace-ui.png" | tee "$OUT/trace-ui.log"
    grep -q '^TRACE UI CHECKS PASSED' "$OUT/trace-ui.log"
    ;;
  trace-fsdb)
    shift
    if [ $# -lt 5 ]; then echo "trace-fsdb: needs <ssh-host> <remote.fsdb> <model.json> <instance> <time>"; exit 2; fi
    # The Verdi engine's client (SVModelSidecar) in one module: only the target enum of its package file.
    L="$ROOT/Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient"
    sed -n '/^public enum SlangCompilationTarget/,/^}/p' "$L/SlangDesignHierarchy.swift" > "$OUT/slang-target.swift"
    swiftc -O "$HERE/trace-fsdb/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" "$L/SVModelSidecar.swift" "$L/VerdiTraceLaunch.swift" \
      "$L/HierarchyPathMapping.swift" "$OUT/slang-target.swift" -o "$OUT/trace-fsdb"
    "$OUT/trace-fsdb" "$ASSETS" "$ASSETS/fsdb-helper" "$@" "$OUT/trace-fsdb.png" | grep -v '^\[log\]' | tee "$OUT/trace-fsdb.log"
    grep -q '^TRACE FSDB CHECKS PASSED' "$OUT/trace-fsdb.log"
    ;;
  trace-smoke)
    mkdir -p "$OUT/smoke/models" "$OUT/smoke/dumps" "$OUT/smoke/designs"
    cp "$2" "$OUT/smoke/models/design.json"
    cp "$3" "$OUT/smoke/dumps/design.vcd"
    cp "$HERE/trace/vcd.js" "$OUT/smoke/vcd.js"
    cp "$HERE/trace/smoke.js" "$OUT/smoke/cases.js"
    swiftc -swift-version 6 -O "$HERE/trace/main.swift" -o "$OUT/trace"
    "$OUT/trace" "$ASSETS/cmux-expr.js" "$ASSETS/cmux-trace.js" "$OUT/smoke"
    ;;
  trace)
    swiftc -swift-version 6 -O "$HERE/trace/main.swift" -o "$OUT/trace"
    "$OUT/trace" "$ASSETS/cmux-expr.js" "$ASSETS/cmux-trace.js" "$HERE/trace"
    ;;
  line-breakpoints)
    L="$ROOT/Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient"
    sed '/^import CmuxSyntaxHighlighting$/d' "$ROOT/Sources/Panels/WaveformDebuggerLineBreakpoints.swift" > "$OUT/line-breakpoints-model.swift"
    swiftc -swift-version 6 -O "$HERE/line-breakpoints/main.swift" "$HERE/line-breakpoints/stubs.swift" "$OUT/line-breakpoints-model.swift" \
      "$L/WaveformLineBreakpoint.swift" "$L/SystemVerilogInlineScan.swift" "$L/HierarchyPathMapping.swift" "$L/LSPTypes.swift" \
      -o "$OUT/line-breakpoints"
    "$OUT/line-breakpoints"
    ;;
  breakpoints)
    swiftc -O "$HERE/breakpoints/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/breakpoints"
    python3 "$HERE/breakpoints/make-vcd.py" "$OUT"
    "$OUT/breakpoints" "$ASSETS" "$OUT/breakpoints.vcd" "$OUT/breakpoints.png" | grep -v '^\[log\]' | tee "$OUT/breakpoints.log"
    grep -q '^BREAKPOINT CHECKS PASSED' "$OUT/breakpoints.log"
    ;;
  fsdb-locals)
    swiftc -O "$HERE/fsdb-locals/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/fsdb-locals"
    "$OUT/fsdb-locals" "$ASSETS" "$OUT/fsdb-locals.png" | grep -v '^\[log\]' | tee "$OUT/fsdb-locals.log"
    grep -q '^FSDB LOCALS CHECKS PASSED' "$OUT/fsdb-locals.log"
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
