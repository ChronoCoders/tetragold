#!/usr/bin/env bash
#
# One-command local monitor: start anvil, deploy the full stack with
# DeployLocal, capture the deployed addresses, and launch the live dashboard.
#
# Usage:
#   tools/monitor/start-local.sh            # deploy + dashboard
#   tools/monitor/start-local.sh --deploy-only   # deploy + write addresses.env, no UI
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RPC_URL="${RPC_URL:-http://localhost:8545}"
ANVIL="${ANVIL:-$HOME/.foundry/bin/anvil}"
FORGE="${FORGE:-$HOME/.foundry/bin/forge}"
ADDR_FILE="$HERE/addresses.env"
DEPLOY_ONLY=0
[ "${1:-}" = "--deploy-only" ] && DEPLOY_ONLY=1

command -v "$ANVIL" >/dev/null 2>&1 || ANVIL=anvil
command -v "$FORGE" >/dev/null 2>&1 || FORGE=forge

ANVIL_PID=""
cleanup() { [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Start anvil unless something already answers on the RPC.
if ! "$HOME/.foundry/bin/cast" block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  echo "Starting anvil..."
  "$ANVIL" --silent &
  ANVIL_PID=$!
  for _ in $(seq 1 30); do
    "$HOME/.foundry/bin/cast" block-number --rpc-url "$RPC_URL" >/dev/null 2>&1 && break
    sleep 0.2
  done
else
  echo "Using existing node at $RPC_URL"
fi

echo "Deploying protocol (DeployLocal.s.sol)..."
DEPLOY_OUT="$("$FORGE" script "$ROOT/script/DeployLocal.s.sol:DeployLocal" \
  --rpc-url "$RPC_URL" --broadcast 2>&1)"

# Extract "Label: 0x..." pairs from the deployment summary into addresses.env.
grab() { grep -oE "$1: +0x[a-fA-F0-9]{40}" <<<"$DEPLOY_OUT" | grep -oE "0x[a-fA-F0-9]{40}" | head -1; }
{
  echo "export RPC_URL=$RPC_URL"
  echo "export ORACLE=$(grab 'OracleAggregator')"
  echo "export POOL=$(grab 'LiquidityPool')"
  echo "export VAULT=$(grab 'VaultManager')"
  echo "export LIQUIDATION_ENGINE=$(grab 'LiquidationEngine')"
  echo "export INSURANCE=$(grab 'InsuranceFund')"
  echo "export TGAUX=$(grab 'TGAUX')"
  echo "export USDC=$(grab 'USDC')"
  echo "export USDT=$(grab 'USDT')"
} >"$ADDR_FILE"

echo "Wrote $ADDR_FILE:"
sed 's/^/  /' "$ADDR_FILE"

if [ "$DEPLOY_ONLY" = 1 ]; then
  echo "Deploy-only mode. Anvil keeps running until you stop it; addresses saved."
  trap - EXIT  # leave anvil running
  exit 0
fi

# shellcheck disable=SC1090
source "$ADDR_FILE"
trap - EXIT  # keep anvil alive while the dashboard runs in foreground
exec "$HERE/dashboard.sh"
