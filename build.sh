#!/bin/bash
# Builds "GitHub Monitor.app" into ./build.
#   ./build.sh           native build
#   ./build.sh install   native build, copy to /Applications and launch
#   ./build.sh release   universal (arm64 + x86_64) build, zipped to build/GitHubMonitor-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
FLAGS=(-c release -Xswiftc -Osize -Xswiftc -wmo)
if [[ "$MODE" == "release" ]]; then
    swift build "${FLAGS[@]}" --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release/GitHubMonitor
else
    swift build "${FLAGS[@]}"
    BIN=.build/release/GitHubMonitor
fi

APP="build/GitHub Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
strip -x "$APP/Contents/MacOS/GitHubMonitor"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

case "$MODE" in
install)
    pkill -x GitHubMonitor 2>/dev/null || true
    rm -rf "/Applications/GitHub Monitor.app"
    cp -R "$APP" /Applications/
    open "/Applications/GitHub Monitor.app"
    echo "Installed to /Applications"
    ;;
release)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    ZIP="build/GitHubMonitor-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
    ;;
esac
