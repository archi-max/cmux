# Third-Party Licenses

cmux includes the following third-party software:

---

## Lobe Icons (selected agent marks)

- **License:** MIT License
- **Copyright:** Copyright (c) 2023 LobeHub
- **Source:** https://github.com/lobehub/lobe-icons/tree/a94750e3f5f8fc33757b839d85030e742284e43a/packages/static-svg/icons

Selected Cursor, Gemini, Kiro, GitHub Copilot, CodeBuddy, Qoder, Kimi, and
Ollama SVG marks are bundled under `Assets.xcassets/AgentIcons`. The complete
license text is in `Assets.xcassets/AgentIcons/LOBE-LICENSE.txt`.

---

## Primer Octicons (selected diff viewer icons)

- **License:** MIT License
- **Copyright:** Copyright (c) 2026 GitHub Inc.
- **Source:** https://github.com/primer/octicons (v19.38.0)

Selected 16px path data is embedded in `webviews/src/icons.tsx`.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Ghostty

- **License:** MIT License
- **Copyright:** Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
- **Source:** https://github.com/ghostty-org/ghostty

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Bonsplit

- **License:** MIT License
- **Copyright:** Copyright (c) 2026 Alasdair Monk
- **Source:** https://github.com/almonk/bonsplit

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## cmux-cua engine

- **License:** MIT License
- **Copyright:** Copyright (c) 2025 Cua AI, Inc.
- **Source:** https://github.com/manaflow-ai/cmux-cua

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## herdr agent-detection plugin

cmux includes a userland agent-detection plugin derived from herdr. Its
manifests and adapted detector sources live under
`cmux-tui/bindings/examples/rust-agent-screen-detection/`.

- **Package license:** MIT AND Apache-2.0
- **Herdr-derived material:** Apache License 2.0
- **Source:** https://github.com/herdrdev/herdr
- **Detector source reference:** commit `7b675f42af35508eab66ac42fe1598628597a893`
- **Pi bundled-launcher correction:** commit `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`
- **Manifest snapshot:** commit `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
- **Included manifest fixes:** Claude MCP elicitation `f807b697353cfa00aa912c7cde4830e863001cf5`, Claude background-shell state `987b070fbfa187e85009b45cd7e208fc6175ff6a`, Codex weak-blocker scope `f457cff4f2648eee85d176f8a41861241d4e8428`, and Copilot background-agent activity `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
- **License text:** cmux-owned code is covered by
  `cmux-tui/bindings/examples/rust-agent-screen-detection/LICENSE-MIT`; the
  herdr-derived files use
  `cmux-tui/bindings/examples/rust-agent-screen-detection/manifests/LICENSE`
- **Latest agent-surface capability audit:** commit `987b070fbfa187e85009b45cd7e208fc6175ff6a`. The herdr repository tip checked on 2026-09-02 is `94f6d9c0d9bb9cf9ffae99d8bbfb09e9bf2fc9e0`; commits after the audit pin change client rendering, terminal reads, graphics ownership, Windows input and worktree handling, or sidebar focus, with no further `src/detect` or manifest changes. The audit includes the exact Pi bundled CLI path correction from `b1ff4582e9688f52ffb943cfa8bee4871ae122e4` and the Claude background-shell state correction from `987b070fbfa187e85009b45cd7e208fc6175ff6a`, both adapted and tested in the userland package. The first-acquisition OSC retention fix from `82e6a80eb3ae39fb3d3ebd4d1fed19389767e605` is adapted in the userland tracker. The foreground group-leader CWD fix from `3a3792622e59c7f2dc20f9c0236167161e4a5035` is already covered by cmux's generic `foreground_cwd` resource. The shell-render refactor in `207be3c771d281baae6e5fa0fb74be9a056e97a2` and independent multi-client tab views in `6c0bb273d5d5405a00985621b17e36f8b4d64609` are application/client architecture and are not copied. The delayed-agent-prompt fix in `8633a398e653eee47b375c963996c78a8a14aa48` changes PTY input sequencing, and `5616196942cbe752cc0659b9bd0fb616b2a6ed5c` hardens malformed Windows process environments in portable-pty. These changes are outside detector behavior and are not copied. SDK endpoint-generation compatibility remains a standalone-release requirement; review the Windows changes before publishing a Windows package.

Nineteen manifests are unchanged from the manifest snapshot. `claude.toml` is
byte-identical to upstream commit `987b070fbfa187e85009b45cd7e208fc6175ff6a`.
`grok.toml` is based on the snapshot file and contains one documented cmux
precedence correction. `github-copilot.toml` is byte-identical to the snapshot
and uses upstream version `2026.08.29.1`. The manifest engine, process discovery, state detector, and update
logic are adapted for the cmux userland plugin contract. The source paths,
commits, license, and adaptations are recorded in
`cmux-tui/bindings/examples/rust-agent-screen-detection/ATTRIBUTIONS.md`.
The SHA256SUMS file is a checked-in byte-provenance record verified before the
bundled manifests are compiled. It detects accidental drift, but it is not a
cryptographic release signature for remote updates.

---

## Sparkle

- **License:** MIT License
- **Copyright:** Copyright (c) 2006-2013 Andy Matuschak, 2009-2013 Elgato Systems GmbH, 2011-2014 Kornel Lesinski, 2015-2017 Sparkle Project
- **Source:** https://github.com/sparkle-project/Sparkle

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## PostHog iOS

- **License:** MIT License
- **Copyright:** Copyright (c) 2020 PostHog
- **Source:** https://github.com/PostHog/posthog-ios

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Sentry Cocoa

- **License:** MIT License
- **Copyright:** Copyright (c) 2015 Sentry
- **Source:** https://github.com/getsentry/sentry-cocoa

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Markdown Viewer Web Assets

cmux bundles these files under `Resources/markdown-viewer/` so the markdown
viewer has no runtime CDN dependency.

### marked

- **Version:** 13.0.3
- **License:** MIT License
- **Copyright:** Copyright (c) 2011-2024, Christopher Jeffrey
- **Source:** https://github.com/markedjs/marked/releases/tag/v13.0.3

### highlight.js

- **Version:** 11.10.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2006-2024 Josh Goebel and other contributors
- **Source:** https://github.com/highlightjs/highlight.js/releases/tag/11.10.0

### github-markdown-css

- **Version:** 5.6.1
- **License:** MIT License
- **Copyright:** Copyright (c) Sindre Sorhus
- **Source:** https://github.com/sindresorhus/github-markdown-css/tree/v5.6.1

### Mermaid

- **Version:** 11.4.1
- **License:** MIT License
- **Copyright:** Copyright (c) 2014-2024 Knut Sveidqvist and Mermaid contributors
- **Source:** https://github.com/mermaid-js/mermaid/releases/tag/mermaid%4011.4.1

### Vega

- **Version:** 5.30.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2015-2024 University of Washington Interactive Data Lab and contributors
- **Source:** https://github.com/vega/vega/releases/tag/v5.30.0

### Vega-Lite

- **Version:** 5.21.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2015-2024 University of Washington Interactive Data Lab and contributors
- **Source:** https://github.com/vega/vega-lite/releases/tag/v5.21.0

### Vega-Embed

- **Version:** 6.26.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2015-2024 University of Washington Interactive Data Lab and contributors
- **Source:** https://github.com/vega/vega-embed/releases/tag/v6.26.0

BSD 3-Clause License:

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

---

## Swift Package Dependencies

The following packages are linked into the cmux app binary.

### MarkdownUI (swift-markdown-ui)

- **License:** MIT License
- **Copyright:** Copyright (c) 2020 Guillermo Gonzalez
- **Source:** https://github.com/gonzalezreal/swift-markdown-ui

### NetworkImage

- **License:** MIT License
- **Copyright:** Copyright (c) 2020 Guille Gonzalez
- **Source:** https://github.com/gonzalezreal/NetworkImage

### swift-cmark (cmark / cmark-gfm)

- **License:** BSD 2-Clause License (and MIT-licensed portions; see upstream COPYING)
- **Copyright:** Copyright (c) 2014, John MacFarlane; cmark-gfm portions Copyright (c) 2017, GitHub, Inc.
- **Source:** https://github.com/swiftlang/swift-cmark

### iroh-ffi

- **License:** MIT License or Apache License 2.0 (dual-licensed; cmux elects MIT)
- **Copyright:** Copyright 2025 N0, INC.
- **Source:** https://github.com/manaflow-ai/iroh-ffi (fork of https://github.com/n0-computer/iroh-ffi)

### Swift Crypto and Swift ASN.1

- **License:** Apache License 2.0
- **Copyright:** Copyright (c) Apple Inc. and the SwiftCrypto / SwiftASN1 project authors
- **Source:** https://github.com/apple/swift-crypto, https://github.com/apple/swift-asn1

### Stack Auth Swift SDK

- **License:** MIT License (per Stack Auth's published per-package licensing policy,
  under which client SDKs are MIT-licensed; the vendored prerelease does not yet
  include its own LICENSE file)
- **Copyright:** Copyright (c) Stack Auth (HexClave, Inc.)
- **Source:** https://github.com/stack-auth/stack

### Highlightr

- **Version:** 2.3.0
- **License:** MIT License
- **Copyright:** Copyright (c) 2016 Juan Pablo Illanes
- **Source:** https://github.com/raspu/Highlightr

Linked by `Packages/Shared/CmuxSyntaxHighlighting`. It bundles highlight.js
(BSD 3-Clause, see above), whose `verilog` grammar colors `.sv`, `.svh`, `.v`
and `.vh` files in the file editor.

---

## SystemVerilog Editor Tools (not bundled)

The file editor's SystemVerilog support runs these programs when they are
installed on the machine that holds the file (the Mac, or the SSH host for
remote files). cmux does not bundle or redistribute them; the editor talks to
them over the Language Server Protocol or standard input/output.

### slang-server

- **License:** MIT License
- **Copyright:** Copyright (c) 2024-2025 Hudson River Trading LLC
- **Source:** https://github.com/hudson-trading/slang-server

Provides diagnostics, hover, go to definition, find references and completion.

### slang

- **License:** MIT License
- **Copyright:** Copyright (c) 2015-2026 Michael Popoloski
- **Source:** https://github.com/MikePopoloski/slang

The SystemVerilog compiler library that slang-server is built on.

### Verible

- **License:** Apache License 2.0
- **Copyright:** Copyright the Verible Authors
- **Source:** https://github.com/chipsalliance/verible

`verible-verilog-format` provides format on save.

### Language Server Protocol

- **License:** MIT License (specification text: Creative Commons Attribution 3.0)
- **Copyright:** Copyright (c) Microsoft Corporation
- **Source:** https://github.com/microsoft/language-server-protocol

The LSP client in `Packages/Shared/CmuxSyntaxHighlighting/Sources/CmuxSyntaxHighlighting/LanguageClient/`
is an original implementation written from this specification; no client
library code is copied.

---

## Waveform Viewer Assets

cmux bundles a build of VaporView's waveform viewer under `Resources/vaporview/`
(see its `README.md` for the build command and the local modifications) and
shows it for `.vcd`, `.fst` and `.ghw` files.

### VaporView

- **Version:** 1.6.1-beta, commit `59107c60c9ee5eefa95750b95369753736b77ca4`
- **License:** GNU General Public License v3.0 (full text in `Resources/vaporview/LICENSE`)
- **Copyright:** Lloyd Ramseyer (GitHub `Lramseyer`) and VaporView contributors; the repository carries no separate copyright notice
- **Source:** https://github.com/Lramseyer/vaporview/tree/59107c60c9ee5eefa95750b95369753736b77ca4

The minified webview (`src/webview/`), its stylesheet, and the wellen parser
compiled to WebAssembly (`src/wellen_parser/`) are bundled. The host page,
VS Code API shim and Web Worker in that folder are adapted from VaporView's
extension code and carry the same license.

### wellen

- **Version:** 0.25.7
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2023-2024, The Regents of the University of California
- **Source:** https://github.com/ekiwi/wellen

The waveform parser (VCD, FST, GHW), by Kevin Laeufer. Compiled into `filehandler.wasm`.

### fst-reader

- **Version:** 0.17.1
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2023, The Regents of the University of California
- **Source:** https://github.com/ekiwi/fst-reader

FST reading for wellen, by Kevin Laeufer. Compiled into `filehandler.wasm`.

### Other Rust crates compiled into `filehandler.wasm`

From `cargo tree --target wasm32-unknown-unknown -e normal,no-proc-macro` at the
commit above (license as declared in each crate's `Cargo.toml`):

- **adler2** 2.0.1: 0BSD OR MIT OR Apache-2.0; Copyright (C) Jonas Schievink; https://github.com/oyvindln/adler2
- **bincode** 1.3.3: MIT; Copyright (c) 2014 Ty Overby; https://github.com/servo/bincode
- **bitflags** 2.13.2: MIT OR Apache-2.0; Copyright (c) 2014 The Rust Project Developers; https://github.com/bitflags/bitflags
- **crossbeam-deque** 0.8.6: MIT OR Apache-2.0; Copyright (c) 2019 The Crossbeam Project Developers; https://github.com/crossbeam-rs/crossbeam
- **crossbeam-epoch** 0.9.18: MIT OR Apache-2.0; Copyright (c) 2019 The Crossbeam Project Developers; https://github.com/crossbeam-rs/crossbeam
- **crossbeam-utils** 0.8.21: MIT OR Apache-2.0; Copyright (c) 2019 The Crossbeam Project Developers; https://github.com/crossbeam-rs/crossbeam
- **either** 1.15.0: MIT OR Apache-2.0; Copyright (c) 2015 bluss; https://github.com/rayon-rs/either
- **equivalent** 1.0.2: Apache-2.0 OR MIT; Copyright (c) 2016--2023 the equivalent authors; https://github.com/indexmap-rs/equivalent
- **hashbrown** 0.17.1: MIT OR Apache-2.0; Copyright (c) 2016 Amanieu d'Antras; https://github.com/rust-lang/hashbrown
- **indexmap** 2.14.2: Apache-2.0 OR MIT; Copyright (c) 2016--2017 the indexmap authors; https://github.com/indexmap-rs/indexmap
- **itoa** 1.0.15: MIT OR Apache-2.0; Copyright David Tolnay; https://github.com/dtolnay/itoa
- **lazy_static** 1.5.0: MIT OR Apache-2.0; Copyright (c) 2010 The Rust Project Developers; https://github.com/rust-lang-nursery/lazy-static.rs
- **leb128** 0.2.7: MIT OR Apache-2.0; Copyright (c) 2015 The Rust Project Developers; https://github.com/gimli-rs/leb128
- **lz4_flex** 0.13.0 and 0.14.0: MIT; Copyright (c) 2020 Pascal Seitz; https://github.com/pseitz/lz4_flex
- **memchr** 2.7.5: Unlicense OR MIT; Copyright (c) 2015 Andrew Gallant; https://github.com/BurntSushi/memchr
- **memmap2** 0.9.10: MIT OR Apache-2.0; Copyright (c) 2020 Yevhenii Reizner; https://github.com/RazrFalcon/memmap2-rs
- **miniz_oxide** 0.9.1: MIT OR Zlib OR Apache-2.0; Copyright 2013-2014 RAD Game Tools and Valve Software; Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC; https://github.com/Frommi/miniz_oxide
- **num_enum** 0.7.6: BSD-3-Clause OR MIT OR Apache-2.0; Copyright Daniel Wagner-Hall, Daniel Henry-Mantilla and Vincent Esche; https://github.com/illicitonion/num_enum
- **rayon, rayon-core** 1.11.0, 1.13.0: MIT OR Apache-2.0; Copyright (c) 2010 The Rust Project Developers; https://github.com/rayon-rs/rayon
- **rustc-hash** 2.1.1: Apache-2.0 OR MIT; Copyright The Rust Project Developers; https://github.com/rust-lang/rustc-hash
- **serde, serde_core, serde_json** 1.0.228, 1.0.228, 1.0.151: MIT OR Apache-2.0; Copyright Erick Tryzelaar and David Tolnay; https://github.com/serde-rs/serde
- **smallvec** 1.15.1: MIT OR Apache-2.0; Copyright (c) 2018 The Servo Project Developers; https://github.com/servo/rust-smallvec
- **thiserror** 2.0.12: MIT OR Apache-2.0; Copyright David Tolnay; https://github.com/dtolnay/thiserror
- **twox-hash** 2.1.1: MIT; Copyright (c) 2015 Jake Goulding; https://github.com/shepmaster/twox-hash
- **wit-bindgen** 0.62.0: Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT; Copyright Alex Crichton and the wit-bindgen contributors; https://github.com/bytecodealliance/wit-bindgen
- **zmij** 1.0.23: MIT; Copyright David Tolnay; https://github.com/dtolnay/zmij

### npm packages bundled into `webview.js`

From esbuild's metafile for the production `webview.js`:

- **@js-temporal/polyfill** 0.5.1: ISC License; Copyright 2017, 2018, 2019, 2020 ECMA International; https://github.com/js-temporal/temporal-polyfill
- **culori** 4.0.2: MIT License; Copyright (c) 2018 Dan Burzo; https://github.com/Evercoder/culori
- **jsbi** 4.3.2: Apache License 2.0; Copyright 2018 Google Inc.; https://github.com/GoogleChromeLabs/jsbi
- **lz4js** 0.2.0: ISC License (declared in package.json, no license file shipped); Copyright John Chadwick; https://github.com/Benzinga/lz4js

### Codicons

- **Version:** 0.0.35 (`@vscode/codicons`)
- **License:** Creative Commons Attribution 4.0 International (icon font); MIT License (code)
- **Copyright:** Copyright (c) Microsoft Corporation
- **Source:** https://github.com/microsoft/vscode-codicons

`codicon.css` and `codicon.ttf` are bundled unmodified in
`Resources/vaporview/codicons/` with both license files.

### FSDB helper sources (`Resources/vaporview/fsdb-helper/`)

cmux uploads these to an SSH host the first time an FSDB file is opened there
and builds the FSDB reader on that host (see "Verdi FSDB Reader" below). They
ship as source; nothing in them is compiled into cmux.

- **VaporView FSDB addon and worker:** `fsdb_reader.cpp` is VaporView's
  `src/fsdb_reader.cpp` at the commit above, unmodified; `packed.cpp.inc`
  (a cmux addition spliced into it at build time) and `fsdb-helper.js`
  (adapted from `src/extension_core/fsdb_worker.ts`) carry VaporView's
  GPL-3.0 license.
- **node-addon-api** 8.6.0: MIT License; Copyright (c) 2017 Node.js API
  collaborators; https://github.com/nodejs/node-addon-api. `napi.h`,
  `napi-inl.h` and `napi-inl.deprecated.h`, unmodified, with `LICENSE.md`, in
  `fsdb-helper/third_party/node-addon-api/`.
- **node-api-headers** 1.9.0: MIT License; Copyright (c) 2021 Node.js;
  https://github.com/nodejs/node-api-headers. The four Node-API C headers,
  unmodified, with `LICENSE`, in `fsdb-helper/third_party/node-api-headers/`.

ISC License (for the ISC components above):

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

MIT, BSD 3-Clause and Apache-2.0 components use the license texts in this
document. For dual- or multi-licensed crates cmux uses them under the MIT
License.

---

## Waveform Viewer Tools (not bundled)

### Verdi FSDB Reader

- **License:** Proprietary (Synopsys end-user license)
- **Copyright:** Copyright (c) Synopsys, Inc.
- **Source:** Ships with Synopsys Verdi (`$VERDI_HOME/share/FsdbReader/`); not publicly available

Reading `.fsdb` waveforms needs Verdi's FSDB reader libraries on the machine
that holds the file. cmux does not bundle, link against, or redistribute them.
On an SSH workspace, cmux builds its FSDB helper on the remote host against
that host's own Verdi installation, for the user who opens the file, and keeps
it in `~/.cache/cmux/fsdb-helper/` there; the built reader never leaves that
host.

---

## Diff Viewer Highlighting Assets

cmux bundles compiled syntax-highlighting code and grammars (shiki and its
Oniguruma WASM engine, built from `webviews/` with `@pierre/diffs`) inside the
generated `Resources/markdown-viewer/webviews-app/` bundle so the diff viewer
has no runtime CDN dependency.

### shiki

- **License:** MIT License
- **Copyright:** Copyright (c) 2021 Pine Wu; Copyright (c) 2023 Anthony Fu and Shiki contributors
- **Source:** https://github.com/shikijs/shiki

### vscode-textmate

- **License:** MIT License
- **Copyright:** Copyright (c) Microsoft Corporation
- **Source:** https://github.com/microsoft/vscode-textmate

### vscode-oniguruma

- **License:** MIT License
- **Copyright:** Copyright (c) Microsoft Corporation
- **Source:** https://github.com/microsoft/vscode-oniguruma

### Oniguruma

- **License:** BSD 2-Clause License
- **Copyright:** Copyright (c) 2002-2019 K.Kosako
- **Source:** https://github.com/kkos/oniguruma (bundled as WebAssembly via vscode-oniguruma)

---

## Browser REPL Runtime Assets

cmux bundles these files under `Resources/browser-repl/vendor/` for the
`cmux browser repl` runtime and its page agent.

### Playwright (injected script and locator helpers)

- **Version:** 1.57.0 (`playwright-core`)
- **License:** Apache License 2.0
- **Copyright:** Copyright (c) Microsoft Corporation
- **Source:** https://github.com/microsoft/playwright
- **Files:** `vendor/playwright-injected.js` (the generated `injectedScriptSource`
  bundle, unmodified) and `vendor/playwright-locator-utils.js` (functions from
  `lib/utils/isomorphic/locatorUtils.js` and `stringUtils.js`, re-wrapped as a
  plain script)

Playwright's NOTICE: "Playwright. Copyright (c) Microsoft Corporation. This
software contains code derived from the Puppeteer project
(https://github.com/puppeteer/puppeteer), available under the Apache 2.0
license (https://github.com/puppeteer/puppeteer/blob/master/LICENSE)."

### acorn

- **Version:** 8.16.0
- **License:** MIT License
- **Copyright:** Copyright (C) 2012-2022 by various contributors
- **Source:** https://github.com/acornjs/acorn
- **Files:** `vendor/acorn.js` (`dist/acorn.js`, unmodified)

---

## Shared License Texts

MIT-licensed components above are distributed under the MIT License text
reproduced in the sections earlier in this document. BSD 2-Clause components
are distributed under the following text:

BSD 2-Clause License:

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Apache-2.0-licensed components are distributed under the Apache License,
Version 2.0. A copy of the license is available at
http://www.apache.org/licenses/LICENSE-2.0 and in each component's source
repository listed above.

---

## WireGuardKit (wireguard-apple)

- **License:** MIT License
- **Copyright:** Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
- **Source:** https://git.zx2c4.com/wireguard-apple (vendored at `vendor/WireGuardKit`)
- **Used by:** the cmux Cloud tunnel system extension (`Contents/Library/SystemExtensions`)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

"WireGuard" and the "WireGuard" logo are registered trademarks of Jason A. Donenfeld.

---

## wireguard-go

- **License:** MIT License
- **Copyright:** Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.
- **Source:** https://git.zx2c4.com/wireguard-go (module `golang.zx2c4.com/wireguard`, compiled into the tunnel extension via `scripts/build-wireguard-go.sh`)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## Go supplementary libraries (golang.org/x/crypto, golang.org/x/net, golang.org/x/sys)

- **License:** BSD 3-Clause License
- **Copyright:** Copyright 2009 The Go Authors.
- **Source:** https://go.googlesource.com/crypto, https://go.googlesource.com/net, https://go.googlesource.com/sys (compiled into the tunnel extension via wireguard-go)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
