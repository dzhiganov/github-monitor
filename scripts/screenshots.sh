#!/bin/bash
# Renders README screenshots from mock data into docs/.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp -d)/screenshots
swiftc -DDEBUG $(ls Sources/GitHubMonitor/*.swift | grep -v main.swift) scripts/screenshots/main.swift -o "$BIN"
"$BIN" docs
