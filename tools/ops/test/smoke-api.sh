#!/usr/bin/env bash
# Smoke test for the public read API: boots anvil + DeployLocal, seeds a
# position, starts the API, and exercises auth, rate limiting, and the live
# on-chain endpoints. Subgraph-backed endpoints are checked only when a
# subgraph is already serving at API_SUBGRAPH_URL (WITH_SUBGRAPH=1).
set -uo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$OPS_DIR/../.." && pwd)"

RPC_URL="${RPC_URL:-http://localhost:8545}"
ANVIL_PORT="${ANVIL_PORT:-8545}"
KEY="${KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
API_PORT="${API_PORT:-8088}"
APIKEY="smoke-test-key"
BASE="http://localhost:$API_PORT"

FORGE="${FORGE:-$HOME/.foundry/bin/forge}"; command -v "$FORGE" >/dev/null 2>&1 || FORGE=forge
CAST="${CAST:-$HOME/.foundry/bin/cast}"; command -v "$CAST" >/dev/null 2>&1 || CAST=cast
ANVIL="${ANVIL:-$HOME/.foundry/bin/anvil}"; command -v "$ANVIL" >/dev/null 2>&1 || ANVIL=anvil

ANVIL_PID=""; API_PID=""
LOG_DIR="$(mktemp -d)"
PASS=0; FAIL=0

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
step()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
cleanup() {
  [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null
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
grab() { grep -oE "$1: +0x[a-fA-F0-9]{40}" <<<"$DEPLOY_OUT" | grep -oE "0x[a-fA-F0-9]{40}" | head -1; }
# code <url> [header...] -> HTTP status
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }
jfield() { python3 -c 'import sys,json;d=json.load(sys.stdin)
try:
  v=d
  for k in sys.argv[1].split("."): v=v[int(k)] if isinstance(v,list) else v.get(k)
  print("" if v is None else v)
except Exception: print("")' "$1"; }

step "1/5 start anvil + deploy"
"$ANVIL" --port "$ANVIL_PORT" --host 0.0.0.0 --silent >"$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
until "$CAST" block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; do sleep 0.3; done
DEPLOY_OUT="$("$FORGE" script "$ROOT/script/DeployLocal.s.sol:DeployLocal" --rpc-url "$RPC_URL" --broadcast 2>&1)"
ORACLE="$(grab 'OracleAggregator')"; POOL="$(grab 'LiquidityPool')"; VAULT="$(grab 'VaultManager')"
ENGINE="$(grab 'LiquidationEngine')"; INSURANCE="$(grab 'InsuranceFund')"; TGAUX="$(grab 'TGAUX')"; USDC="$(grab 'USDC')"
[ -n "$VAULT" ] || { red "deploy parse failed"; exit 1; }
# seed one position so /v1/positions live reads have something
send "$USDC" "approve(address,uint256)" "$POOL" 100000000000
send "$POOL" "depositLP(uint256,uint8,address)" 100000000000 0 "$USDC"
send "$USDC" "approve(address,uint256)" "$VAULT" 110000000
send "$VAULT" "openPosition(uint256,uint256,address)" 110000000 2 "$USDC"
green "  vault=$VAULT"

step "2/5 start api"
( cd "$OPS_DIR" && env \
  RPC_URL="$RPC_URL" CHAIN_ID=31337 \
  ORACLE="$ORACLE" VAULT="$VAULT" POOL="$POOL" LIQUIDATION_ENGINE="$ENGINE" INSURANCE="$INSURANCE" TGAUX="$TGAUX" \
  API_PORT="$API_PORT" API_KEYS="$APIKEY" API_RATE_LIMIT_MAX=20 API_RATE_LIMIT_WINDOW_SECONDS=60 \
  API_SUBGRAPH_URL="${API_SUBGRAPH_URL:-http://localhost:8000/subgraphs/name/tetragold/tetragold}" \
  LOG_FORMAT=pretty \
  node_modules/.bin/tsx src/api.ts ) >"$LOG_DIR/api.log" 2>&1 &
API_PID=$!
until curl -s "$BASE/health" >/dev/null 2>&1; do sleep 0.3; [ -d "/proc/$API_PID" ] || { red "api died"; cat "$LOG_DIR/api.log"; exit 1; }; done
green "  api up (pid $API_PID)"

step "3/5 health + auth"
assert "GET /health 200"                "$(code "$BASE/health")" "200"
assert "GET /metrics 200"               "$(code "$BASE/metrics")" "200"
assert "GET /v1/overview no key -> 401" "$(code "$BASE/v1/overview")" "401"
assert "GET /v1/overview bad key -> 401" "$(code -H 'x-api-key: nope' "$BASE/v1/overview")" "401"
assert "GET /v1/overview with key -> 200" "$(code -H "x-api-key: $APIKEY" "$BASE/v1/overview")" "200"
assert "Bearer scheme accepted -> 200"  "$(code -H "authorization: Bearer $APIKEY" "$BASE/v1/overview")" "200"
assert "unknown route -> 404"           "$(code -H "x-api-key: $APIKEY" "$BASE/v1/nope")" "404"
assert "wrong method -> 405"            "$(code -X DELETE -H "x-api-key: $APIKEY" "$BASE/v1/overview")" "405"

step "4/5 live endpoints"
OV="$(body -H "x-api-key: $APIKEY" "$BASE/v1/overview")"
assert "overview has gold price" "$(echo "$OV" | jfield live.goldPriceUsd | grep -qE '^[0-9]' && echo yes || echo no)" "yes"
assert "oracle endpoint paused=false" "$(body -H "x-api-key: $APIKEY" "$BASE/v1/oracle" | jfield paused)" "False"
assert "pools endpoint lists 2 pools" "$(body -H "x-api-key: $APIKEY" "$BASE/v1/pools" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["pools"]))')" "2"
assert "insurance has healthLabel" "$(body -H "x-api-key: $APIKEY" "$BASE/v1/insurance" | jfield healthLabel | grep -qE '[A-Z]' && echo yes || echo no)" "yes"

# /v1/positions/:id merges indexed (subgraph) + live (chain). Test the live
# path when a subgraph is serving, otherwise assert the 502 degradation.
SG_URL="${API_SUBGRAPH_URL:-http://localhost:8000/subgraphs/name/tetragold/tetragold}"
if curl -s -m 3 -X POST "$SG_URL" -H 'content-type: application/json' -d '{"query":"{_meta{block{number}}}"}' 2>/dev/null | grep -q '"data"'; then
  assert "position 1 live enriched" "$(body -H "x-api-key: $APIKEY" "$BASE/v1/positions/1" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("yes" if d.get("live") and "isLiquidatable" in d["live"] else "no")' 2>/dev/null || echo no)" "yes"
else
  assert "position 1 -> 502 when subgraph down" "$(code -H "x-api-key: $APIKEY" "$BASE/v1/positions/1")" "502"
  assert "502 carries a subgraph error code" "$(body -H "x-api-key: $APIKEY" "$BASE/v1/positions/1" | jfield error.code | grep -q '^subgraph' && echo yes || echo no)" "yes"
fi

step "5/5 rate limiting (limit=20/window)"
# already spent a handful of authed requests; keep hitting until 429 appears
rl=no
for _ in $(seq 1 30); do
  c="$(code -H "x-api-key: $APIKEY" "$BASE/v1/oracle")"
  [ "$c" = "429" ] && { rl=yes; break; }
done
assert "rate limit returns 429" "$rl" "yes"
assert "429 carries Retry-After" "$(curl -s -D - -o /dev/null -H "x-api-key: $APIKEY" "$BASE/v1/oracle" | grep -ic '^retry-after:' )" "1"

printf '\n\033[1m== api smoke: %d passed, %d failed ==\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
