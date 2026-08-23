#!/usr/bin/env bash
# Attestable — one-shot dev setup. Safe to re-run.
#   bash scripts/setup.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Foundry"
if ! command -v forge >/dev/null 2>&1; then
  echo "    not found — installing"
  curl -L https://foundry.paradigm.xyz | bash
  # shellcheck disable=SC1090
  export PATH="$HOME/.foundry/bin:$PATH"
  foundryup
else
  echo "    $(forge --version | head -1)"
fi

echo "==> forge-std"
if [ ! -d lib/forge-std ]; then
  git clone --depth 1 -q https://github.com/foundry-rs/forge-std.git lib/forge-std
  echo "    cloned"
else
  echo "    present"
fi

echo "==> .env"
if [ ! -f .env ]; then
  cp .env.example .env
  echo "    created from .env.example — fill it in (it is gitignored)"
else
  echo "    present"
fi

echo "==> build + test"
forge test

echo "==> chain preflight"
node scripts/preflight.mjs || true

echo
echo "Ready. Frontend:  python -m http.server 3000 --directory frontend"
