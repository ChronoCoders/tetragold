#!/usr/bin/env bash
# Subgraph indexing phase of the e2e liquidation test. Invoked by
# e2e-liquidation.sh when WITH_SUBGRAPH=1, with the live contract addresses:
#   e2e-subgraph.sh <ORACLE> <VAULT> <ENGINE> <POOL> <INSURANCE>
# Spins up the local graph-node stack, deploys the subgraph against the running
# anvil chain, waits for it to sync, and asserts the liquidated position was
# indexed (status LIQUIDATED, all tranches, liquidation + mark entities).
set -uo pipefail

ORACLE="${1:?ORACLE address required}"
VAULT="${2:?VAULT address required}"
ENGINE="${3:?ENGINE address required}"
POOL="${4:?POOL address required}"
INSURANCE="${5:?INSURANCE address required}"

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$OPS_DIR/../.." && pwd)"
SG="$ROOT/subgraph"

RPC_URL="${RPC_URL:-http://localhost:8545}"
NAME="tetragold/tetragold"
GRAPH="$SG/node_modules/.bin/graph"
SYNC_TIMEOUT="${SUBGRAPH_SYNC_TIMEOUT:-180}"
KEEP_STACK="${SUBGRAPH_KEEP_STACK:-0}"

PASS=0; FAIL=0
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
sub()   { printf '\n\033[1m-- subgraph: %s\033[0m\n' "$1"; }
assert() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then green "  PASS: $desc"; PASS=$((PASS+1));
  else red "  FAIL: $desc (got '$got', want '$want')"; FAIL=$((FAIL+1)); fi
}

command -v docker >/dev/null 2>&1 || { red "  docker not found (required for WITH_SUBGRAPH=1)"; exit 1; }
command -v curl   >/dev/null 2>&1 || { red "  curl not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { red "  python3 not found"; exit 1; }
docker info >/dev/null 2>&1 || { red "  docker daemon not reachable"; exit 1; }

# Pick host ports that are actually free (another stack may already hold the
# graph-node defaults). Container-internal ports are unchanged; only the
# published host ports are remapped, via the compose ${..} overrides.
pick_port() { python3 -c '
import socket, sys
p = int(sys.argv[1])
while p < 65535:
    s = socket.socket()
    try:
        s.bind(("0.0.0.0", p)); print(p); break
    except OSError:
        p += 1
    finally:
        s.close()
' "$1"; }
export GRAPH_PORT_GQL="$(pick_port "${GRAPH_PORT_GQL:-18000}")"
export GRAPH_PORT_GQLWS="$(pick_port "${GRAPH_PORT_GQLWS:-18001}")"
export GRAPH_PORT_ADMIN="$(pick_port "${GRAPH_PORT_ADMIN:-18020}")"
export GRAPH_PORT_STATUS="$(pick_port "${GRAPH_PORT_STATUS:-18030}")"
export IPFS_PORT="$(pick_port "${IPFS_PORT:-15001}")"
export PG_PORT="$(pick_port "${PG_PORT:-15432}")"
ADMIN="http://localhost:$GRAPH_PORT_ADMIN"
IPFS="http://localhost:$IPFS_PORT"
STATUS="http://localhost:$GRAPH_PORT_STATUS/graphql"
QUERY="http://localhost:$GRAPH_PORT_GQL/subgraphs/name/tetragold/tetragold"

rpc() {
  curl -s -X POST "$RPC_URL" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}"
}
block_number() {
  rpc eth_blockNumber | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))'
}
gql() {
  local url="$1" q="$2"
  python3 - "$url" "$q" <<'PY'
import sys, json, urllib.request
url, q = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, data=json.dumps({"query": q}).encode(),
                             headers={"content-type": "application/json"})
try:
    print(urllib.request.urlopen(req, timeout=10).read().decode())
except Exception as e:
    print(json.dumps({"errors": [{"message": str(e)}]}))
PY
}
jget() { python3 -c 'import sys,json;d=json.load(sys.stdin)
try:
  v=d
  for k in sys.argv[1].split("."):
    v = v[int(k)] if isinstance(v,list) else v.get(k)
    if v is None: break
  print("" if v is None else v)
except Exception:
  print("")' "$1"; }

NET_BAK="$(mktemp)"; YAML_BAK="$(mktemp)"
cp "$SG/networks.json" "$NET_BAK"
cp "$SG/subgraph.yaml" "$YAML_BAK"
cleanup() {
  cp "$NET_BAK" "$SG/networks.json"; cp "$YAML_BAK" "$SG/subgraph.yaml"
  rm -f "$NET_BAK" "$YAML_BAK"
  if [ "$KEEP_STACK" != "1" ]; then
    ( cd "$SG" && docker compose down -v >/dev/null 2>&1 )
  fi
}
trap cleanup EXIT INT TERM

sub "1/6 point networks.json at the live deployment"
DEPLOY_BLOCK="$(block_number)"
python3 - "$SG/networks.json" "$VAULT" "$ENGINE" "$ORACLE" "$POOL" "$INSURANCE" "$DEPLOY_BLOCK" <<'PY'
import sys, json
path, vault, engine, oracle, pool, ins, blk = sys.argv[1:8]
blk = int(blk)
with open(path) as f: net = json.load(f)
loc = net.setdefault("localhost", {})
addrs = {"VaultManager": vault, "LiquidationEngine": engine, "OracleAggregator": oracle,
         "LiquidityPool": pool, "InsuranceFund": ins}
for k, v in addrs.items():
    loc[k] = {"address": v, "startBlock": 0}
with open(path, "w") as f: json.dump(net, f, indent=2)
print(f"  networks.json localhost set (deploy head block {blk})")
PY

sub "2/6 start graph-node stack"
green "  ports: gql=$GRAPH_PORT_GQL admin=$GRAPH_PORT_ADMIN status=$GRAPH_PORT_STATUS ipfs=$IPFS_PORT pg=$PG_PORT"
( cd "$SG" && docker compose up -d ) >/dev/null 2>&1 \
  || { red "  docker compose up failed"; ( cd "$SG" && docker compose up -d 2>&1 | tail -10 ); exit 1; }
wait_http() {
  local url="$1" name="$2" deadline=$(( $(date +%s) + 180 ))
  until [ "$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" != "000" ]; do
    [ "$(date +%s)" -gt "$deadline" ] && { red "  timeout waiting for $name ($url)"; return 1; }
    sleep 2
  done
}
wait_http "$IPFS/api/v0/version" "ipfs" || exit 1
wait_http "$STATUS" "graph-node status" || exit 1
wait_http "$ADMIN" "graph-node admin" || exit 1
green "  graph-node up"

sub "3/6 codegen + build (network=localhost)"
( cd "$SG" && "$GRAPH" codegen >/dev/null 2>&1 && "$GRAPH" build --network localhost >/dev/null 2>&1 ) \
  || { red "  graph codegen/build failed"; ( cd "$SG" && "$GRAPH" build --network localhost 2>&1 | tail -15 ); exit 1; }
green "  build ok"

sub "4/6 create + deploy subgraph"
( cd "$SG" && "$GRAPH" create --node "$ADMIN/" "$NAME" ) >/dev/null 2>&1 || true
( cd "$SG" && "$GRAPH" deploy --node "$ADMIN/" --ipfs "$IPFS" --version-label e2e "$NAME" ) >/dev/null 2>&1 \
  || { red "  graph deploy failed"; ( cd "$SG" && "$GRAPH" deploy --node "$ADMIN/" --ipfs "$IPFS" --version-label e2e "$NAME" 2>&1 | tail -15 ); exit 1; }
green "  deployed"

sub "5/6 wait for sync to chain head"
# advance the head a few blocks so the liquidation block is comfortably below it
for _ in 1 2 3; do rpc evm_mine >/dev/null; done
TARGET="$(block_number)"
SYNC_Q='{ indexingStatusForCurrentVersion(subgraphName:"tetragold/tetragold"){ synced health chains { latestBlock { number } chainHeadBlock { number } } fatalError { message } } }'
deadline=$(( $(date +%s) + SYNC_TIMEOUT ))
synced=no
while [ "$(date +%s)" -le "$deadline" ]; do
  resp="$(gql "$STATUS" "$SYNC_Q")"
  health="$(echo "$resp" | jget data.indexingStatusForCurrentVersion.health)"
  latest="$(echo "$resp" | jget data.indexingStatusForCurrentVersion.chains.0.latestBlock.number)"
  fatal="$(echo "$resp" | jget data.indexingStatusForCurrentVersion.fatalError.message)"
  if [ "$health" = "failed" ] || [ -n "$fatal" ]; then
    red "  indexing failed: ${fatal:-unknown}"; FAIL=$((FAIL+1)); break
  fi
  if [ -n "$latest" ] && [ "$latest" -ge "$TARGET" ] 2>/dev/null; then synced=yes; break; fi
  sleep 2
done
assert "subgraph synced to head (>= block $TARGET)" "$synced" "yes"
[ "$synced" = "yes" ] || { printf '\n\033[1m-- subgraph result: %d passed, %d failed --\033[0m\n' "$PASS" "$FAIL"; exit 1; }

sub "6/6 assert indexed liquidation"
POS_Q='{ position(id:"1"){ status tranchesLiquidated borrowedAmount liquidations(first:10){ id penalty } marks{ id markedTime } } protocol(id:"tetragold"){ totalPositionsLiquidated totalLiquidations } }'
resp="$(gql "$QUERY" "$POS_Q")"
echo "$resp" | python3 -m json.tool 2>/dev/null | sed 's/^/    /' | head -40

status="$(echo "$resp"   | jget data.position.status)"
tranches="$(echo "$resp" | jget data.position.tranchesLiquidated)"
liqcount="$(echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(((d.get("data") or {}).get("position") or {}).get("liquidations") or []))')"
markcount="$(echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(((d.get("data") or {}).get("position") or {}).get("marks") or []))')"
totalLiq="$(echo "$resp"  | jget data.protocol.totalPositionsLiquidated)"

assert "position 1 indexed as LIQUIDATED" "$status" "LIQUIDATED"
assert "all 4 tranches recorded" "$tranches" "4"
assert "liquidation entities indexed" "$([ "${liqcount:-0}" -ge 1 ] && echo yes || echo no)" "yes"
assert "liquidation mark indexed" "$([ "${markcount:-0}" -ge 1 ] && echo yes || echo no)" "yes"
assert "protocol counts one liquidation" "$totalLiq" "1"

printf '\n\033[1m-- subgraph result: %d passed, %d failed --\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
