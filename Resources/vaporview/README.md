# Waveform viewer (VaporView)

The waveform viewer that cmux opens for `.vcd`, `.fst`, `.ghw` and `.fsdb`
files is VaporView's webview, built from source and hosted in a WKWebView
without VS Code.

- Upstream: https://github.com/Lramseyer/vaporview
- Commit: `59107c60c9ee5eefa95750b95369753736b77ca4` (tag `1.6.1-beta`)
- License: GNU General Public License v3.0 (`LICENSE`, copied from upstream)
- Author: Lloyd Ramseyer (GitHub `Lramseyer`) and the VaporView contributors

## How these files were built

From a clean checkout of the commit above, with Rust (`wasm32-unknown-unknown`),
`wasm-tools` and Node.js:

```sh
npm ci
npm run compile-wasm          # wit2ts bindings + cargo build --release for wasm32
node esbuild.js --production  # minified dist/webview.js
```

| File | Source |
| --- | --- |
| `webview.js` | `dist/webview.js` (build output of `src/webview/`, patched; see below) |
| `filehandler.wasm` | `target/wasm32-unknown-unknown/release/filehandler.wasm` (unmodified build output of `src/wellen_parser/`, wellen 0.25.7) |
| `style.css` | `media/style.css` (unmodified) |
| `codicons/codicon.css`, `codicons/codicon.ttf` | `node_modules/@vscode/codicons/dist/` 0.0.35 (unmodified; `codicons/LICENSE` CC-BY-4.0, `codicons/LICENSE-CODE` MIT) |
| `viewer.html` | `media/webview.html`, modified (see below) |

The bundled npm and Rust dependencies, with their licenses, are listed under
"Waveform Viewer Assets" in the repository's `THIRD_PARTY_LICENSES.md`.

## Local modifications

Made by cmux on 2026-10-30 (viewer, host, FSDB helper) and 2026-10-31
(escaping, Content-Security-Policy, FSDB helper hardening).

- `webview.js`: waveform data reaches `innerHTML` unescaped in four places in
  upstream `src/webview/` (an upstream bug, to be reported): the
  `data-vscode-context` attribute is written unquoted (`signal_item.ts`, all
  `createLabelElement`/`createValueDisplayElement` methods), the label
  tooltip of `createLabelElement` at line 524 escapes `<>` but not `"`, the
  drag tag sets `innerHTML` to the dragged signal's name (`labels.ts:333`),
  and value display text, which the String format takes from the file, is
  not escaped (`signal_item.ts:304-311`, `:548`). The minified build is
  patched textually at those sites to quote and escape through
  `cmuxEscapeAttribute`, `cmuxEscapeQuotes` and `cmuxEscapeHtml` (defined in
  `vscode-api-shim.js`), and to set the drag tag's `textContent`. To redo the
  patch after a rebuild, replace `data-vscode-context=${this.vscodeContext}`,
  `title="${x}"`, ``dragCursorTag.innerHTML=`${this.dragCursorText}` `` and
  `<p style="color:${c}">${v}</p>` accordingly, then run
  `scripts/waveform-viewer-checks/run.sh xss`.
- `index.html`, `viewer.html`: a Content-Security-Policy `<meta>` tag (the
  scheme handler also sends it as a header): only bundled scripts, styles,
  fonts and the wasm, no inline script, no other origin.

- `viewer.html`: the `${webAssets.*}` template placeholders are replaced with
  relative paths, the unused `icons.svg` link is removed, `vscode-theme.css`
  and `vscode-api-shim.js` are loaded in `<head>`, a header comment is added,
  and line endings are LF.
- `vscode-api-shim.js` (new, adapted from `src/webview/vscode_wrapper.ts`):
  provides `acquireVsCodeApi()` and forwards the webview's messages to the
  host page instead of VS Code, and defines the escaping helpers above.
- `wellen-worker.js` (new, adapted from `src/extension_core/worker.ts` and
  `src/extension_core/wasm_handler.ts`): runs `filehandler.wasm` in a Web
  Worker with hand-written canonical-ABI glue in place of
  `@vscode/wasm-component-model`, and reads the file through synchronous
  `Range` requests instead of Node's `fs`.
- `host.js` and `index.html` (new, adapted from
  `src/extension_core/document.ts` and `src/extension_core/viewer_provider.ts`):
  the extension-host side reduced to opening one file, answering the webview's
  `ready` / `initialized` / `fetchDataFromFile` / `copyToClipboard` messages,
  recording `contextUpdate` and `executeCommand setContext` state, and a simple
  netlist tree in place of VS Code's TreeView. VaporView's VS Code context
  menus and keybindings (contributed in its `package.json`) are not
  reimplemented yet.
- `host.js` also reads FSDB files through cmux's FSDB helper (below) and
  delivers every signal's value changes through one function that dispatches
  the message event on the same-origin viewer frame instead of posting it, so
  large signals are not structured-cloned. FSDB value changes arrive as
  packed records and are decoded with one shared string per distinct value.
- `fsdb-helper/` (new): what cmux uploads to an SSH host to read FSDB there.
  `fsdb-helper.js` is adapted from `src/extension_core/fsdb_worker.ts`: the
  same addon calls, served over the ssh stdio channel (newline-delimited JSON
  requests; replies on fd 3, because Verdi's reader prints to stdout) instead
  of Node IPC, with the scope/variable walk done in the helper and signal data
  sent as deflated `[u64 delta time][value chars]` records. `fsdb_reader.cpp`
  is upstream `src/fsdb_reader.cpp`, unmodified; `packed.cpp.inc` adds
  `getValueChangesPacked`, which returns a signal's value changes as one
  packed buffer, and `build.sh` splices it in before `Init()` and compiles
  the addon on the host with `g++` against that host's Verdi (in place of
  `binding.gyp`/node-gyp, without `-static-libstdc++`). `fsdb-helper.sh`
  starts it in a private run directory, and exits 87 so cmux rebuilds when
  the Node.js or Verdi it was built for is gone. `getValueChangesPacked`
  also returns the signal's bit size, throws for an unknown signal or no
  open file (where upstream's calls would dereference null), and hands its
  buffer to Node without a copy. `third_party/` holds the node-addon-api 8.6.0 and
  node-api-headers 1.9.0 headers (MIT) the build needs.
- `vscode-theme.css` (new): the `--vscode-*` theme variables VS Code injects
  into webviews, with dark and light values; cmux overrides the background and
  foreground with the panel's colors.

The Swift side (`Sources/Panels/FilePreviewWaveformSession.swift`,
`Sources/Panels/WaveformViewerSchemeHandler.swift`) serves this folder and the
opened file over the `cmux-waveform:` URL scheme, and
`Sources/Panels/WaveformFSDBHelper.swift` installs and runs the FSDB helper on
an SSH workspace's host and relays the page's FSDB requests to it.

## Updating

Rebuild at the new upstream commit with the commands above, copy the files in
the table, re-apply the `viewer.html` changes, check that the message names in
`src/webview/vscode_wrapper.ts` and the exports in
`src/wellen_parser/filehandler.wit` still match `host.js` and
`wellen-worker.js`, and update the commit here and in `THIRD_PARTY_LICENSES.md`.
