#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build --build-system native -c release
MODE_BIN_DIR="$(swift build --build-system native -c release --show-bin-path)"
swift scripts/bundle.swift "$MODE_BIN_DIR"
