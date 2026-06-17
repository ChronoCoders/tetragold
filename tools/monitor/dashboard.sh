#!/usr/bin/env bash
#
# Tetra Gold live protocol monitor.
#
# A terminal dashboard that polls a running deployment with `cast` and renders
# protocol state on a refresh loop: oracle price, liquidity pools, open
# positions and their health, and the insurance fund.
#
# Configuration is read from the environment (or an addresses file you source
# first). Required:
#   RPC_URL    JSON-RPC endpoint            (default http://localhost:8545)
#   ORACLE     OracleAggregator address
#   POOL       LiquidityPool address
#   VAULT      VaultManager address
#   INSURANCE  InsuranceFund address
#   TGAUX      TGAUX token address
# Optional:
#   INTERVAL   refresh seconds              (default 5)
#
# Usage:
#   source tools/monitor/addresses.env && tools/monitor/dashboard.sh
#   tools/monitor/dashboard.sh --once      # render a single frame and exit
#
set -uo pipefail

RPC_URL="${RPC_URL:-http://localhost:8545}"
INTERVAL="${INTERVAL:-5}"
ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1

CAST="${CAST:-$HOME/.foundry/bin/cast}"
command -v "$CAST" >/dev/null 2>&1 || CAST=cast

# Colors
B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'

need() { [ -n "${!1:-}" ] || { echo "config error: \$$1 is not set" >&2; exit 1; }; }
need ORACLE; need POOL; need VAULT; need INSURANCE; need TGAUX

# cast call helper: $1 address, $2 "sig(returns)", $3.. args. Echoes decoded
# return value(s), one per line, or nothing on failure. The trailing
# scientific annotation cast adds to integers (e.g. "200000000000 [2e11]") is
# stripped so values are usable in shell arithmetic; array output "[1, 2]"
# (no leading space before the bracket) is left intact.
call() {
  local addr="$1" sig="$2"; shift 2
  "$CAST" call "$addr" "$sig" "$@" --rpc-url "$RPC_URL" 2>/dev/null | sed -E 's/ \[[^][]*\]//g'
}

# Format a fixed-point integer for display: fmt <value> <decimals> [precision]
fmt() {
  local v="${1:-}" dec="$2" prec="${3:-2}"
  [ -n "$v" ] || { echo "n/a"; return; }
  awk -v v="$v" -v d="$dec" -v p="$prec" 'BEGIN{ printf "%.*f", p, v / (10 ^ d) }'
}

fund_health_label() {
  case "${1:-}" in
    0) echo "${RED}CRITICAL${R}" ;;
    1) echo "${YEL}WARNING${R}" ;;
    2) echo "${GRN}HEALTHY${R}" ;;
    3) echo "${CYN}OVERCAPITALIZED${R}" ;;
    *) echo "n/a" ;;
  esac
}

RULE="  ------------------------------------------------------------"

render() {
  local now block
  now=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  block=$("$CAST" block-number --rpc-url "$RPC_URL" 2>/dev/null || echo "n/a")

  printf '%s' $'\033[H\033[2J'
  echo "${B}  TETRA GOLD  -  live protocol monitor${R}"
  echo "${DIM}  rpc ${RPC_URL}   block ${block}   ${now}   refresh ${INTERVAL}s${R}"
  echo "$RULE"

  # ---- Oracle ----
  local price ut paused age
  price=$(call "$ORACLE" "lastPrice()(uint256)")
  ut=$(call "$ORACLE" "lastUpdateTime()(uint256)")
  paused=$(call "$ORACLE" "paused()(bool)")
  age="n/a"
  [[ "${ut:-}" =~ ^[0-9]+$ ]] && age="$(( $(date +%s) - ut ))s ago"
  local pstr="${GRN}live${R}"; [ "$paused" = "true" ] && pstr="${RED}PAUSED${R}"
  printf "  %-9s gold ${B}\$%s${R}/oz   updated %s   %b\n" "ORACLE" "$(fmt "$price" 8)" "$age" "$pstr"
  echo "$RULE"

  # ---- Liquidity pools ----
  echo "  ${B}LIQUIDITY POOLS${R}"
  printf "    %-12s %14s %14s %8s\n" "pool" "deposits" "borrowed" "util"
  local pid name dep bor util rest
  for pid in 0 1; do
    name=$([ "$pid" = 0 ] && echo CONSERVATIVE || echo AGGRESSIVE)
    { read -r dep; read -r bor; read -r util; read -r rest; } < <(
      call "$POOL" "getPoolInfo(uint8)(uint256,uint256,uint256,address,uint256)" "$pid")
    printf "    %-12s %14s %14s %7s%%\n" "$name" "$(fmt "$dep" 6 0)" "$(fmt "$bor" 6 0)" "$(fmt "$util" 2 1)"
  done
  echo "$RULE"

  # ---- VaultManager + positions ----
  local tvl count nextId
  tvl=$(call "$VAULT" "totalValueLocked()(uint256)")
  count=$(call "$VAULT" "activePositionCount()(uint256)")
  nextId=$(call "$VAULT" "nextPositionId()(uint256)")
  printf "  %-9s TVL ${B}\$%s${R}   active positions %s   next id %s\n" \
    "VAULT" "$(fmt "$tvl" 6 0)" "${count:-n/a}" "${nextId:-n/a}"

  local ids id health liq lev owner col owstr hpct flag
  ids=$(call "$VAULT" "getActivePositionIds()(uint256[])" | tr -d '[]"' | tr ',' ' ')
  if [ -n "$ids" ]; then
    printf "    %-4s %-14s %-5s %8s   %s\n" "id" "owner" "lev" "health" "status"
    for id in $ids; do
      [ -n "$id" ] || continue
      health=$(call "$VAULT" "getPositionHealth(uint256)(uint256)" "$id")
      liq=$(call "$VAULT" "isLiquidatable(uint256)(bool)" "$id")
      { read -r owner; read -r col; read -r _ct; read -r _tg; read -r _bo; read -r lev; read -r _op; read -r _ts; read -r _act; } < <(
        call "$VAULT" "getPosition(uint256)(address,uint256,address,uint256,uint256,uint256,uint256,uint256,bool)" "$id")
      owstr="${owner:0:6}..${owner: -4}"
      hpct=$(fmt "$health" 2 1)
      if [ "$liq" = "true" ]; then flag="${RED}LIQUIDATABLE${R}"; else flag="${GRN}ok${R}"; fi
      # status is the last column, so the color codes do not affect alignment
      printf "    %-4s %-14s %-5s %7s%%   %b\n" "$id" "$owstr" "${lev:-?}x" "$hpct" "$flag"
    done
  fi
  echo "$RULE"

  # ---- Insurance fund ----
  local res tgt fh supply
  res=$(call "$INSURANCE" "getTotalReserves()(uint256)")
  tgt=$(call "$INSURANCE" "getTargetReserve()(uint256)")
  fh=$(call "$INSURANCE" "getFundHealth()(uint8)")
  supply=$(call "$TGAUX" "totalSupply()(uint256)")
  printf "  %-9s reserves ${B}\$%s${R}   target \$%s   status %b\n" \
    "INSURANCE" "$(fmt "$res" 6 0)" "$(fmt "$tgt" 6 0)" "$(fund_health_label "$fh")"
  printf "  %-9s supply ${B}%s${R}\n" "TGAUX" "$(fmt "$supply" 18 4)"
  echo "$RULE"
  echo "${DIM}  Ctrl-C to exit${R}"
}

if [ "$ONCE" = 1 ]; then
  render
  exit 0
fi

trap 'printf "\033[?25h\n"; exit 0' INT TERM
printf '\033[?25l'  # hide cursor
while true; do
  render
  sleep "$INTERVAL"
done
