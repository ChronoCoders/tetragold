#!/usr/bin/env bash
set -uo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$OPS_DIR/../.." && pwd)"

RPC_URL="${RPC_URL:-http://localhost:8545}"
ANVIL_PORT="${ANVIL_PORT:-8545}"
KEY="${KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
WITH_SUBGRAPH="${WITH_SUBGRAPH:-0}"

FORGE="${FORGE:-$HOME/.foundry/bin/forge}"; command -v "$FORGE" >/dev/null 2>&1 || FORGE=forge
CAST="${CAST:-$HOME/.foundry/bin/cast}"; command -v "$CAST" >/dev/null 2>&1 || CAST=cast
ANVIL="${ANVIL:-$HOME/.foundry/bin/anvil}"; command -v "$ANVIL" >/dev/null 2>&1 || ANVIL=anvil

GOLD_8DEC=284700000000
COLLATERAL=110000000
LEVERAGE=2
POS_ID=1

ANVIL_PID=""
LOG_DIR="$(mktemp -d)"
PASS=0; FAIL=0

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
step()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }

cleanup() {
  [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null
  rm -rf "$LOG_DIR"
}
trap cleanup EXIT INT TERM

assert() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then green "  PASS: $desc"; PASS=$((PASS+1));
  else red "  FAIL: $desc (got '$got', want '$want')"; FAIL=$((FAIL+1)); fi
}

call() { "$CAST" call "$1" "$2" "${@:3}" --rpc-url "$RPC_URL" 2>/dev/null | sed -E 's/ \[[^][]*\]//g'; }
send() { "$CAST" send "$1" "$2" "${@:3}" --private-key "$KEY" --rpc-url "$RPC_URL" >/dev/null 2>&1; }
mine() { "$CAST" rpc evm_increaseTime "$1" --rpc-url "$RPC_URL" >/dev/null 2>&1; "$CAST" rpc evm_mine --rpc-url "$RPC_URL" >/dev/null 2>&1; }
grab() { grep -oE "$1: +0x[a-fA-F0-9]{40}" <<<"$DEPLOY_OUT" | grep -oE "0x[a-fA-F0-9]{40}" | head -1; }

run_keeper() {
  local staleness="$1" logf="$2"
  ( cd "$OPS_DIR" && timeout 60 env \
    RPC_URL="$RPC_URL" CHAIN_ID=31337 \
    ORACLE="$ORACLE" VAULT="$VAULT" POOL="$POOL" LIQUIDATION_ENGINE="$ENGINE" INSURANCE="$INSURANCE" TGAUX="$TGAUX" \
    KEEPER_PRIVATE_KEY="$KEY" KEEPER_DRY_RUN=false KEEPER_ONCE=true \
    ORACLE_MAX_STALENESS_SECONDS="$staleness" KEEPER_POLL_SECONDS=3600 LOG_FORMAT=pretty \
    node_modules/.bin/tsx src/keeper.ts ) >"$logf" 2>&1
}

step "1/7 start anvil"
# Bind 0.0.0.0 so the graph-node container (WITH_SUBGRAPH=1) can reach it via
# host.docker.internal; the default 127.0.0.1 bind is loopback-only.
"$ANVIL" --port "$ANVIL_PORT" --host "${ANVIL_HOST:-0.0.0.0}" --silent >"$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
until "$CAST" block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; do sleep 0.3; done
green "  anvil up (pid $ANVIL_PID)"

step "2/7 deploy protocol"
DEPLOY_OUT="$("$FORGE" script "$ROOT/script/DeployLocal.s.sol:DeployLocal" --rpc-url "$RPC_URL" --broadcast 2>&1)"
ORACLE="$(grab 'OracleAggregator')"
POOL="$(grab 'LiquidityPool')"
VAULT="$(grab 'VaultManager')"
ENGINE="$(grab 'LiquidationEngine')"
INSURANCE="$(grab 'InsuranceFund')"
TGAUX="$(grab 'TGAUX')"
USDC="$(grab 'USDC')"
if [ -z "$ORACLE" ] || [ -z "$ENGINE" ] || [ -z "$VAULT" ]; then
  red "  deploy parse failed"; echo "$DEPLOY_OUT" | tail -20; exit 1
fi
CHAINLINK="$(call "$ORACLE" 'chainlinkOracle()(address)')"
BAND="$(call "$ORACLE" 'bandOracle()(address)')"
API3="$(call "$ORACLE" 'api3Oracle()(address)')"
green "  vault=$VAULT engine=$ENGINE"

step "3/7 fund pool and open ${LEVERAGE}x position"
FUND=100000000000
send "$USDC" "approve(address,uint256)" "$POOL" "$FUND"
send "$POOL" "depositLP(uint256,uint8,address)" "$FUND" 0 "$USDC"
send "$USDC" "approve(address,uint256)" "$VAULT" "$COLLATERAL"
send "$VAULT" "openPosition(uint256,uint256,address)" "$COLLATERAL" "$LEVERAGE" "$USDC"
assert "position is active" "$(call "$VAULT" 'getPosition(uint256)(address,uint256,address,uint256,uint256,uint256,uint256,uint256,bool)' "$POS_ID" | tail -1)" "true"

step "4/7 drive price up two 4% steps"
price=$GOLD_8DEC
for i in 1 2; do
  price=$(( price * 104 / 100 ))
  big="${price}0000000000"
  send "$CHAINLINK" "setLatestAnswer(int256)" "$price"
  send "$BAND" "setReferenceData(uint256)" "$big"
  send "$API3" "setValue(int224)" "$big"
  mine 601
  send "$ORACLE" "updateTwap()"
done
assert "position is liquidatable" "$(call "$VAULT" 'isLiquidatable(uint256)(bool)' "$POS_ID")" "true"

step "5/7 keeper tick 1 (expect auto-mark)"
run_keeper 30 "$LOG_DIR/keeper1.log"
sed 's/^/    /' "$LOG_DIR/keeper1.log"
assert "position is marked" "$(call "$ENGINE" 'getPositionLiquidationInfo(uint256)((bool,uint256,uint256,uint256,bool))' "$POS_ID" | head -1 | tr -d '()' | cut -d',' -f1)" "true"

step "6/7 advance past grace, keeper tick 2 (expect liquidation)"
mine 660
run_keeper 30 "$LOG_DIR/keeper2.log"
sed 's/^/    /' "$LOG_DIR/keeper2.log"
assert "keeper sent perform_upkeep" "$(grep -c 'perform_upkeep.*success' "$LOG_DIR/keeper2.log" | head -1 | grep -qE '[1-9]' && echo yes || echo no)" "yes"
assert "position fully liquidated (inactive)" "$(call "$VAULT" 'getPosition(uint256)(address,uint256,address,uint256,uint256,uint256,uint256,uint256,bool)' "$POS_ID" | tail -1)" "false"
assert "borrowed fully repaid" "$(call "$VAULT" 'getPosition(uint256)(address,uint256,address,uint256,uint256,uint256,uint256,uint256,bool)' "$POS_ID" | sed -n '5p')" "0"

step "7/7 subgraph indexing"
if [ "$WITH_SUBGRAPH" = "1" ]; then
  "$ROOT/tools/ops/test/e2e-subgraph.sh" "$ORACLE" "$VAULT" "$ENGINE" "$POOL" "$INSURANCE" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
else
  echo "  SKIP (set WITH_SUBGRAPH=1 to deploy graph-node and assert indexing)"
fi

printf '\n\033[1m== result: %d passed, %d failed ==\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
