#!/bin/bash
# Builds "GitHub Monitor.app" into ./build. Pass "install" to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release -Xswiftc -Osize -Xswiftc -wmo

APP="build/GitHub Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GitHubMonitor "$APP/Contents/MacOS/"
strip -x "$APP/Contents/MacOS/GitHubMonitor"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
    pkill -x GitHubMonitor 2>/dev/null || true
    rm -rf "/Applications/GitHub Monitor.app"
    cp -R "$APP" /Applications/
    open "/Applications/GitHub Monitor.app"
    echo "Installed to /Applications"
fi
