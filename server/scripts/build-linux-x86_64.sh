#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

tools_directory="$PWD/.cross-tools"
rust_target="x86_64-unknown-linux-gnu"
case "${1:-}" in
    --setup)
        if command -v uv >/dev/null 2>&1; then
            if [[ ! -x "$tools_directory/bin/python" ]]; then
                uv venv --python python3 "$tools_directory"
            fi
            uv pip install --python "$tools_directory/bin/python" cargo-zigbuild==0.24.0 ziglang==0.14.1
        else
            if [[ ! -x "$tools_directory/bin/python" ]]; then
                python3 -m venv "$tools_directory"
            fi
            "$tools_directory/bin/python" -m pip install cargo-zigbuild==0.24.0 ziglang==0.14.1
        fi
        rustup target add "$rust_target"
        ;;
    "") ;;
    *) echo "Usage: bash scripts/build-linux-x86_64.sh [--setup]" >&2; exit 2 ;;
esac

if [[ ! -x "$tools_directory/bin/cargo-zigbuild" ]]; then
    echo "Cross-build tools are missing. Run this script once with --setup." >&2
    exit 1
fi
if [[ "$(rustup target list --installed)" != *"$rust_target"* ]]; then
    echo "The Rust Linux target is missing. Run this script once with --setup." >&2
    exit 1
fi

export PATH="$tools_directory/bin:$PATH"
export CARGO_ZIGBUILD_PYTHON_PATH="$tools_directory/bin/python"
export ZIG_GLOBAL_CACHE_DIR="$PWD/target/zig-cache"
export CARGO_ZIGBUILD_CACHE_DIR="$PWD/target/zigbuild-cache"
cargo zigbuild --release --locked --target "$rust_target.2.31"
file "target/$rust_target/release/portside-server"
