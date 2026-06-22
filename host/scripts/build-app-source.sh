#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."  # repo root

# Package the Elixir app source (excluding build artifacts, deps, and dotfiles)
# so the Rust host can embed it and extract it next to ~/.hermes for
# system-runtime launches (mix phx.server from source under mise/PATH Erlang).
OUTPUT_DIR="host/embedded"
mkdir -p "$OUTPUT_DIR"

tar -cf - \
  --exclude='_build' \
  --exclude='deps' \
  --exclude='.git' \
  --exclude='.elixir_ls' \
  --exclude='.elixir-tools' \
  --exclude='hermes_test.db*' \
  --exclude='hermes_dev.db*' \
  --exclude='erl_crash.dump' \
  --exclude='.DS_Store' \
  --exclude='.beads' \
  --exclude='.claude' \
  -C . mix.exs mix.lock config lib priv test .formatter.exs 2>/dev/null \
  | zstd -19 -f -o "$OUTPUT_DIR/hermes-app-source.tar.zst"

echo "App source embedded to $OUTPUT_DIR/hermes-app-source.tar.zst"
