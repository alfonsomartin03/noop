#!/bin/sh
# Builds ble_probe and wraps it in an .app so macOS asks for Bluetooth permission for the probe itself
# (a bare CLI is attributed to its parent terminal and killed for lacking a usage description).
set -e
cd "$(dirname "$0")"
swift build -c debug
APP=.build/NOOPBLEProbe.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp bundle/Info.plist "$APP/Contents/Info.plist"
cp .build/debug/ble_probe "$APP/Contents/MacOS/ble_probe"
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
