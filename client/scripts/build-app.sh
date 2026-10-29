#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift build -c release
binary_directory="$(xcrun swift build -c release --show-bin-path)"
mkdir -p "$PWD/dist" "$PWD/.build"
staging_directory="$(mktemp -d "$PWD/.build/app-update.XXXXXX")"
application_directory="$staging_directory/Portside.app"
mkdir -p "$application_directory/Contents/MacOS" "$application_directory/Contents/Resources"
cp "$binary_directory/Portside" "$application_directory/Contents/MacOS/Portside"
cp Resources/Info.plist "$application_directory/Contents/Info.plist"
xcrun swift scripts/make-icon.swift "$PWD/.build/Portside.iconset"
iconutil -c icns .build/Portside.iconset -o "$application_directory/Contents/Resources/Portside.icns"
codesign --force --sign - --identifier app.portside.mac "$application_directory"
# Replace the bundle by renaming it, rather than overwriting a running executable.
# Retain the old bundle in the ignored build directory until the app is relaunched.
python3 - "$application_directory" "$PWD/dist/Portside.app" "$staging_directory/Portside.previous.app" <<'PY'
import os
import sys

staged, destination, previous = sys.argv[1:]
had_previous = os.path.exists(destination)
if had_previous:
    os.rename(destination, previous)
try:
    os.rename(staged, destination)
except OSError:
    if had_previous:
        os.rename(previous, destination)
    raise
PY
echo "Built $PWD/dist/Portside.app — relaunch when ready to use the update."
