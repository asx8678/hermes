#!/bin/bash
# Build a fat desktop binary for a single (OS, arch) target.
#
# The Elixir release is built with bundled ERTS, compressed with zstd,
# embedded into the Rust host crate, and the Rust host binary is compiled
# for the requested target triple. The resulting binary is then packaged
# by host/scripts/package-release.sh.
#
# Usage:
#   bash host/scripts/build-desktop.sh <target-triple> [artifact-name]
#
# Examples:
#   bash host/scripts/build-desktop.sh aarch64-apple-darwin hermes-darwin-arm64
#   bash host/scripts/build-desktop.sh x86_64-unknown-linux-gnu hermes-linux-x64
#
# Because ERTS and Rustler NIFs are native, the default build only allows
# the target to match the host triple. To override (e.g. when a cross
# toolchain and foreign ERTS are configured), set CROSS_COMPILE=1.
set -euo pipefail

cd "$(dirname "$0")/../.."  # repo root

TARGET=${1:?"target triple required (e.g. aarch64-apple-darwin)"}
ARTIFACT_NAME=${2:-"hermes-${TARGET}"}

HOST_TRIPLE=$(rustc -vV | sed -n 's|host: ||p')

if [[ "$TARGET" != "$HOST_TRIPLE" && -z "${CROSS_COMPILE:-}" ]]; then
  echo "ERROR: target ${TARGET} does not match host ${HOST_TRIPLE}." >&2
  echo "ERTS and NIFs are native, so desktop binaries must be built on the target architecture." >&2
  echo "Set CROSS_COMPILE=1 only if you have configured a cross toolchain and matching ERTS." >&2
  exit 1
fi

# Ensure Elixir dependencies are present before compiling the release.
mix deps.get


echo "=== Building desktop binary for ${TARGET} (host: ${HOST_TRIPLE}) ==="

# Ensure the Rust target is installed.
rustup target add "$TARGET"

# 1. Build the Elixir release with bundled ERTS.
MIX_ENV=prod mix release --overwrite

# 2. Compress and stage the release for embedding.
bash host/scripts/build-release.sh

# 3. Build the Rust host binary for the target.
cargo build --release --manifest-path host/Cargo.toml --target "$TARGET"

# 4. Package the binary into a tar.zst archive.
bash host/scripts/package-release.sh "$TARGET" "$ARTIFACT_NAME"

echo "=== Desktop build complete: host/dist/${ARTIFACT_NAME}.tar.zst ==="
