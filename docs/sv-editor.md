# sv-editor: SystemVerilog editing and waveform debugging in cmux

This branch of cmux, `sv-editor` on `archi-max/cmux`, adds a hardware-design workflow to the terminal:
- a SystemVerilog editor;
- a waveform viewer built on VaporView;
- a debugger that steps through a recorded simulation.

It is aimed at remote work: the design, the simulator and the dumps live on a Linux host reached over SSH, and the Mac runs the UI.

To see everything this branch adds on top of cmux, use the GitHub compare view `main...sv-editor`. The `.github/workflows` part of that diff is mostly upstream workflows this fork removes. The fork's own CI is `build-fork-app.yml`.

## What it does

- **SystemVerilog editor.** Syntax highlighting, plus language features from [slang-server](https://github.com/hudson-trading/slang-server): diagnostics, go-to-definition and hierarchy. Profiles and top-level selection are also supported.
- **Remote workspaces.** Over SSH you can open, search and go to files on the remote host. Terminal links (`path:line`) open in the editor.
- **Waveform viewer.** VaporView's viewer runs inside cmux without VS Code. It reads VCD, FST and GHW, and also FSDB when Verdi is installed on the remote host (see below). It includes VaporView's menus, keybindings, netlist view, sessions and settings.
- **RTL ↔ waveform link.** You can jump from a signal to its source and from source to its waveform, and see values inline in the editor at the cursor time.
- **Debugger.** It steps through a recorded simulation the way gdb steps through a program:
  - line, value and expression breakpoints;
  - continue/step forward and backward;
  - an evaluate expression.
- **CPU traces.** For designs that log instruction commits:
  - registers and memory at any point in time (machine state);
  - PC/address breakpoints on an assembly listing;
  - instruction text and sequence breakpoints;
  - a RISC-V disassembler.
- **FSMs.** It shows enum and state names, and an FSM view that builds the state graph from the design.
- **Trace-X.** It traces where a signal's value comes from, back through its drivers.

## Where the code lives

### cmux / macOS side (Swift)

| Area | Path |
| --- | --- |
| Editor (text view, gutter, inline values, modes) | `Sources/Panels/FilePreview*.swift` |
| SystemVerilog highlighting | `Packages/Shared/CmuxSyntaxHighlighting/` |
| slang-server integration | `Sources/Panels/Slang*.swift` |
| Remote workspaces: file open, preview cache, search, go-to-file, terminal links | `Sources/Remote*.swift`, `Sources/SSHFile*.swift`, `Sources/GoToFile*.swift`, `Sources/Workspace+TerminalLinkOpening.swift`, `Packages/macOS/CmuxRemoteWorkspace/`, `daemon/remote/` |
| Native side of the waveform features: hosting the viewer, debugger, breakpoints, machine state, FSM engines, source link, FSDB helper launcher | `Sources/Panels/Waveform*.swift` |

### VaporView side (web, inside the viewer)

| Area | Path |
| --- | --- |
| cmux's changes to upstream VaporView, as one patch (the GPL corresponding source for `webview.js`) | `Resources/vaporview/source/cmux-vaporview.patch` |
| Viewer page, host bridge, VS Code API shim, wellen parser (`filehandler.wasm`) | `Resources/vaporview/` (`index.html`, `host.js`, `vscode-api-shim.js`) |
| cmux add-ons that run in the page: debugger, machine state, FSM, enums, expressions, RISC-V disassembler, sequence search | `Resources/vaporview/cmux-*.js` |
| How each bundled file was built, and the modifications | `Resources/vaporview/README.md` |

For a feature-by-feature guide to cmux's VaporView changes, with screenshots and the files involved, see
[docs/vaporview/README.md](vaporview/README.md).

### FSDB on a remote host

FSDB is read on the remote host by `Resources/vaporview/fsdb-helper-v2/`. This is a small Node helper with VaporView's FSDB reader addon, compiled on the host against that host's own Verdi install. cmux uploads it over SSH and streams only the windows of data the viewer needs. Synopsys libraries are never bundled or redistributed. See `fsdb-helper-v2/NOTICE`.

### Tests

`scripts/waveform-viewer-checks/` contains headless harnesses for each area. `run.sh <suite>` runs one suite, for example `windowed`, `debugger`, `breakpoints`, `machine`, `fsm`, `riscv`, `xss` or `parity`.

## Credits and licenses

- [VaporView](https://github.com/Lramseyer/vaporview), by Lloyd Ramseyer and contributors, GPL-3.0. Its sources are changed here only through the patch above.
- [wellen](https://github.com/ekiwi/wellen), by Kevin Laeufer, BSD-3-Clause.
- [slang-server](https://github.com/hudson-trading/slang-server).
- Everything else is listed in `THIRD_PARTY_LICENSES.md` and `Resources/vaporview/README.md`.
