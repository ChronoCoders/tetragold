import http from "node:http";
import { Registry, Counter, Gauge, collectDefaultMetrics } from "prom-client";
import { log } from "./logger.js";

export const registry = new Registry();
collectDefaultMetrics({ register: registry, prefix: "tetragold_ops_" });

export const goldPrice = new Gauge({
  name: "tetragold_gold_price_usd",
  help: "Oracle cached gold price in USD (8-decimal value scaled to a float).",
  registers: [registry],
});
export const oraclePriceAge = new Gauge({
  name: "tetragold_oracle_price_age_seconds",
  help: "Seconds since the oracle TWAP was last updated.",
  registers: [registry],
});
export const oraclePaused = new Gauge({
  name: "tetragold_oracle_paused",
  help: "1 if the OracleAggregator is paused (circuit breaker or admin), else 0.",
  registers: [registry],
});
export const contractPaused = new Gauge({
  name: "tetragold_contract_paused",
  help: "1 if the named contract is paused, else 0.",
  labelNames: ["contract"],
  registers: [registry],
});
export const tvlUsd = new Gauge({
  name: "tetragold_tvl_usd",
  help: "VaultManager total value locked in USD.",
  registers: [registry],
});
export const activePositions = new Gauge({
  name: "tetragold_active_positions",
  help: "Number of active positions.",
  registers: [registry],
});
export const liquidatablePositions = new Gauge({
  name: "tetragold_liquidatable_positions",
  help: "Number of positions currently liquidatable (backlog the keeper must clear).",
  registers: [registry],
});
export const positionHealthMin = new Gauge({
  name: "tetragold_position_health_min_ratio",
  help: "Lowest health ratio across active positions (basis-point ratio scaled to a float, 1.0 == 100%).",
  registers: [registry],
});
export const poolDeposits = new Gauge({
  name: "tetragold_pool_deposits_usd",
  help: "LP deposits per pool in USD.",
  labelNames: ["pool"],
  registers: [registry],
});
export const poolBorrowed = new Gauge({
  name: "tetragold_pool_borrowed_usd",
  help: "Borrowed amount per pool in USD.",
  labelNames: ["pool"],
  registers: [registry],
});
export const poolUtilization = new Gauge({
  name: "tetragold_pool_utilization_ratio",
  help: "Utilization per pool (0..1).",
  labelNames: ["pool"],
  registers: [registry],
});
export const insuranceReserves = new Gauge({
  name: "tetragold_insurance_reserves_usd",
  help: "Insurance fund total reserves in USD.",
  registers: [registry],
});
export const insuranceTarget = new Gauge({
  name: "tetragold_insurance_target_usd",
  help: "Insurance fund target reserve in USD.",
  registers: [registry],
});
export const insuranceHealth = new Gauge({
  name: "tetragold_insurance_health",
  help: "Insurance FundHealth enum: 0 CRITICAL, 1 WARNING, 2 HEALTHY, 3 OVERCAPITALIZED.",
  registers: [registry],
});
export const tgauxSupply = new Gauge({
  name: "tetragold_tgaux_supply",
  help: "TGAUX total supply (18-decimal value scaled to a float).",
  registers: [registry],
});
export const scrapeErrors = new Counter({
  name: "tetragold_exporter_scrape_errors_total",
  help: "Total exporter scrape failures.",
  registers: [registry],
});
export const lastScrapeSuccess = new Gauge({
  name: "tetragold_exporter_last_scrape_success_timestamp",
  help: "Unix timestamp of the last successful exporter scrape (liveness signal).",
  registers: [registry],
});

export const keeperUp = new Gauge({
  name: "tetragold_keeper_up",
  help: "1 while the keeper loop is running.",
  registers: [registry],
});
export const keeperLastTick = new Gauge({
  name: "tetragold_keeper_last_tick_timestamp",
  help: "Unix timestamp of the keeper's last completed loop iteration (liveness signal).",
  registers: [registry],
});
export const keeperBalanceWei = new Gauge({
  name: "tetragold_keeper_balance_wei",
  help: "Native gas balance of the keeper account, in wei.",
  registers: [registry],
});
export const keeperActions = new Counter({
  name: "tetragold_keeper_actions_total",
  help: "Keeper actions attempted, by type and outcome.",
  labelNames: ["action", "outcome"],
  registers: [registry],
});
export const keeperDryRun = new Gauge({
  name: "tetragold_keeper_dry_run",
  help: "1 if the keeper is in dry-run mode (no txs sent).",
  registers: [registry],
});

export function serveMetrics(port: number, name: string) {
  const server = http.createServer(async (req, res) => {
    if (req.url === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("ok");
      return;
    }
    if (req.url === "/metrics") {
      try {
        const body = await registry.metrics();
        res.writeHead(200, { "content-type": registry.contentType });
        res.end(body);
      } catch (err) {
        res.writeHead(500);
        res.end(String(err));
      }
      return;
    }
    res.writeHead(404);
    res.end("not found");
  });
  server.listen(port, () => log.info(`${name} metrics listening`, { port, path: "/metrics" }));
  return server;
}
