import { getAddress, type Address } from "viem";

function str(name: string, fallback?: string): string {
  const v = process.env[name];
  if (v === undefined || v === "") {
    if (fallback !== undefined) return fallback;
    throw new Error(`config error: $${name} is required`);
  }
  return v;
}

function num(name: string, fallback: number): number {
  const v = process.env[name];
  if (v === undefined || v === "") return fallback;
  const n = Number(v);
  if (!Number.isFinite(n)) throw new Error(`config error: $${name} must be a number, got "${v}"`);
  return n;
}

function bool(name: string, fallback: boolean): boolean {
  const v = process.env[name];
  if (v === undefined || v === "") return fallback;
  return v === "1" || v.toLowerCase() === "true";
}

function addr(name: string): Address {
  return getAddress(str(name));
}

export interface Addresses {
  oracle: Address;
  vault: Address;
  pool: Address;
  liquidationEngine: Address;
  insurance: Address;
  tgaux: Address;
}

export function loadAddresses(): Addresses {
  return {
    oracle: addr("ORACLE"),
    vault: addr("VAULT"),
    pool: addr("POOL"),
    liquidationEngine: addr("LIQUIDATION_ENGINE"),
    insurance: addr("INSURANCE"),
    tgaux: addr("TGAUX"),
  };
}

export const chainConfig = {
  rpcUrl: () => str("RPC_URL", "http://localhost:8545"),
  rpcUrlFallback: () => process.env.RPC_URL_FALLBACK || "",
  chainId: () => num("CHAIN_ID", 31337),
};

export const keeperConfig = {
  privateKey: () => str("KEEPER_PRIVATE_KEY"),
  dryRun: () => bool("KEEPER_DRY_RUN", true),
  pollSeconds: () => num("KEEPER_POLL_SECONDS", 15),
  oracleMaxStaleness: () => num("ORACLE_MAX_STALENESS_SECONDS", 300),
  oracleMinUpdateInterval: () => num("ORACLE_MIN_UPDATE_INTERVAL", 60),
  maxLiquidationsPerTick: () => num("MAX_LIQUIDATIONS_PER_TICK", 10),
  txConfirmations: () => num("TX_CONFIRMATIONS", 1),
  gasLimitMultiplier: () => num("GAS_LIMIT_MULTIPLIER", 1.25),
  performUpkeepBaseGas: () => num("PERFORM_UPKEEP_BASE_GAS", 200_000),
  performUpkeepGasPerPosition: () => num("PERFORM_UPKEEP_GAS_PER_POSITION", 800_000),
  metricsPort: () => num("KEEPER_METRICS_PORT", 9101),
  once: () => bool("KEEPER_ONCE", false),
};

export const exporterConfig = {
  port: () => num("EXPORTER_PORT", 9102),
  scrapeSeconds: () => num("EXPORTER_SCRAPE_SECONDS", 15),
  maxPositions: () => num("EXPORTER_MAX_POSITIONS", 200),
};

function list(name: string): string[] {
  return (process.env[name] || "").split(",").map((s) => s.trim()).filter(Boolean);
}

export const apiConfig = {
  port: () => num("API_PORT", 8080),
  apiKeys: () => list("API_KEYS"),
  authDisabled: () => bool("API_AUTH_DISABLED", false),
  rateLimitMax: () => num("API_RATE_LIMIT_MAX", 120),
  rateLimitWindowSeconds: () => num("API_RATE_LIMIT_WINDOW_SECONDS", 60),
  cacheTtlSeconds: () => num("API_CACHE_TTL_SECONDS", 5),
  subgraphUrl: () =>
    str("API_SUBGRAPH_URL", "http://localhost:8000/subgraphs/name/tetragold/tetragold"),
  subgraphTimeoutMs: () => num("API_SUBGRAPH_TIMEOUT_MS", 10_000),
  maxPositions: () => num("API_MAX_POSITIONS", 200),
  corsOrigin: () => str("API_CORS_ORIGIN", "*"),
  graphqlPassthrough: () => bool("API_GRAPHQL_PASSTHROUGH", true),
};

export const logConfig = {
  level: () => str("LOG_LEVEL", "info"),
  format: () => str("LOG_FORMAT", "json"),
};
