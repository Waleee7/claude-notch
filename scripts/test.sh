#!/bin/bash
# Compile and run the usage engine's unit tests with plain swiftc (no XCTest, no swift build).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx14.0 -sdk "$(xcrun --show-sdk-path)" \
  Sources/ClaudeNotch/UsageCore.swift Tests/UsageCoreTests/main.swift -o build/usage-tests
build/usage-tests
