# Waveform viewer (VaporView)

The waveform viewer that cmux opens for `.vcd`, `.fst` and `.ghw` files is
VaporView's webview, built from source and hosted in a WKWebView without VS Code.

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
| `webview.js` | `dist/webview.js` (unmodified build output of `src/webview/`) |
| `filehandler.wasm` | `target/wasm32-unknown-unknown/release/filehandler.wasm` (unmodified build output of `src/wellen_parser/`, wellen 0.25.7) |
| `style.css` | `media/style.css` (unmodified) |
| `codicons/codicon.css`, `codicons/codicon.ttf` | `node_modules/@vscode/codicons/dist/` 0.0.35 (unmodified; `codicons/LICENSE` CC-BY-4.0, `codicons/LICENSE-CODE` MIT) |
| `viewer.html` | `media/webview.html`, modified (see below) |

The bundled npm and Rust dependencies, with their licenses, are listed under
"Waveform Viewer Assets" in the repository's `THIRD_PARTY_LICENSES.md`.

## Local modifications

- `viewer.html`: the `${webAssets.*}` template placeholders are replaced with
  relative paths, the unused `icons.svg` link is removed, `vscode-theme.css`
  and `vscode-api-shim.js` are loaded in `<head>`, a header comment is added,
  and line endings are LF.
- `vscode-api-shim.js` (new, adapted from `src/webview/vscode_wrapper.ts`):
  provides `acquireVsCodeApi()` and forwards the webview's messages to the
  host page instead of VS Code.
- `wellen-worker.js` (new, adapted from `src/extension_core/worker.ts` and
  `src/extension_core/wasm_handler.ts`): runs `filehandler.wasm` in a Web
  Worker with hand-written canonical-ABI glue in place of
  `@vscode/wasm-component-model`, and reads the file through synchronous
  `Range` requests instead of Node's `fs`.
- `host.js` and `index.html` (new, adapted from
  `src/extension_core/document.ts` and `src/extension_core/viewer_provider.ts`):
  the extension-host side reduced to opening one file, answering the webview's
  `ready` / `initialized` / `fetchDataFromFile` / `copyToClipboard` messages,
  and a simple netlist tree in place of VS Code's TreeView.
- `vscode-theme.css` (new): the `--vscode-*` theme variables VS Code injects
  into webviews, with dark and light values; cmux overrides the background and
  foreground with the panel's colors.

The Swift side (`Sources/Panels/FilePreviewWaveformSession.swift`,
`Sources/Panels/WaveformViewerSchemeHandler.swift`) serves this folder and the
opened file over the `cmux-waveform:` URL scheme.

## Updating

Rebuild at the new upstream commit with the commands above, copy the files in
the table, re-apply the `viewer.html` changes, check that the message names in
`src/webview/vscode_wrapper.ts` and the exports in
`src/wellen_parser/filehandler.wit` still match `host.js` and
`wellen-worker.js`, and update the commit here and in `THIRD_PARTY_LICENSES.md`.
