#!/bin/sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || true)}"
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
  SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
fi
OUT="${ROOT}/.build-local"
mkdir -p "$OUT"
cd "${ROOT}/Sources/ClaudeNotch"
swiftc -O -target arm64-apple-macosx11.0 \
  -sdk "$SDK" \
  -framework AppKit -framework SwiftUI \
  -o "${OUT}/ClaudeNotch" \
  main.swift AppDelegate.swift UnixSocketServer.swift NotchPanelController.swift SoundPlayer.swift PetView.swift SessionTracker.swift MarkdownView.swift TerminalJumper.swift ChatEngine.swift
echo "Built: ${OUT}/ClaudeNotch"
