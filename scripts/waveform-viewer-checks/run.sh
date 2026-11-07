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
#   ./run.sh fsm                         the state machine view (cmux-fsm.js): the
#                                        graph, the state at the marker, jumps to
#                                        a transition's next occurrence, counts
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
#   ./run.sh machine-core                machine state (cmux-machine-core.js): commit stream detection,
#                                        the replay rules, gdb commands, $ names; the synthetic RVFI
#                                        generator and NERV/PicoRV32/Ibex against Spike (machine/fixtures)
#   ./run.sh machine [case...]           the machine state in the page (cmux-machine.js): the Machine section,
#                                        F10 by commit, $ names, gdb commands, row actions, the ELF image
#                                        (WaveformMachineState.swift's readelf) on the cores and synthetic streams
#   ./run.sh machine-fsdb <ssh-host> <remote.fsdb> <commit.log> [prog.elf]
#                                        the machine state on a remote FSDB against its commit.log
#   ./run.sh machine-mutants             mutants of the replay rules (machine/mutants.js) each fail machine-core
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
#   ./run.sh debugger-invoke             debugger commands from keys, menu, palette with a
#                                        viewer field focused; the no-viewer notice
#   ./run.sh expr                        the debugger's expression evaluator (cmux-expr.js) in JavaScriptCore
#   ./run.sh text                        text breakpoints' formats and match rules (cmux-textmatch.js) in JavaScriptCore
#   ./run.sh text-breakpoints            text breakpoints in the page: hits, menus, conditions, caps, watchdog
#   ./run.sh commit-breakpoints          pc, instruction-text, write and sequence breakpoints (cmux-debugger-commits.js) in JavaScriptCore
#   ./run.sh commit-page                 those in the page, over a mock commit index: hits, menus, prompts, session, caps
#   ./run.sh asm-listing                 listing breakpoints: gutter, F9, marks that follow their code, current commit, match check
#                                        while the debugger's Locals shows,
#                                        refills and removes the same signals
#                                        (helper stand-in, no host)
#   ./run.sh sim-unit                    live simulation's host side (fsdb-helper-v2/sim.js): novas_dump.log
#                                        run arguments, the stub check, open/watch/run/until/stop/poll/read/
#                                        close against a stand-in worker (no simulator)
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
#   ./run.sh riscv                       Format Values > RISC-V (16 bits and wider)
#                                        and the value-alias items from the context
#                                        menu: decoded text, selection, undo, session
#                                        save/load, reload, restore
#   ./run.sh split                       Split (Into N Parts, By Width, Bits, Add Slice, Declared Dimensions)
#                                        from the row menu: slices under their parent,
#                                        names, values, own formats, marker, search,
#                                        copy, nesting, collapse, undo, removal, and
#                                        session save/load, reload, restore
#   ./run.sh fsdb-array                  the FSDB helper nests the reader's arrays (a stand-in addon, no FSDB)
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
  fsm)
    swiftc -O "$HERE/fsm/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/fsm"
    "$OUT/fsm" "$ASSETS" "$HERE/fsm/fsm.vcd" "$OUT/fsm.png" | tee "$OUT/fsm.log"
    grep -q '^FSM CHECKS PASSED' "$OUT/fsm.log"
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
  machine-core)
    swiftc -swift-version 6 -O "$HERE/machine/main.swift" -o "$OUT/machine-core"
    "$OUT/machine-core" "$HERE/machine/fixtures" "$ASSETS/cmux-expr.js" "$ASSETS/cmux-machine-core.js" \
      "$ASSETS/cmux-riscv-disasm.js" "$ASSETS/cmux-sequence.js" "$HERE/machine/make-rvfi-vcd.js" "$HERE/machine/core-cases.js" \
      "$HERE/machine/sequence-cases.js" | tee "$OUT/machine-core.log"
    grep -q '^MACHINE CORE CHECKS PASSED' "$OUT/machine-core.log"
    ;;
  machine)
    # The page: each dump in its own off-screen WKWebView (cases: the three cores, six synthetic streams, none).
    shift
    swiftc -O "$HERE/machine/page/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" "$ROOT/Sources/Panels/WaveformMachineState.swift" -o "$OUT/machine-page"
    cases="${*:-nerv picorv32 ibex prefixed packed2 array2 array2late array2single struct monitor forward none}"
    for c in $cases; do
      "$OUT/machine-page" "$ASSETS" "$HERE/machine" "$OUT" "$c" | tee "$OUT/machine-$c.log"
      grep -q '^MACHINE PAGE CHECKS PASSED' "$OUT/machine-$c.log"
    done
    ;;
  machine-fsdb)
    # A remote FSDB read in place (helper under nice) against its Spike-format commit.log (a local copy).
    shift
    if [ $# -lt 3 ]; then echo "machine-fsdb: needs <ssh-host> <remote.fsdb> <local commit.log> [local.elf]"; exit 2; fi
    swiftc -O "$HERE/machine/page/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" "$ROOT/Sources/Panels/WaveformMachineState.swift" -o "$OUT/machine-page"
    # Exit 75: the dump never opened (a stuck connection); one retry with a fresh helper. Each attempt
    # keeps its own log (machine-fsdb.attemptN.log); machine-fsdb.log is the last one.
    rm -f "$OUT"/machine-fsdb.attempt*.log
    for attempt in 1 2; do
      set +e; "$OUT/machine-page" "$ASSETS" "$HERE/machine" "$OUT" fsdb "$ASSETS/fsdb-helper" "$@" | tee "$OUT/machine-fsdb.attempt$attempt.log"; status=${PIPESTATUS[0]}; set -e
      cp "$OUT/machine-fsdb.attempt$attempt.log" "$OUT/machine-fsdb.log"
      [ "$status" -eq 75 ] && [ "$attempt" -eq 1 ] && { echo "machine-fsdb: retrying once (attempt 1's log: $OUT/machine-fsdb.attempt1.log)"; continue; }
      break
    done
    grep -q '^MACHINE PAGE CHECKS PASSED' "$OUT/machine-fsdb.log"
    ;;
  machine-mutants)
    swiftc -swift-version 6 -O "$HERE/machine/main.swift" -o "$OUT/machine-core"
    "$HERE/machine/mutants.sh" "$OUT/machine-core" "$ASSETS" "$HERE/machine" "$OUT" | tee "$OUT/mutants.log"
    grep -q '0 survived' "$OUT/mutants.log"
    ;;
  expr)
    swiftc -swift-version 6 -O "$HERE/expr/main.swift" -o "$OUT/expr"
    "$OUT/expr" "$ASSETS/cmux-expr.js" "$HERE/expr/cases.js" "$HERE/expr/fuzz-regressions.js"
    ;;
  text)
    swiftc -swift-version 6 -O "$HERE/text/main.swift" -o "$OUT/text"
    "$OUT/text" "$ASSETS/cmux-formats.js" "$ASSETS/cmux-textmatch.js" "$HERE/text/cases.js"
    ;;
  commit-breakpoints)
    swiftc -swift-version 6 -O "$HERE/commit-breakpoints/main.swift" -o "$OUT/commit-breakpoints"
    "$OUT/commit-breakpoints" "$ASSETS/cmux-formats.js" "$ASSETS/cmux-textmatch.js" "$ASSETS/cmux-debugger-text.js" \
      "$ASSETS/cmux-debugger-commits.js" "$ASSETS/cmux-expr.js" "$ASSETS/cmux-sequence.js" "$HERE/commit-breakpoints/cases.js"
    ;;
  asm-listing)
    A="$ROOT/Packages/Shared/CmuxSyntaxHighlighting"
    sed '/^import CmuxSyntaxHighlighting$/d' "$ROOT/Sources/Panels/WaveformDebuggerAsmBreakpoints.swift" > "$OUT/asm-listing-model.swift"
    swiftc -swift-version 6 -O "$HERE/asm-listing/main.swift" "$HERE/asm-listing/stubs.swift" "$OUT/asm-listing-model.swift" \
      "$A"/Sources/CmuxSyntaxHighlighting/AsmListing/*.swift -o "$OUT/asm-listing"
    "$OUT/asm-listing" "$A/Tests/Fixtures/AsmListing/gnu-rv32-code.dis"
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
    "$OUT/trace-fsdb" "$ASSETS" "$ASSETS/fsdb-helper" "$@" "$OUT/trace-fsdb.png" | grep --line-buffered -v '^\[log\]' | tee "$OUT/trace-fsdb.log"
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
  debugger-invoke)
    swiftc -swift-version 6 -O "$HERE/debugger-invoke/main.swift" "$ROOT/Sources/Panels/WaveformDebuggerInvocation.swift" -o "$OUT/debugger-invoke"
    "$OUT/debugger-invoke"
    ;;
  line-breakpoints)
    L="$ROOT/Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient"
    sed '/^import CmuxSyntaxHighlighting$/d' "$ROOT/Sources/Panels/WaveformDebuggerLineBreakpoints.swift" > "$OUT/line-breakpoints-model.swift"
    swiftc -swift-version 6 -O "$HERE/line-breakpoints/main.swift" "$HERE/line-breakpoints/stubs.swift" "$OUT/line-breakpoints-model.swift" \
      "$ROOT/Sources/Panels/WaveformDebuggerTextBreakpoints.swift" "$ROOT/Sources/Panels/WaveformDebuggerCommitBreakpoints.swift" \
      "$L/WaveformLineBreakpoint.swift" "$L/SystemVerilogInlineScan.swift" "$L/HierarchyPathMapping.swift" "$L/LSPTypes.swift" \
      "$ROOT"/Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/AsmListing/*.swift \
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
  text-breakpoints)
    swiftc -O "$HERE/text-breakpoints/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/text-breakpoints"
    python3 "$HERE/text-breakpoints/make-vcd.py" "$OUT"
    "$OUT/text-breakpoints" "$ASSETS" "$OUT/text-breakpoints.vcd" "$OUT/text-breakpoints.png" | grep -v '^\[log\]' | tee "$OUT/text-breakpoints.log"
    grep -q '^TEXT BREAKPOINT CHECKS PASSED' "$OUT/text-breakpoints.log"
    ;;
  commit-page)
    swiftc -O "$HERE/commit-page/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/commit-page"
    python3 "$HERE/commit-page/make-vcd.py" "$OUT"
    "$OUT/commit-page" "$ASSETS" "$OUT/commit-page.vcd" "$OUT/text-breakpoints.vcd" "$OUT/commit-page.png" | grep -v '^\[log\]' | tee "$OUT/commit-page.log"
    grep -q '^COMMIT PAGE CHECKS PASSED' "$OUT/commit-page.log"
    ;;
  fsdb-locals)
    swiftc -O "$HERE/fsdb-locals/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/fsdb-locals"
    "$OUT/fsdb-locals" "$ASSETS" "$OUT/fsdb-locals.png" | grep -v '^\[log\]' | tee "$OUT/fsdb-locals.log"
    grep -q '^FSDB LOCALS CHECKS PASSED' "$OUT/fsdb-locals.log"
    ;;
  sim-unit)
    command -v node >/dev/null || { echo "sim-unit: needs node"; exit 2; }
    node "$HERE/sim/sim-unit.cjs" "$ASSETS/fsdb-helper-v2" "$OUT" | tee "$OUT/sim-unit.log"
    grep -q '^SIM UNIT CHECKS PASSED' "$OUT/sim-unit.log"
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
  sim)
    command -v node >/dev/null || { echo "sim: needs node"; exit 2; }
    # Red until Sources/Panels/WaveformSimRelay.swift exists (the harness names WaveformSimRelay).
    swiftc -swift-version 6 -typecheck "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      $(ls "$ROOT/Sources/Panels/WaveformSimRelay.swift" 2>/dev/null)
    swiftc -O "$HERE/sim/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" $(ls "$ROOT/Sources/Panels/WaveformSimRelay.swift" 2>/dev/null) -o "$OUT/sim"
    "$OUT/sim" "$ASSETS" "$ASSETS/fsdb-helper-v2" "$ASSETS/fsdb-helper" "$HERE/sim/mock-helper-sim.cjs" \
      "$HERE/windowed/mock-helper-v2.cjs" "$HERE/sim/fake-worker.cjs" "$HERE/sim/fixture" "$OUT/sim-scratch" \
      | grep -v '^\[log\]' | tee "$OUT/sim.log"
    grep -q '^SIM CHECKS PASSED' "$OUT/sim.log"
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
  riscv)
    swiftc -O "$HERE/riscv/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" "$ROOT/Sources/Panels/WaveformViewerStrings.swift" \
      "$ROOT/Sources/Panels/WaveformValueAliasFiles.swift" -o "$OUT/riscv"
    "$OUT/riscv" "$ASSETS" "$HERE/riscv/riscv.vcd" "$HERE/riscv/aliases.alias" "$OUT/riscv.png" | grep -v '^\[log\]' | tee "$OUT/riscv.log"
    grep -q '^RISCV CHECKS PASSED' "$OUT/riscv.log"
    ;;
  fsdb-array)
    # fsdb-helper-v2's tree.js against the reader's callbacks for a dump with packed arrays (no FSDB needed).
    node "$HERE/fsdb-array/check.js" "$ASSETS/fsdb-helper-v2" | tee "$OUT/fsdb-array.log"
    grep -q '^FSDB ARRAY CHECKS PASSED' "$OUT/fsdb-array.log"
    ;;
  split)
    swiftc -O "$HERE/split/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
      "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" "$ROOT/Sources/Panels/WaveformViewerStrings.swift" -o "$OUT/split"
    "$OUT/split" "$ASSETS" "$HERE/split/split.vcd" "$OUT/split.png" | grep -v '^\[log\]' | tee "$OUT/split.log"
    grep -q '^SPLIT CHECKS PASSED' "$OUT/split.log"
    ;;
  *) sed -n "2,$(( $(grep -n '^set -euo' "$0" | cut -d: -f1) - 1 ))p" "$0"; exit 2 ;;
esac
