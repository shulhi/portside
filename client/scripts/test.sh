#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
(cd ../server && cargo build --release --locked)
export PORTSIDE_TEST_SERVER="$(cd ../server && pwd)/target/release/portside-server"
xcrun swift test
