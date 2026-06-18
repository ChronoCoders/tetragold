import "dotenv/config";
import { exporterConfig, loadAddresses } from "./config.js";
import { publicClient } from "./chain.js";
import { readSnapshot } from "./protocol.js";
import { log } from "./logger.js";
import {
  activePositions,
  contractPaused,
  goldPrice,
  insuranceHealth,
  insuranceReserves,
  insuranceTarget,
  lastScrapeSuccess,
  liquidatablePositions,
  oraclePaused,
  oraclePriceAge,
  poolBorrowed,
  poolDeposits,
  poolUtilization,
  positionHealthMin,
  scrapeErrors,
  serveMetrics,
  tgauxSupply,
  tvlUsd,
} from "./metrics.js";

const addresses = loadAddresses();
const client = publicClient();
const intervalMs = exporterConfig.scrapeSeconds() * 1000;
const maxPositions = exporterConfig.maxPositions();

async function scrape() {
  try {
    const s = await readSnapshot(client, addresses, maxPositions);

    goldPrice.set(s.goldPriceUsd);
    oraclePriceAge.set(s.oraclePriceAgeSeconds);
    oraclePaused.set(s.oraclePaused ? 1 : 0);
    contractPaused.set({ contract: "oracle" }, s.oraclePaused ? 1 : 0);
    contractPaused.set({ contract: "vault" }, s.vaultPaused ? 1 : 0);
    contractPaused.set({ contract: "pool" }, s.poolPaused ? 1 : 0);
    contractPaused.set({ contract: "insurance" }, s.insurancePaused ? 1 : 0);

    tvlUsd.set(s.tvlUsd);
    activePositions.set(s.activePositions);
    liquidatablePositions.set(s.liquidatable);
    if (s.minHealthRatio !== null) positionHealthMin.set(s.minHealthRatio);

    for (const p of s.pools) {
      poolDeposits.set({ pool: p.name }, p.deposits);
      poolBorrowed.set({ pool: p.name }, p.borrowed);
      poolUtilization.set({ pool: p.name }, p.utilization);
    }

    insuranceReserves.set(s.insuranceReserves);
    insuranceTarget.set(s.insuranceTarget);
    insuranceHealth.set(s.insuranceHealth);
    tgauxSupply.set(s.tgauxSupply);

    lastScrapeSuccess.set(Math.floor(Date.now() / 1000));
    log.debug("scrape ok", {
      goldPriceUsd: s.goldPriceUsd,
      tvlUsd: s.tvlUsd,
      liquidatable: s.liquidatable,
      insuranceHealth: s.insuranceHealth,
    });
  } catch (err) {
    scrapeErrors.inc();
    log.error("scrape failed", { error: (err as Error).message });
  }
}

async function main() {
  serveMetrics(exporterConfig.port(), "exporter");
  log.info("exporter started", {
    rpc: addresses ? "configured" : "missing",
    intervalSeconds: exporterConfig.scrapeSeconds(),
    maxPositions,
  });
  await scrape();
  const timer = setInterval(scrape, intervalMs);

  const shutdown = (sig: string) => {
    log.info("shutting down", { signal: sig });
    clearInterval(timer);
    process.exit(0);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main().catch((err) => {
  log.error("exporter fatal", { error: (err as Error).message });
  process.exit(1);
});
