#!/bin/bash
# Regenerates the screenshots in docs/vaporview/images/ from open fixtures only (fsm/fsm.vcd,
# riscv/riscv.vcd, machine/fixtures/picorv32). Each dump opens in an off-screen, transparent,
# click-through WKWebView (main.swift), as run.sh's page harnesses do: nothing is shown on screen.
# Usage: make-shots.sh [outDir]   (default: docs/vaporview/images). Needs Xcode's swiftc, python3, sips.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ASSETS="$ROOT/Resources/vaporview"
CHECKS="$ROOT/scripts/waveform-viewer-checks"
DEST="${1:-$ROOT/docs/vaporview/images}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-docs-shots.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$DEST"
swiftc -O "$HERE/main.swift" "$ROOT/Sources/Panels/WaveformViewerSchemeHandler.swift" \
  "$ROOT/Sources/Panels/WaveformFSDBHelper.swift" -o "$OUT/shot"
# The page's English strings, as the app hands them over (WaveformViewerStrings and the debugger's).
python3 -I "$HERE/strings.py" "$OUT/strings.json" "$ROOT"/Sources/Panels/Waveform*.swift "$ROOT/Sources/Panels/FilePreviewWaveformSession.swift"
shot() { perl -e 'alarm 960; exec @ARGV' "$OUT/shot" "$ASSETS" "$1" "$OUT/strings.json" "$HERE/$2" "$OUT" "$3" "$4" | grep -E '^(wrote|.*ERROR|timeout)' || true; }
shot "$CHECKS/fsm/fsm.vcd" fsm-steps.js 1200 700
mv "$OUT/context-menu.png" "$OUT/context-menu-tall.png"
shot "$CHECKS/fsm/fsm.vcd" fsm-steps.js 1200 520
shot "$CHECKS/machine/fixtures/picorv32/picorv32.vcd" machine-steps.js 1200 760
shot "$CHECKS/riscv/riscv.vcd" riscv-steps.js 1200 560
# crop <in> <out> <x> <y> <w> <h> <width>: snapshot pixels (2x), then scaled to <width>.
crop() { [ -s "$OUT/$1" ] || { echo "make-shots: $1 was not written" >&2; exit 1; }
         sips --cropOffset "$4" "$3" -c "$6" "$5" "$OUT/$1" --out "$OUT/crop.png" >/dev/null
         sips --resampleWidth "$7" "$OUT/crop.png" --out "$DEST/$2" >/dev/null; }
crop viewer.png viewer-overview.png 0 0 2400 960 1200
crop fsm-pane.png fsm-view.png 0 0 2400 1040 1200
crop context-menu-tall.png context-menu.png 0 0 1320 1400 660
crop riscv-menu.png riscv-format-menu.png 380 0 1380 1000 690
crop debugger-machine.png debugger-machine-state.png 0 0 2400 1520 1200
crop machine-sequences.png machine-sequences.png 0 930 662 560 662
ls -l "$DEST"
