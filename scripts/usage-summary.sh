#!/bin/bash
# Run the usage engine against the real ~/.claude/projects (or the folder given as $1) and print
# totals, scan time and idle-rescan time. Numbers only, never transcript contents.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx14.0 -sdk "$(xcrun --show-sdk-path)" \
  Sources/ClaudeNotch/UsageCore.swift Tools/usage_summary/main.swift -o build/usage-summary
build/usage-summary "$@"
