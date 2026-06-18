# Tetra Gold ops

Production operations for a live deployment: a **keeper** that keeps the protocol
running, an **exporter** that publishes protocol state as Prometheus metrics, a
**read API** that serves protocol data to frontends and customers, and a
**monitoring stack** (Prometheus + Alertmanager + Grafana) with ready-made alert
rules. Declarative **Defender** and **Tenderly** alert definitions are included
for teams that prefer on-chain alerting services.

This is the operational layer around the contracts. The read-only
`tools/monitor/dashboard.sh` is still useful for eyeballing a local node; this
package is what you run in production.

## Components

| Component | Entry | Holds keys | Purpose |
|---|---|---|---|
| Keeper | `src/keeper.ts` | yes (gas only) | Refresh oracle TWAP; mark + liquidate positions |
| Exporter | `src/exporter.ts` | no | Publish protocol state on `/metrics` (`:9102`) |
| API | `src/api.ts` | no | Public read API on `:8080` (live chain + subgraph) |
| Monitoring | `monitoring/docker-compose.yml` | no | Prometheus + Alertmanager + Grafana |

## What the keeper does

Both duties are permissionless on-chain calls, so the keeper account needs only
gas - no protocol roles:

- **Oracle freshness.** `OracleAggregator.updateTwap()` must be called externally
  or the cached price goes stale. The keeper refreshes once the price ages past
  `ORACLE_MAX_STALENESS_SECONDS`, never sooner than the on-chain
  `MIN_UPDATE_INTERVAL`.
- **Liquidations.** `checkUpkeep()` reports positions needing action;
  `performUpkeep()` auto-marks newly-underwater positions (starting their grace
  period) and liquidates those past grace. The keeper loops `performUpkeep` to
  drain backlogs larger than the per-call cap (10).

It is **dry-run by default** (`KEEPER_DRY_RUN=true`): it logs intended actions
and sends nothing. Set `false` only with a funded, dedicated key.

## Setup

```bash
cd tools/ops
cp .env.example .env        # fill in RPC_URL and contract addresses
npm install
```

For a local node, the address file written by `tools/monitor/start-local.sh`
provides the addresses; copy them into `.env` (keeper/exporter use upper-case
names: `LIQUIDATION_ENGINE` etc).

## Run (without Docker)

```bash
npm run exporter            # serves metrics on :9102
npm run keeper              # dry-run by default; serves its own metrics on :9101
```

## Read API

`src/api.ts` is the serving tier a frontend, analytics dashboard, or customer
integration consumes. It merges two sources: **live** on-chain state (via the
same `readSnapshot` the exporter uses, cached `API_CACHE_TTL_SECONDS`) and
**indexed** history from the subgraph (`API_SUBGRAPH_URL`). Zero web-framework
dependencies - raw Node `http`, native `fetch`.

```bash
npm run api                 # serves on :8080 (API_PORT)
```

Auth is API-key based: send `Authorization: Bearer <key>` or `x-api-key: <key>`,
with keys in `API_KEYS` (comma-separated). `/v1/*` requires a key; rate limited
per key (`API_RATE_LIMIT_MAX` per `API_RATE_LIMIT_WINDOW_SECONDS`, returning 429
with `Retry-After`). Set `API_AUTH_DISABLED=true` for local dev only.

| Method + path | Auth | Source | Returns |
|---|---|---|---|
| `GET /health` | no | - | liveness |
| `GET /ready` | no | rpc + subgraph | readiness with per-backend checks |
| `GET /metrics` | no | - | Prometheus metrics (`tetragold_api_*`) |
| `GET /v1/overview` | yes | live + indexed | snapshot + protocol aggregates |
| `GET /v1/oracle` | yes | live | gold price, age, paused |
| `GET /v1/pools` | yes | live | per-pool deposits/borrowed/utilization |
| `GET /v1/insurance` | yes | live | reserves, target, health |
| `GET /v1/positions` | yes | subgraph | list (`status`, `owner`, `first`, `skip`, `orderBy`) |
| `GET /v1/positions/:id` | yes | subgraph + live | indexed record + live health/liquidatable |
| `GET /v1/liquidations` | yes | subgraph | recent liquidations (`first`, `skip`) |
| `GET /v1/stats/daily` | yes | subgraph | per-day aggregates (`first`) |
| `POST /v1/graphql` | yes | subgraph | passthrough (disable with `API_GRAPHQL_PASSTHROUGH=false`) |

Errors are JSON `{ "error": { "code", "message" } }`; subgraph failures surface
as `502`. Every response carries `x-request-id`. Tighten `API_CORS_ORIGIN` to
your frontend origin in production. The limiter is in-memory (single instance) -
front it with a shared store before scaling horizontally.

Smoke test (boots anvil, exercises auth/limits/live endpoints):

```bash
test/smoke-api.sh
```

## Run the full stack (Docker)

```bash
docker compose -f monitoring/docker-compose.yml up -d --build
```

- Grafana: http://localhost:3000 (admin/admin), dashboard "Tetra Gold - Protocol Overview"
- Prometheus: http://localhost:9090 (Alerts tab shows rule state)
- Alertmanager: http://localhost:9093

When the stack runs in Docker but your chain (anvil/node) runs on the host, set
`RPC_URL=http://host.docker.internal:8545` in `.env`.

## Alerts

Prometheus rules live in `monitoring/prometheus/alerts.yml`, grouped by oracle,
protocol, insurance, keeper, and exporter. They cover oracle staleness and pause,
circuit breaker, liquidatable backlog not being cleared, weak position health,
high pool utilization, insurance fund CRITICAL/WARNING and undercollateralization,
keeper down/stalled/low-gas/dry-run, and exporter liveness.

Wire notifications in `monitoring/alertmanager/alertmanager.yml` (PagerDuty for
critical, Slack for warning - placeholders to replace). Equivalent on-chain
alert definitions are in `monitoring/defender/monitors.json` and
`monitoring/tenderly/alerts.yaml`.

## Metrics

`tetragold_*` gauges/counters from both processes. Notable ones:
`tetragold_oracle_price_age_seconds`, `tetragold_oracle_paused`,
`tetragold_liquidatable_positions`, `tetragold_position_health_min_ratio`,
`tetragold_insurance_health`, `tetragold_keeper_last_tick_timestamp`,
`tetragold_keeper_balance_wei`, `tetragold_keeper_actions_total`. The API adds
`tetragold_api_requests_total`, `tetragold_api_request_duration_seconds`,
`tetragold_api_rate_limited_total`, and `tetragold_api_auth_failures_total` on
its own `/metrics`.

## Security notes

- Never commit a real `KEEPER_PRIVATE_KEY`. Use a secrets manager and inject at
  runtime. Use a dedicated EOA funded only with gas.
- The keeper requires no protocol roles; do not grant it any.
- Keep `KEEPER_DRY_RUN=true` until you have verified behaviour against a testnet.
