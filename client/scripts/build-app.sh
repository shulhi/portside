#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift build -c release
binary_directory="$(xcrun swift build -c release --show-bin-path)"
application_directory="$PWD/dist/Portside.app"
mkdir -p "$application_directory/Contents/MacOS" "$application_directory/Contents/Resources"
cp "$binary_directory/Portside" "$application_directory/Contents/MacOS/Portside"
cp Resources/Info.plist "$application_directory/Contents/Info.plist"
xcrun swift scripts/make-icon.swift "$PWD/.build/Portside.iconset"
iconutil -c icns .build/Portside.iconset -o "$application_directory/Contents/Resources/Portside.icns"
codesign --force --sign - --identifier app.portside.mac "$application_directory"
echo "Built $application_directory"
