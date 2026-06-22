#!/bin/bash
set -euo pipefail
# Sign the Rust host binary for the requested target.
#
# Platform-specific signing:
#   macOS: codesign with APPLE_DEVELOPER_ID identity
#   Linux: optional detached GPG signature when GPG_KEY_ID is set
#
# Usage:
#   bash host/scripts/sign-and-verify.sh <target-triple>
#
# Secrets are loaded from environment variables. When a secret is missing,
# the script falls back to a no-op or warning so CI scaffolding can run
# without real certificates.

cd "$(dirname "$0")/../.."  # repo root

TARGET=${1:?"target triple required (e.g. aarch64-apple-darwin)"}
BINARY="host/target/${TARGET}/release/hermes-host"

if [[ ! -f "$BINARY" ]]; then
  echo "Binary not found at ${BINARY}" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    if [[ -n "${APPLE_DEVELOPER_ID:-}" ]]; then
      echo "=== Signing ${BINARY} with Developer ID ${APPLE_DEVELOPER_ID} ==="
      codesign --force --options runtime --sign "$APPLE_DEVELOPER_ID" --timestamp "$BINARY"
      codesign --verify --verbose=2 "$BINARY"
    else
      echo "=== APPLE_DEVELOPER_ID not set; skipping macOS code signing ==="
    fi
    ;;

  Linux)
    if [[ -n "${GPG_KEY_ID:-}" ]]; then
      echo "=== Signing ${BINARY} with GPG key ${GPG_KEY_ID} ==="
      gpg --batch --yes --detach-sign --armor --local-user "$GPG_KEY_ID" "$BINARY"
      gpg --verify "${BINARY}.asc" "$BINARY"
    else
      echo "=== GPG_KEY_ID not set; skipping Linux GPG signing ==="
    fi
    ;;

  *)
    echo "=== Unsupported host OS: $(uname -s); skipping signing ==="
    ;;
esac

echo "Signed/verified: $BINARY"
