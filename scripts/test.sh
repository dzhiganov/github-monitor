#!/bin/bash
# Runs the PR classification tests (no network needed).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp -d)/classifier-tests
swiftc Sources/GitHubMonitor/GitHub.swift scripts/classifier-tests/main.swift -o "$BIN"
"$BIN"
