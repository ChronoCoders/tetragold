# Tetra Gold subgraph

A [Graph Protocol](https://thegraph.com) subgraph that indexes the Tetra Gold
contracts into a GraphQL API: positions and their lifecycle, liquidations and
marks, oracle prices and circuit-breaker trips, LP pool activity, insurance fund
events, fees, and protocol/user/day-level aggregates.

This is the read layer a frontend, analytics, or notification service queries -
the on-chain state cannot be read historically with `cast` or the exporter.

## Indexed sources

| Contract | Key events |
|---|---|
| VaultManager | PositionOpened/Closed/CollateralAdded/Liquidated, BadDebtRealized |
| LiquidationEngine | PositionLiquidated (tranches), Marked, MarkCleared |
| OracleAggregator | PriceUpdated, CircuitBreakerTriggered |
| LiquidityPool | LPDeposit/Withdrawal, Borrowed, Repaid, UtilizationUpdated |
| InsuranceFund | FundsDeposited, CoverageProvided, FundHealthUpdated, Rebalanced |
| FeeDistributor | FeesCollected |

Position rows are enriched with `openPrice`, `collateralToken`, and
`borrowedAmount` via a `getPosition` call in the open handler (the event itself
omits them).

## Configure addresses

`networks.json` holds per-network addresses and deploy blocks. Fill them in (set
`startBlock` to the contract's deploy block so indexing does not scan from
genesis), then build for that network:

```bash
npm install
npm run codegen
npm run build:mainnet     # or build:sepolia / build:localhost
```

`graph build --network <name>` rewrites `subgraph.yaml` from `networks.json`. The
committed `subgraph.yaml` keeps zero-address placeholders; that is expected.

## Local indexing (against anvil)

```bash
# 1. Run a local chain + deploy (writes tools/monitor/addresses.env)
tools/monitor/start-local.sh --deploy-only

# 2. Put those addresses into subgraph/networks.json under "localhost"
#    (they match the anvil DeployLocal defaults already seeded there)

# 3. Start graph-node + ipfs + postgres
cd subgraph && docker compose up -d

# 4. Build, create, and deploy the subgraph
npm run codegen && npm run build:localhost
npm run create-local
npm run deploy-local

# GraphQL playground: http://localhost:8000/subgraphs/name/tetragold/tetragold
```

The published host ports default to 8000/8001/8020/8030 (graph-node), 5001
(ipfs), and 5432 (postgres). Override any that collide with another stack:
`GRAPH_PORT_GQL`, `GRAPH_PORT_GQLWS`, `GRAPH_PORT_ADMIN`, `GRAPH_PORT_STATUS`,
`IPFS_PORT`, `PG_PORT`. Note: anvil must bind `0.0.0.0` (not the default
loopback) for the graph-node container to reach it via `host.docker.internal`.

## End-to-end indexing test

`tools/ops/test/e2e-liquidation.sh` drives a position underwater, lets the keeper
liquidate it, and - with `WITH_SUBGRAPH=1` - boots this stack, deploys the
subgraph against the same anvil chain, waits for sync, and asserts the
liquidation was indexed. It picks conflict-free host ports automatically and
tears the stack down afterward:

```bash
WITH_SUBGRAPH=1 tools/ops/test/e2e-liquidation.sh
```

## Deploy to The Graph Studio

```bash
graph auth <deploy-key>
npm run build:mainnet
npm run deploy            # deploys to the "tetragold" Studio subgraph
```

## Example queries

Protocol overview and the weakest open positions:

```graphql
{
  protocol(id: "tetragold") {
    openPositionCount
    totalLiquidations
    totalBadDebt
    lastGoldPrice
    circuitBreakerTrips
  }
  positions(first: 5, where: { status: OPEN }, orderBy: leverage, orderDirection: desc) {
    positionId
    owner { id }
    leverage
    collateral
    openPrice
    tranchesLiquidated
  }
}
```

Recent liquidations with the position they hit:

```graphql
{
  liquidations(first: 10, orderBy: timestamp, orderDirection: desc) {
    liquidator
    penalty
    portion
    timestamp
    position { positionId owner { id } status }
  }
}
```

Daily activity:

```graphql
{
  protocolDayDatas(first: 14, orderBy: date, orderDirection: desc) {
    date
    positionsOpened
    positionsLiquidated
    penalties
    goldPriceClose
  }
}
```

## Notes

- `LiquidationMark` keeps one record per position (id == positionId); a re-mark
  overwrites the prior record, since the clear event carries only the positionId.
- A position partially liquidated across tranches stays `OPEN` until the settling
  tranche (`portion == 10000` or the 4-tranche cap), then becomes `LIQUIDATED`.
- USD amounts are 6-decimal, gold price 8-decimal, TGAUX 18-decimal (see the
  root `CLAUDE.md`). The subgraph stores raw integers; scale in the client.
