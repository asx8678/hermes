#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."  # repo root

# Build the Elixir release with bundled ERTS
MIX_ENV=prod mix release --overwrite

# Compress the release with zstd
RELEASE_DIR="_build/prod/rel/hermes"
OUTPUT_DIR="host/embedded"
mkdir -p "$OUTPUT_DIR"

tar -cf - -C "_build/prod/rel" "hermes" | zstd -19 -f -o "$OUTPUT_DIR/hermes-release.tar.zst"

echo "Release embedded to $OUTPUT_DIR/hermes-release.tar.zst"
