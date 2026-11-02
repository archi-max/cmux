# VaporView in cmux

cmux opens waveform dumps (`.vcd`, `.fst`, `.ghw`, `.fsdb`) in [VaporView](https://github.com/Lramseyer/vaporview),
the GPL-3.0 waveform viewer by Lloyd Ramseyer. Upstream VaporView is a VS Code extension. cmux runs it without
VS Code, and adds a link to the SystemVerilog editor, a debugger that steps through the recorded run, and tools for
CPU traces and state machines.

This document covers cmux's changes only. For VaporView itself, see its own README.
[docs/sv-editor.md](../sv-editor.md) gives an overview of the whole `sv-editor` branch.

![The viewer in cmux: netlist, rows with enum names, the marker and the status strip](images/viewer-overview.png)

*The viewer in a cmux panel, on the FSM fixture (`scripts/waveform-viewer-checks/fsm/fsm.vcd`). `state` and
`next_state` show their enum member names.*

## Contents

1. [Background](#background)
2. [Architecture](#architecture)
3. [Features](#features)
4. [Maintaining the patch](#maintaining-the-patch)
5. [Testing](#testing)
6. [Licenses and credits](#licenses-and-credits)
7. [Upstream bugs found](#upstream-bugs-found)

## Background

VaporView has two halves:

- **The webview** (`src/webview/`) draws the waveform: rows, values, the marker, zoom, search. It talks to its host
  only through messages.
- **The extension host** (`src/extension_core/`) runs in VS Code. It parses the dump with
  [wellen](https://github.com/ekiwi/wellen) (compiled to WebAssembly) in a Node worker, reads FSDB through a native
  addon, and provides everything VS Code draws around the webview.

To run the webview without VS Code, cmux had to replace the whole host half:

| VS Code provides | cmux's replacement |
| --- | --- |
| The webview container and `acquireVsCodeApi()` | A `WKWebView` panel, `vscode-api-shim.js`, `vscode-theme.css` |
| File reading (Node `fs`, a worker thread) | `wellen-worker.js` (a Web Worker) that reads the file through HTTP range requests on a private URL scheme |
| FSDB through a native Node addon | A small helper that cmux builds and runs on the remote host, over SSH |
| Context menus, keybindings, settings, the status bar | `cmux-commands.js`, `cmux-ui.js`, generated from VaporView's `package.json` |
| The netlist TreeView | `cmux-netlist.js` |
| Custom-document sessions, undo, dirty state | `cmux-commands.js` and the Swift session code |
| Terminal links | `WaveformTerminalLinks.swift`, since cmux owns the terminal |

On top of that host, cmux adds features VaporView does not have: the editor link, the debugger, machine state,
listings, FSMs and more. They are described under [Features](#features).

## Architecture

```
 cmux (Swift, macOS)                                 WKWebView page  (Resources/vaporview/)
 ────────────────────────────────────                ─────────────────────────────────────────────────────
 FilePreviewWaveformSession.swift  ── callAsyncJS ─▶  index.html
   serves the page and the dump    ◀─ postMessage ──    host.js           extension-host half: backends,
 WaveformViewerSchemeHandler.swift                                        netlist, sessions, link API
   cmux-waveform: URL scheme,      ◀── range GET ───    wellen-worker.js  wellen (filehandler.wasm) in a
   range reads from disk                                                  Web Worker: VCD, FST, GHW
 WaveformDebugger*.swift, Waveform*.swift               cmux-commands.js, cmux-ui.js, cmux-netlist.js
   debugger, breakpoints, machine state,                cmux-debugger*.js, cmux-machine*.js, cmux-fsm.js,
   enum and FSM engines, source link                    cmux-enum.js, cmux-expr.js, cmux-sequence.js, ...
 SystemVerilog editor (FilePreview*.swift)              <iframe id="viewer">  viewer.html + webview.js
   slang-server: types, drivers, hierarchy                VaporView's webview, built from the patch
         │
         │ ssh (stdin/stdout, one per viewer)
         ▼
 remote host: fsdb-helper-v2 (Node + VaporView's FSDB reader addon, built there against the host's Verdi)
```

How the pieces talk:

- **Swift → page:** `callAsyncJavaScript` on `window.cmuxWaveform` (`open`, `reload`, `link.*`, `debugger.*`,
  `machine.*`, `fsm.*`, `enums.*`).
- **Page → Swift:** `webkit.messageHandlers.cmuxWaveform.postMessage({ type, ... })`, for example `opened`,
  `fsmRequest`, `enumTypes`, `loadValueAliases`, `debugger` events.
- **Page → VaporView frame:** the same messages VS Code would send (`add-variable`, `setMarker`, `setDisplayFormat`,
  ...). `host.js` dispatches them on the same-origin frame, so large signals are not copied.
- **Dump bytes:** the page reads the file through `cmux-waveform:` URLs with range requests. Nothing outside the
  bundled folder and the opened file is served. A Content-Security-Policy allows only the bundled scripts.
- **FSDB:** the page `POST`s requests to the served FSDB URL. Swift relays each one as a JSON line to the helper's
  stdin and returns its reply. Replies use fd 3, because the FSDB reader prints to stdout.

## Features

Each section says what the feature does, how to reach it, and which files implement it. Menu names are the English
strings in the code. "View > Waveform Debugger" is a submenu of cmux's View menu, and every item in it is also in
the command palette.

### 1. VaporView parity: menus, keys, netlist, sessions, settings

Everything VaporView offers in VS Code works in the cmux panel, with the same command IDs.

- **Context menus.** Right-click a row, the ruler or the netlist for VaporView's menus and submenus. Their
  `when` clauses are evaluated against the webview's own context, as VS Code does.
- **Keys.** ⌘R shows a row in the netlist, ⌘F searches the netlist, F2 renames, ⌘0 zooms to fit, ⌥= and ⌥- change
  the row scale, G groups the selection, 1 to 8 set a color, ⌘Z and ⇧⌘Z undo and redo.
- **Netlist.** A lazy scope tree with multi-select, add and remove, drag into the viewer and search by instance
  path.
- **Sessions.** Save Vaporview Session... (⌘S) and Load Vaporview Session... read and write VaporView's JSON format.
  A `<dump>.json` next to the dump can load on open (a setting). For a dump on an SSH host, save asks whether to
  write next to it on the host or on this Mac.
- **Settings.** Right-click the ruler > More Settings... opens the `vaporview.*` settings. cmux keeps them across
  launches.
- **Status strip.** Marker time, the delta to the alt marker, and the selected signal.
- **Auto Reload.** The toolbar checkbox reloads the dump when it changes on disk, and keeps the shown rows.

Differences from VS Code, by design:
- A signal that is already shown is not added again, from any entry point. Adding it selects its row.
- Rename (F2) opens the rename box instead of setting the label to the full path.
- There is no WCP server and no remote (surfer) viewer.

<img src="images/context-menu.png" width="440" alt="The row context menu: VaporView's items plus Show State Machine and the debugger's breakpoint items">

*A row's context menu. The items through Reload File are VaporView's. Show State Machine and the items below
Reload File are cmux's.*

| Files | Role |
| --- | --- |
| [`Resources/vaporview/cmux-commands.js`](../../Resources/vaporview/cmux-commands.js) | Command table, menus, keys, settings, sessions, undo, status strip |
| [`Resources/vaporview/cmux-ui.js`](../../Resources/vaporview/cmux-ui.js) | Menu, input box, quick pick, confirm and toast widgets; `when` clauses |
| [`Resources/vaporview/cmux-netlist.js`](../../Resources/vaporview/cmux-netlist.js) | The netlist panel |
| [`Resources/vaporview/host.js`](../../Resources/vaporview/host.js), [`index.html`](../../Resources/vaporview/index.html) | The extension-host half, the page layout |
| [`Resources/vaporview/vscode-api-shim.js`](../../Resources/vaporview/vscode-api-shim.js), [`vscode-theme.css`](../../Resources/vaporview/vscode-theme.css) | `acquireVsCodeApi()` and VS Code's theme variables |
| [`Sources/Panels/FilePreviewWaveformSession.swift`](../../Sources/Panels/FilePreviewWaveformSession.swift) | Hosts the page, settings, session files, key pass-through |
| [`Sources/Panels/WaveformViewerSchemeHandler.swift`](../../Sources/Panels/WaveformViewerSchemeHandler.swift) | The `cmux-waveform:` scheme: the page and range reads of the dump |
| [`Sources/Panels/WaveformViewerStrings.swift`](../../Sources/Panels/WaveformViewerStrings.swift) | The page's strings, localized |

### 2. Terminal links

⌘-click a time (`@ 50000`, `50,000 ns`) in a cmux terminal to move the marker of the last-used viewer. ⌘-click an
instance path (`tb.dut.u_fifo.count`) to add that signal. The matcher is VaporView's `terminal_links.ts` rule,
bounded for very long lines. A path that looks like a file name is left to cmux's file links. A setting turns
instance-path links off.

| Files | Role |
| --- | --- |
| [`Sources/Panels/WaveformTerminalLinks.swift`](../../Sources/Panels/WaveformTerminalLinks.swift) | Routes a clicked link to a viewer |
| [`Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/LinkRouting/WaveformTerminalLink.swift`](../../Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/LinkRouting/WaveformTerminalLink.swift) | The matcher |

### 3. Local and remote dumps, and FSDB

- **VCD, FST, GHW** are parsed in the page by wellen, from a local file or a file in an SSH workspace (cmux's remote
  file preview brings it to the Mac).
- **FSDB** opens from an SSH workspace whose host has Verdi installed. The dump stays on the host. On first use cmux
  uploads `fsdb-helper-v2/`, compiles VaporView's FSDB reader addon there against the host's own Verdi, and caches
  the build under `~/.cache/cmux/` on the host. A local FSDB shows a message, because the FSDB reader does not run on
  macOS.
- **Windowed loading.** With helper v2 the viewer asks for windows of a signal's data as you pan and zoom, instead
  of whole signals. Next and previous edge, value search, values at the marker and WaveDrom export are answered on
  the host. If v2 can't be built or started, cmux falls back to the whole-signal helper (`fsdb-helper/`) and says so
  in the status strip, with a Retry button. The "FSDB signal loading" setting picks Whole signals.

| Files | Role |
| --- | --- |
| [`Resources/vaporview/wellen-worker.js`](../../Resources/vaporview/wellen-worker.js), `filehandler.wasm` | wellen in a Web Worker |
| [`Resources/vaporview/fsdb-helper-v2/`](../../Resources/vaporview/fsdb-helper-v2/) | Windowed helper: a pool of reader processes, windows, edges, search, derived signals |
| [`Resources/vaporview/fsdb-helper/`](../../Resources/vaporview/fsdb-helper/) | Whole-signal helper (fallback) |
| [`Sources/Panels/WaveformFSDBHelper.swift`](../../Sources/Panels/WaveformFSDBHelper.swift) | Installs, starts and relays to the helper; allowlists its commands and file |
| `src/webview/window_cache.ts` in the patch | The viewer side of windowed loading |

### 4. RTL ↔ waveform link and inline values

The SystemVerilog editor and the viewer in the same workspace know about each other.

- **Editor → waveform.** Put the cursor on a signal and press ⌃W (Add Signal to Waveform, also in the editor's
  context menu as Add to Waveform). Add All Signals in Scope to Waveform adds an instance's signals. slang-server
  places the signal in the elaborated design. A signal that is not dumped is shown through the net it connects to,
  when a port connection or an instance-array slice leads to one.
- **Waveform → editor.** Select a row and press ⌥⇧D (Show Waveform Signal in Source), or double-click the row.
  ⌃- and ⌃⇧- go back and forward.
- **Inline values.** The editor shows each signal's value at the marker next to the code. Hover shows the value and,
  for an enum, its member name. Show Waveform Values For picks the instance when a module has several. For FSDB,
  values come only for signals shown in the waveform, unless View > Show FSDB Values for Signals Not in the Waveform
  is on.
- **Path mapping.** When the dump names the design differently (`top_tb.dut` for `cpu`), View > Waveform Path
  Mapping... holds the rules. cmux infers rules it can, and marks them `# inferred`.

| Files | Role |
| --- | --- |
| [`Sources/Panels/WaveformSourceLink.swift`](../../Sources/Panels/WaveformSourceLink.swift) | Both directions, path mapping, Add All Signals in Scope |
| [`Sources/Panels/FilePreviewLanguageFeatures.swift`](../../Sources/Panels/FilePreviewLanguageFeatures.swift), [`FilePreviewInlineValueOverlay.swift`](../../Sources/Panels/FilePreviewInlineValueOverlay.swift) | Editor menu items, inline values and hover |
| [`HierarchyPathMapping.swift`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient/HierarchyPathMapping.swift), [`SystemVerilogInlineScan.swift`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient/SystemVerilogInlineScan.swift) | Path rules; the identifiers on a line and their module |
| `host.js` (`window.cmuxWaveform.link`) | The page API the editor calls: scopes, add, select, marker, values |

### 5. Enum names

A row whose signal has a SystemVerilog enum type shows member names (`DECODE`) instead of bits, by default. VCD
never records enum types, so cmux asks slang-server for the type and hands it to the page. A dump that has its own
enum types (FST, GHW) keeps VaporView's. If you choose another format, cmux keeps your choice. Format Values > Enum
Names gives a row its table back. The overview screenshot at the top shows it.

| Files | Role |
| --- | --- |
| [`Resources/vaporview/cmux-enum.js`](../../Resources/vaporview/cmux-enum.js) | Enum types as value alias tables, default formats |
| [`Sources/Panels/WaveformEnumLink.swift`](../../Sources/Panels/WaveformEnumLink.swift), [`SlangEnumTypes.swift`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient/SlangEnumTypes.swift) | Reads enum types and members from slang-server |

### 6. State machine view

Right-click a state register's row (wider than 1 bit) > Show State Machine. A pane beside the viewer draws its states
and transitions, marks the state at the marker and the transition into it, and counts how often each state is
entered and each transition is taken in the dump. Click a transition to move the marker to its next occurrence
(⇧-click: the previous one), or a state to its next entry. Dashed transitions are ones the dump takes but the model
lacks. Drag the pane's left edge to resize it.

cmux finds the machine with the first engine that works:
1. Verdi's FSM analysis, on a host where the dump and a Verdi install with a licence are;
2. Yosys's FSM passes over the design, when Yosys is found;
3. the dump alone, with state names from slang when it knows them.

A note under the graph says which engine answered.

![The state machine pane: five states, the current one highlighted, counts on states and transitions](images/fsm-view.png)

*The FSM fixture's `state` register. The model is the one the Yosys engine returns for this design, given to the
pane by the screenshot script. The marker is at 50, in DECODE.*

| Files | Role |
| --- | --- |
| [`Resources/vaporview/cmux-fsm.js`](../../Resources/vaporview/cmux-fsm.js) | The pane: layered SVG graph, jumps, counts |
| [`Sources/Panels/WaveformFSMEngines.swift`](../../Sources/Panels/WaveformFSMEngines.swift) | Picks and runs an engine, caches answers |
| [`Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/Fsm/`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/Fsm/), [`SlangFsmContext.swift`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient/SlangFsmContext.swift) | The model, engine output parsing, the order engines run in |
| [`Resources/vaporview/fsm/cmux-fsm-verdi.sh`](../../Resources/vaporview/fsm/cmux-fsm-verdi.sh), [`cmux-fsm-yosys.sh`](../../Resources/vaporview/fsm/cmux-fsm-yosys.sh) | The engine runners |

### 7. RISC-V instructions and value aliases

- **Format Values > RISC-V** shows a 16-bit or wider value as a disassembled instruction (`addi a2,a2,-1755`), in
  four styles: ABI Names, x-Registers, and each without pseudo-instructions. The output matches GNU objdump: the
  tests compare 60,847 encodings in all four styles. It covers RV32I, M, Zicsr, Zifencei, the privileged
  instructions and RV32C. Branch targets show as `pc+N`, since a lone row has no PC.
- **Format Values > Load Value Alias File...** loads a table that names values: Verdi-style `.alias` files, the
  alias lines of `.rc` files, JSON or CSV. The tables then appear under Format Values > Alias. Sessions remember the
  file and read it again.
- Value search on these rows matches the shown text.

<img src="images/riscv-format-menu.png" width="520" alt="Format Values > RISC-V submenu with its four styles">

*Format Values > RISC-V on `scripts/waveform-viewer-checks/riscv/riscv.vcd`. The rows behind the menu show `nop`,
`ret` and `li a0,0`.*

| Files | Role |
| --- | --- |
| `src/webview/riscv_disasm.ts`, `value_alias.ts`, `extra_formats.ts` in the patch | Disassembler, alias parser, the extra formats |
| [`Resources/vaporview/cmux-commands.js`](../../Resources/vaporview/cmux-commands.js) | The RISC-V and Alias submenus |
| [`Sources/Panels/WaveformValueAliasFiles.swift`](../../Sources/Panels/WaveformValueAliasFiles.swift) | Reads alias files (local or on the SSH host), keys them in sessions |
| [`Resources/vaporview/cmux-riscv-disasm.js`](../../Resources/vaporview/cmux-riscv-disasm.js), [`cmux-formats.js`](../../Resources/vaporview/cmux-formats.js) | The same TypeScript, bundled for the machine state and text breakpoints |

### 8. The debugger

The dump is a recorded run, so cmux steps through it the way gdb steps through a program, forwards and backwards.

- **Stepping.** F10 steps one cycle of the clock, ⇧F10 one cycle back. View > Waveform Debugger has Go to First
  Cycle, Go to Last Cycle, Play or Pause Waveform (at a set number of cycles per second), Play Faster and Play
  Slower. cmux picks a clock (`clk`, `clock`, ... near the top). Use Selected Signal as Clock picks another.
- **The status strip** shows the cycle, its time and the play rate, plus an Evaluate field.
- **Locals.** While stepping, a Locals group shows the signals of the instance the editor's cursor is in, and
  follows the cursor.
- **Editor highlights.** Each step tints, in the editor, the signals that changed this cycle and their driver lines.
  It works both ways: rows the editor highlights are highlighted in the viewer too. Play Waits for the Editor keeps
  play in step with these updates.
- **Breakpoints.** F5 continues to the next breakpoint, ⇧F5 to the previous one. F5 with no breakpoint enabled
  plays or pauses. Kinds:
  - on a row: Break When Changes, Break When Equals... (`'h3f`, `8'b1010_??01`, `x`);
  - on an editor line: F9 or a click in the gutter. It stops when a signal assigned on that line changes, in that
    instance;
  - Break When Text Matches... on a row: stops when the row's shown text matches a regular expression
    (`^csrw mtvec` on a RISC-V row). Matching runs in a worker with a time limit, so a bad pattern can't hang the
    viewer;
  - the instruction kinds of [section 10](#10-listings-and-instruction-breakpoints).

  Each breakpoint can have a condition (Edit Condition...). The list sits under the netlist, with a checkbox and a
  remove button for each.
- **Evaluate and watches.** Type a SystemVerilog expression in Evaluate, or use Evaluate Expression... or Add
  Watch.... Operators, widths, signedness and 4-state results follow IEEE 1800-2017, as slang implements them.
  Watches update on every step.

![The debugger stepping a PicoRV32 run: breakpoints, watches, the Machine section and the cycle strip](images/debugger-machine-state.png)

*The PicoRV32 fixture (our test program on the upstream core, `scripts/waveform-viewer-checks/machine/fixtures/`)
at cycle 421. Left: five breakpoints of different kinds, two watches, and the Machine section (section 9). Bottom:
the cycle strip and Evaluate. The `rvfi_insn` row uses the RISC-V format.*

| Files | Role |
| --- | --- |
| [`Resources/vaporview/cmux-debugger.js`](../../Resources/vaporview/cmux-debugger.js) | Page side: clock, steps, play, Locals, breakpoint list and search, watches |
| [`Resources/vaporview/cmux-expr.js`](../../Resources/vaporview/cmux-expr.js) | SystemVerilog expression evaluator (4-state) |
| [`Resources/vaporview/cmux-debugger-text.js`](../../Resources/vaporview/cmux-debugger-text.js), [`cmux-textmatch.js`](../../Resources/vaporview/cmux-textmatch.js), [`cmux-text-worker.js`](../../Resources/vaporview/cmux-text-worker.js) | Text breakpoints |
| [`Sources/Panels/WaveformDebugger.swift`](../../Sources/Panels/WaveformDebugger.swift), [`WaveformDebuggerMenu.swift`](../../Sources/Panels/WaveformDebuggerMenu.swift) | Commands, keys, menu, command palette |
| [`WaveformDebuggerLineBreakpoints.swift`](../../Sources/Panels/WaveformDebuggerLineBreakpoints.swift), [`WaveformDebuggerTextBreakpoints.swift`](../../Sources/Panels/WaveformDebuggerTextBreakpoints.swift), [`WaveformDebuggerEvaluate.swift`](../../Sources/Panels/WaveformDebuggerEvaluate.swift) | Line breakpoints, text breakpoint prompts, Evaluate and conditions |
| [`WaveformDebuggerEditorHighlights.swift`](../../Sources/Panels/WaveformDebuggerEditorHighlights.swift), [`WaveformDebuggerRTLStatus.swift`](../../Sources/Panels/WaveformDebuggerRTLStatus.swift) | Editor highlights, Play Waits for the Editor |
| [`WaveformLineBreakpoint.swift`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient/WaveformLineBreakpoint.swift), [`WaveformCycleHighlights.swift`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient/WaveformCycleHighlights.swift), [`SlangDriverCone.swift`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient/SlangDriverCone.swift), [`WaveformRefreshThrottle.swift`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient/WaveformRefreshThrottle.swift) | Package side: line signals, change highlights, slang drivers, refresh pacing |

### 9. Machine state

For a CPU design that dumps its retired instructions, cmux shows the architectural state at the marker, like gdb's
`info registers` and `x/`. It finds the commit stream by its [RVFI](https://github.com/YosysHQ/riscv-formal/blob/main/docs/rvfi.md)
names (`rvfi_valid`, `rvfi_pc_rdata`, ...) and common variants. If it can't, right-click the signals > Use as Commit.
It then replays every commit into registers and memory.

- **The Machine section** under the netlist has Registers, Memory, CSRs, History and Sequences tabs. Registers
  written by the current instruction show the new value. View > Waveform Debugger > Show or Hide Machine State
  toggles it.
- **Instruction mode.** F10 and ⇧F10 step by commit instead of by cycle. Auto does that while the section has focus.
- **Evaluate** takes `$a0`, `$pc`, `$mem32(addr)` and gdb commands (`info registers`, `p`, `x/4x $sp`).
- **Who wrote this.** A register or memory row's menu has Who Last Wrote This, Go to Previous Write, Go to Next
  Write, and Break When Written.
- **Program image.** Load ELF for Machine State... (or an ELF beside the dump) fills memory the program never wrote,
  and checks loads against it. It needs `readelf` from a RISC-V or LLVM toolchain, or Python's pyelftools.
- **Sequences.** Search the committed instructions with an SVA-like sequence, where one commit is one tick:
  `{lw} as L ##1 rs1 == L.rd || rs2 == L.rd` finds a load followed by an instruction that reads its result. Steps are
  instruction text (`{jal ra}`, `/regex/`) or conditions on decoded fields (`rd`, `rs1`, `imm`, `cls == LOAD`) and
  commit fields (`pc`, `mem_addr`). Delays are `##n`, `##[m:n]` and `##[1:$]`. Click a match to go there.

<img src="images/machine-sequences.png" width="330" alt="The Sequences tab with a load-use query and its matches">

*The Sequences tab on the PicoRV32 fixture: 50 load-use pairs, found in 6 ms.*

| Files | Role |
| --- | --- |
| [`Resources/vaporview/cmux-machine-core.js`](../../Resources/vaporview/cmux-machine-core.js) | Stream detection, replay, state index, gdb commands (no DOM) |
| [`Resources/vaporview/cmux-machine.js`](../../Resources/vaporview/cmux-machine.js) | The Machine section |
| [`Resources/vaporview/cmux-sequence.js`](../../Resources/vaporview/cmux-sequence.js) | Sequence parser and matcher |
| [`Sources/Panels/WaveformMachineState.swift`](../../Sources/Panels/WaveformMachineState.swift), [`WaveformMachineStateLoader.swift`](../../Sources/Panels/WaveformMachineStateLoader.swift) | ELF image and symbols, the section's strings |

### 10. Listings and instruction breakpoints

Open the program's objdump listing (for example `prog.dis`) in the editor next to the viewer. cmux recognizes GNU and
LLVM objdump output and ties it to the dump's commit stream:

- **PC breakpoints.** F9 or a gutter click on an instruction stops where that PC commits. The gutter menu also has
  Run to Next Commit Here, Run to Previous Commit Here, conditions, Enable and Disable.
- **Current instruction.** While stepping, the listing marks the current commit's line with an arrow and a
  highlight. Show Instruction in Listing reveals it.
- **Rebuilt programs.** After a rebuild, breakpoints follow their code by symbol and offset. A breakpoint that moved
  is always reported, never moved silently.
- **More instruction breakpoints** (View > Waveform Debugger > Add Instruction Breakpoint...): Break at Address...,
  Break When Next Instruction Matches... (a regular expression over the disassembly), and Break When Written...
  (`a0`, `mstatus`, `[0x80001000]`).
- **Show Value as Address in Listing** on a row's menu reveals the row's value at the marker as a PC.
- cmux checks that the listing matches the dump, and says so when it doesn't.
- *(coming)* **Sequence breakpoints:** Break When Sequence Matches... stops at a sequence match (section 9).

There is no screenshot of the listing: it lives in the cmux editor, outside the viewer page.

| Files | Role |
| --- | --- |
| [`Sources/Panels/WaveformDebuggerAsmBreakpoints.swift`](../../Sources/Panels/WaveformDebuggerAsmBreakpoints.swift) | Listing detection, gutter, current line, moved marks |
| [`Sources/Panels/WaveformDebuggerCommitBreakpoints.swift`](../../Sources/Panels/WaveformDebuggerCommitBreakpoints.swift), [`Resources/vaporview/cmux-debugger-commits.js`](../../Resources/vaporview/cmux-debugger-commits.js) | Address, instruction-text and write breakpoints |
| [`Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/AsmListing/`](../../Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/AsmListing/) | Listing parser (ported from Compiler Explorer) and marks |

### 11. Trace-X *(coming)*

Not in this branch yet. Trace-X will follow a value, or an X, back through its drivers to the cycle and line where it
came from. It uses Verdi on the remote host when present, and otherwise slang plus cmux's own evaluator.

## Maintaining the patch

All changes to VaporView's own sources are in one file,
[`Resources/vaporview/source/cmux-vaporview.patch`](../../Resources/vaporview/source/cmux-vaporview.patch), against
upstream commit `59107c6` (tag `1.6.1-beta`). It is the GPL corresponding source for the bundled `webview.js`.

- **What's in it.** The changes to `src/webview/` (escaping fixes, windowed loading, RISC-V and alias formats,
  exact value search, the remove-row fix) and VaporView-side tests (`test/riscv/`). The patch's `CHANGES.md`
  describes each change.
- **The `cmux:` convention.** Every edit to an upstream file carries a `// cmux:` comment that says why. New files
  (`window_cache.ts`, `riscv_disasm.ts`, `value_alias.ts`, `extra_formats.ts`) are cmux's own throughout. To list
  the touched upstream lines, search the patch for `cmux:`.
- **Rebuilding byte for byte.** From a clean checkout of `59107c6`, with Rust (`wasm32-unknown-unknown`),
  `wasm-tools` and Node.js:

  ```sh
  git apply <cmux>/Resources/vaporview/source/cmux-vaporview.patch
  npm ci
  npm run compile-wasm
  node esbuild.js --production   # dist/webview.js == Resources/vaporview/webview.js
  ```

  `filehandler.wasm` has its own reproducible build, with wellen's split-bit fix:
  `scripts/waveform-viewer-checks/wellen/build-wasm.sh <VaporView checkout> <work dir>`.
- **Generated files.** `cmux-formats.js` is built by `scripts/waveform-viewer-checks/text/build-formats.mjs`, and
  `cmux-riscv-disasm.js` by esbuild, both from the patched TypeScript. Rebuild them whenever those sources change.
- **Rebasing onto a new upstream.**
  1. In a VaporView checkout, branch from the new upstream tag and apply the patch with `git apply -3`. Resolve
     conflicts hunk by hunk, using the `cmux:` comments.
  2. Run the build above and VaporView's own tests (`node test/riscv/run.cjs`).
  3. Check that the message names in `src/webview/vscode_wrapper.ts` and the exports in
     `src/wellen_parser/filehandler.wit` still match `host.js` and `wellen-worker.js`. Regenerate the menus in
     `cmux-commands.js` from the new `package.json`.
  4. Copy the build outputs (the table in [`Resources/vaporview/README.md`](../../Resources/vaporview/README.md)),
     regenerate the patch with `git diff <new tag> <your branch> -- . ':(exclude)test/riscv/*.gz'`, and update the upstream commit
     in that README and in `THIRD_PARTY_LICENSES.md`.
  5. Run the suites below.

[`Resources/vaporview/README.md`](../../Resources/vaporview/README.md) lists every bundled file, where it came from,
and each local modification in detail.

## Testing

`scripts/waveform-viewer-checks/run.sh <suite>` runs one suite. Page suites load the real bundled page through the
app's own scheme handler in an off-screen, invisible `WKWebView`. Logic suites run the page's scripts in
JavaScriptCore. None of them opens a window. Suites marked *host* need an SSH host with Verdi and a dump, and skip
or stop without one.

| Suite | Covers |
| --- | --- |
| `parity` | Terminal-link matcher, settings, sessions, reloads, undo, the remove-row fix |
| `xss` | Markup in signal names stays inert, the CSP, range and router checks |
| `windowed` | Windowed FSDB with a mock helper through the real `WaveformFSDBHelper`: relay, cancel, fallback |
| `link`, `fsdb-locals` | The editor link API; FSDB inline values of pinned signals |
| `enum`, `enum-link` | Enum names in rows; the app's slang wiring (`WaveformEnumLink.swift`) |
| `fsm` | The state machine pane, through the real menu path |
| `riscv` | Format Values > RISC-V, alias files, sessions with aliases |
| `debugger`, `debugger-editor` | Clock, stepping, play, Locals, highlights; editor highlights on a windowless text view |
| `breakpoints`, `line-breakpoints` | Signal breakpoints, continue and reverse; line breakpoints, gutter, edits |
| `expr` | The expression evaluator (JavaScriptCore), with fuzz regressions |
| `text`, `text-breakpoints` | Text formats and match rules; text breakpoints in the page |
| `commit-breakpoints`, `commit-page`, `asm-listing` | Address, instruction-text and write breakpoints; listing marks |
| `machine-core`, `machine`, `machine-mutants` | Replay rules against Spike on NERV, PicoRV32 and Ibex; the Machine section; mutants of the replay |
| `fsdb`, `debugger-fsdb`, `fsdb-values`, `machine-fsdb`, `windowed-fsdb`, `windowed-launcher` | *host:* the same features on a real remote FSDB, and the helper's build and launcher |

Also: the Swift package tests in `Packages/Shared/CmuxSyntaxHighlighting` (FSM model, listings, line breakpoints,
path mapping, enum types), `WaveformTerminalLinkTests` in `CmuxTerminalCore`, `wellen/check.sh` (the wellen patch,
red unpatched and green patched), and VaporView's `node test/riscv/run.cjs` in a patched checkout.

The screenshots here come from `scripts/waveform-viewer-checks/docs-shots/make-shots.sh`, which uses the same
off-screen page and open fixtures only.

## Licenses and credits

- **VaporView**, by Lloyd Ramseyer (`Lramseyer`) and contributors, GPL-3.0. The bundled webview, the patch, and the
  files adapted from its extension host (`host.js`, `cmux-commands.js`, `cmux-netlist.js`, `cmux-ui.js`,
  `vscode-api-shim.js`, `wellen-worker.js`, the FSDB helpers, `WaveformTerminalLinks.swift`). License:
  [`Resources/vaporview/LICENSE`](../../Resources/vaporview/LICENSE).
- **wellen**, by Kevin Laeufer, BSD-3-Clause, with cmux's patch to its split-bit merge.
- **slang** (MIT): the expression evaluator reimplements its semantics; no slang code is bundled.
  **slang-server** supplies types, drivers and hierarchy at run time.
- **riscv-formal** (ISC): the RVFI signal names and meanings. The machine fixtures simulate NERV, PicoRV32 and Ibex
  unmodified.
- **Compiler Explorer** (BSD-2-Clause): the listing parser is a port of its objdump parser.
- **@vscode/codicons** (CC-BY-4.0 and MIT), **node-addon-api** and **node-api-headers** (MIT).
- **Verdi's FSDB reader is never bundled or redistributed.** The helper links it on the remote host, from that
  host's own install. See [`fsdb-helper-v2/NOTICE`](../../Resources/vaporview/fsdb-helper-v2/NOTICE).

Full texts and versions: [`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md) and
[`Resources/vaporview/README.md`](../../Resources/vaporview/README.md).

## Upstream bugs found

Found while porting, fixed here, and to be reported upstream:

- **VaporView: unescaped HTML.** Waveform data reaches `innerHTML` unescaped: `data-vscode-context` is written
  unquoted (`signal_item.ts`), label tooltips don't escape `"`, the drag tag uses the signal's name as HTML
  (`labels.ts`), and value text from the file is not escaped. A crafted dump could inject markup. The patch escapes
  each once, where the HTML is built.
- **VaporView: Undo with an expanded group throws.** `applyState` passes a group and its children to
  `handleRemoveVariable` (`row_handler.ts`), and the second `dispose()` throws. It affects Undo, Redo and session
  loads. The patch skips a row already queued.
- **VaporView: numeric value search matches substrings.** The search is an unanchored regular expression over the
  value's bits, so hex `5` also finds `0x15`. The patch anchors it to the whole value, with zero or sign extension.
  Wildcards and explicit regexes still work.
- **wellen 0.25.7: split-bit vectors.** Merging a VCD's bit-blasted vector (`valid [0]`, `valid [1]`) in
  `transform_bv_signal` had four mistakes. Bits started at the wrong value, a bit whose first change came late lost
  its values, an X before a bit's first value became 0, and a never-written bit emptied the whole vector.
  `wellen-0.25.7-split-bit-start.patch` fixes all four.
