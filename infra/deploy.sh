#!/usr/bin/env bash
# Builds the gateway and applies the infrastructure.
#   infra/deploy.sh            plan + apply (asks for confirmation)
#   infra/deploy.sh plan       plan only
set -euo pipefail
cd "$(dirname "$0")/.."

(cd gateway && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o dist/gateway-linux-arm64 .)

cd infra
tofu init -input=false >/dev/null
if [[ ${1:-} == plan ]]; then
  tofu plan
else
  tofu apply
fi
