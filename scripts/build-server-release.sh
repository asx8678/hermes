#!/bin/bash
set -euo pipefail

MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release --overwrite

echo "Server release built at _build/prod/rel/hermes/"
echo "Container: docker build -f Dockerfile.server -t hermes-server:latest ."
