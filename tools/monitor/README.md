# Live protocol monitor

A terminal dashboard that polls a running Tetra Gold deployment with `cast` and
renders protocol state on a refresh loop: oracle price, liquidity pools, open
positions with their health and liquidation status, and the insurance fund.

It is a read-only operations/inspection tool, not a test harness — correctness
is covered by the Foundry suite (`forge test`). Use this to watch state change
as you interact with a local or testnet deployment.

## Quick start (local)

```bash
# Starts anvil, deploys the full stack, captures addresses, launches the UI.
tools/monitor/start-local.sh
```

Then, in another terminal, drive the protocol with `cast` and watch the
dashboard update — for example, open a 1x position from anvil account 0:

```bash
source tools/monitor/addresses.env
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
cast send "$USDC"  "approve(address,uint256)" "$VAULT" 4500000000 --private-key $KEY --rpc-url "$RPC_URL"
cast send "$VAULT" "openPosition(uint256,uint256,address)" 4500000000 1 "$USDC" --private-key $KEY --rpc-url "$RPC_URL"
```

## Pointing at an existing deployment

Set the addresses yourself (e.g. a testnet) and run the dashboard directly:

```bash
export RPC_URL=https://your-rpc
export ORACLE=0x... POOL=0x... VAULT=0x... INSURANCE=0x... TGAUX=0x...
export INTERVAL=10        # optional, default 5s
tools/monitor/dashboard.sh
```

`tools/monitor/dashboard.sh --once` renders a single frame and exits (useful for
scripting or a quick check).

## Requirements

Foundry (`cast`, and `anvil`/`forge` for the local launcher). No other
dependencies — the dashboard is plain `bash` + `cast`.
