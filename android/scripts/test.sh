#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${JAVA_HOME:-}" && -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
    export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
if [[ -z "${ANDROID_HOME:-}" && -d "$HOME/Library/Android/sdk" ]]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
fi
cargo build --manifest-path ../server/Cargo.toml --release --locked
export PORTSIDE_TEST_SERVER="$PWD/../server/target/release/portside-server"
export PORTSIDE_TEST_TAILSCALE="$PWD/../server/tests/fixtures/tailscale.py"
./gradlew :core:test --rerun-tasks
