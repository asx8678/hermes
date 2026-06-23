#!/usr/bin/env bash
#
# Launch the hermes TUI against the Makora provider.
#
# The Makora token is read at runtime from the local oh-my-posh agent config
# (~/.omp/agent/models.yml) so it is never duplicated into this file. Both Kimi
# and GLM are `makora` models in hermes' catalog, so this one token covers both.
#
# Usage:
#   ./run-tui.sh                              # GLM-5.2 (default)
#   ./run-tui.sh moonshotai/Kimi-K2.7-Code    # Kimi
#   ./run-tui.sh zai-org/GLM-5.2-FP8          # GLM (explicit)
#
# Switch models live inside the TUI with `/model`.
set -euo pipefail

OMP_MODELS="${HOME}/.omp/agent/models.yml"
MODEL="${1:-zai-org/GLM-5.2-FP8}"

if [[ ! -f "${OMP_MODELS}" ]]; then
  echo "run-tui: ${OMP_MODELS} not found" >&2
  exit 1
fi

# Pull the apiKey from the `makora:` block, stripping any inline comment.
TOKEN="$(awk '/^[[:space:]]*makora:/{f=1} f&&/apiKey:/{sub(/#.*/,""); sub(/^[^:]*:[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit}' "${OMP_MODELS}")"

if [[ -z "${TOKEN}" ]]; then
  echo "run-tui: could not find makora apiKey in ${OMP_MODELS}" >&2
  exit 1
fi

export MAKORA_OPTIMIZE_TOKEN="${TOKEN}"
# The TUI uses the Tokyo Night truecolor palette; default COLORTERM so modern
# terminals get the full RGB theme instead of the named-color fallback.
export COLORTERM="${COLORTERM:-truecolor}"

cd "$(dirname "$0")"
exec ./target/release/hermes-host --provider makora --model "${MODEL}" chat
