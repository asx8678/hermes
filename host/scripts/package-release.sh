#!/bin/bash
# Package the built Rust host binary as a .tar.zst archive.
#
# The binary is renamed from "hermes-host" to "hermes" for the shipped CLI
# name. On macOS, if SIGNING_IDENTITY is set, the binary is codesigned with
# the requested developer identity before packaging.
#
# Usage:
#   bash host/scripts/package-release.sh <target-triple> [artifact-name]
#
# If the built binary is missing, this script falls back to invoking
# host/scripts/build-desktop.sh so it can be used as a CI wrapper.
set -euo pipefail

cd "$(dirname "$0")/../.."  # repo root

TARGET=${1:?"target triple required (e.g. aarch64-apple-darwin)"}
ARTIFACT_NAME=${2:-"hermes-${TARGET}"}

BIN_DIR="host/target/${TARGET}/release"
HOST_BIN="${BIN_DIR}/hermes-host"
SIDECAR_BIN="${BIN_DIR}/hermes-sidecar"
DIST_DIR="host/dist"

if [[ ! -f "$HOST_BIN" ]]; then
  echo "Built host binary not found at ${HOST_BIN}; running full build..." >&2
  exec bash host/scripts/build-desktop.sh "$TARGET" "$ARTIFACT_NAME"
fi

if [[ ! -f "$SIDECAR_BIN" ]]; then
  echo "Warning: sidecar binary not found at ${SIDECAR_BIN}; package will not include it." >&2
fi

mkdir -p "$DIST_DIR"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$HOST_BIN" "$TMP_DIR/hermes"
chmod +x "$TMP_DIR/hermes"

if [[ -f "$SIDECAR_BIN" ]]; then
  cp "$SIDECAR_BIN" "$TMP_DIR/hermes-sidecar"
  chmod +x "$TMP_DIR/hermes-sidecar"
fi

# Optional macOS code signing. In CI set SIGNING_IDENTITY to the name of
# a Developer ID or Apple Distribution certificate in the keychain.
if [[ "$(uname -s)" == "Darwin" && -n "${SIGNING_IDENTITY:-}" ]]; then
  echo "=== Signing binaries with identity: ${SIGNING_IDENTITY} ==="
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp \
           "$TMP_DIR/hermes"
  if [[ -f "$TMP_DIR/hermes-sidecar" ]]; then
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp \
             "$TMP_DIR/hermes-sidecar"
  fi
else
  echo "=== No signing identity configured; packaging unsigned binary ==="
fi

OUTPUT="${DIST_DIR}/${ARTIFACT_NAME}.tar.zst"

if [[ -f "$TMP_DIR/hermes-sidecar" ]]; then
  tar -cf - -C "$TMP_DIR" hermes hermes-sidecar | zstd -19 -f -o "$OUTPUT"
else
  tar -cf - -C "$TMP_DIR" hermes | zstd -19 -f -o "$OUTPUT"
fi

echo "Packaged: ${OUTPUT}"
ls -lh "$OUTPUT"
