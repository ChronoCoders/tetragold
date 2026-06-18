import "dotenv/config";
import http from "node:http";
import { randomUUID } from "node:crypto";
import { apiConfig, loadAddresses } from "./config.js";
import { publicClient } from "./chain.js";
import { vaultAbi } from "./abi.js";
import { readSnapshot, BPS } from "./protocol.js";
import { registry } from "./metrics.js";
import { apiUp, authFailures, httpDuration, httpRequests, rateLimited } from "./apiMetrics.js";
import { authenticate } from "./auth.js";
import { rateLimit, sweepBuckets } from "./ratelimit.js";
import { cached } from "./cache.js";
import { ApiError, Router, readJsonBody, sendError, sendJson, type Ctx } from "./http.js";
import {
  clampFirst,
  clampSkip,
  dailyStats,
  getPosition,
  listLiquidations,
  listPositions,
  overview,
  pickDir,
  pickOrder,
  querySubgraph,
} from "./subgraph.js";
import { log } from "./logger.js";

const addresses = loadAddresses();
const client = publicClient();

const POSITION_ORDER = ["openedAt", "leverage", "collateral", "borrowedAmount", "positionId"];
const POSITION_STATUS = ["OPEN", "CLOSED", "LIQUIDATED"];

async function liveOverview() {
  return cached("overview", apiConfig.cacheTtlSeconds(), () =>
    readSnapshot(client, addresses, apiConfig.maxPositions()),
  );
}

async function enrichLive(positionId: string) {
  try {
    const id = BigInt(positionId);
    const [health, isLiquidatable] = await Promise.all([
      client.readContract({ address: addresses.vault, abi: vaultAbi, functionName: "getPositionHealth", args: [id] }),
      client.readContract({ address: addresses.vault, abi: vaultAbi, functionName: "isLiquidatable", args: [id] }),
    ]);
    return { healthRatio: Number(health) / BPS, isLiquidatable };
  } catch {
    return null; // closed/settled positions revert on health reads
  }
}

const router = new Router();

router.add("GET", "/health", (ctx) => writeText(ctx, 200, "text/plain", "ok"), { public: true });

router.add(
  "GET",
  "/ready",
  async (ctx) => {
    const checks = { rpc: false, subgraph: false };
    await Promise.all([
      client.getBlockNumber().then(() => (checks.rpc = true)).catch(() => {}),
      querySubgraph("{ _meta { block { number } } }").then(() => (checks.subgraph = true)).catch(() => {}),
    ]);
    const ok = checks.rpc && checks.subgraph;
    sendJson(ctx.res, ok ? 200 : 503, { status: ok ? "ready" : "degraded", checks });
  },
  { public: true },
);

router.add(
  "GET",
  "/metrics",
  async (ctx) => writeText(ctx, 200, registry.contentType, await registry.metrics()),
  { public: true },
);

router.add("GET", "/v1/overview", async () => {
  const [live, indexed] = await Promise.all([liveOverview(), overview().catch(() => null)]);
  return { live, indexed: indexed ? (indexed as { protocol: unknown }).protocol : null };
});

router.add("GET", "/v1/oracle", async () => {
  const s = await liveOverview();
  return {
    goldPriceUsd: s.goldPriceUsd,
    lastUpdate: s.oracleLastUpdate,
    priceAgeSeconds: s.oraclePriceAgeSeconds,
    paused: s.oraclePaused,
  };
});

router.add("GET", "/v1/pools", async () => ({ pools: (await liveOverview()).pools }));

router.add("GET", "/v1/insurance", async () => {
  const s = await liveOverview();
  return {
    reservesUsd: s.insuranceReserves,
    targetUsd: s.insuranceTarget,
    health: s.insuranceHealth,
    healthLabel: ["CRITICAL", "WARNING", "HEALTHY", "OVERCAPITALIZED"][s.insuranceHealth] ?? "UNKNOWN",
  };
});

router.add("GET", "/v1/positions", async (ctx) => {
  const status = ctx.query.get("status")?.toUpperCase();
  if (status && !POSITION_STATUS.includes(status)) {
    throw new ApiError(400, "invalid_status", `status must be one of ${POSITION_STATUS.join(", ")}`);
  }
  const data = await listPositions({
    first: clampFirst(ctx.query.get("first")),
    skip: clampSkip(ctx.query.get("skip")),
    orderBy: pickOrder(ctx.query.get("orderBy"), POSITION_ORDER, "openedAt"),
    orderDirection: pickDir(ctx.query.get("orderDirection")),
    status,
    owner: ctx.query.get("owner") ?? undefined,
  });
  return { positions: data.positions };
});

router.add("GET", "/v1/positions/:id", async (ctx) => {
  const id = ctx.params.id ?? "";
  if (!/^\d+$/.test(id)) throw new ApiError(400, "invalid_id", "position id must be a non-negative integer");
  const data = await getPosition(id);
  if (!data.position) throw new ApiError(404, "not_found", `position ${id} not found`);
  const live = await enrichLive(id);
  return { ...data.position, live };
});

router.add("GET", "/v1/liquidations", async (ctx) => {
  const data = await listLiquidations({
    first: clampFirst(ctx.query.get("first")),
    skip: clampSkip(ctx.query.get("skip")),
  });
  return { liquidations: data.liquidations };
});

router.add("GET", "/v1/stats/daily", async (ctx) => {
  const data = await dailyStats({ first: clampFirst(ctx.query.get("first"), 30) });
  return { days: data.protocolDayDatas };
});

router.add("POST", "/v1/graphql", async (ctx) => {
  if (!apiConfig.graphqlPassthrough()) {
    throw new ApiError(403, "passthrough_disabled", "GraphQL passthrough is disabled");
  }
  const body = (await readJsonBody(ctx.req)) as { query?: string; variables?: Record<string, unknown> } | undefined;
  if (!body || typeof body.query !== "string") {
    throw new ApiError(400, "invalid_request", "body must be { query: string, variables?: object }");
  }
  return { data: await querySubgraph(body.query, body.variables ?? {}) };
});

function writeText(ctx: Ctx, status: number, contentType: string, body: string) {
  ctx.res.writeHead(status, { "content-type": contentType });
  ctx.res.end(body);
}

function applyCors(res: http.ServerResponse) {
  res.setHeader("access-control-allow-origin", apiConfig.corsOrigin());
  res.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
  res.setHeader("access-control-allow-headers", "authorization, x-api-key, content-type");
}

function handleError(res: http.ServerResponse, err: unknown, route: string) {
  if (err instanceof ApiError) {
    if (err.status >= 500) log.error("request error", { route, code: err.code, message: err.message });
    sendError(res, err.status, err.code, err.message, err.headers ?? {});
    return;
  }
  log.error("unhandled error", { route, error: (err as Error).message });
  sendError(res, 500, "internal_error", "internal server error");
}

const server = http.createServer(async (req, res) => {
  const start = process.hrtime.bigint();
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  const method = req.method || "GET";
  const requestId = randomUUID();
  res.setHeader("x-request-id", requestId);
  applyCors(res);
  let routePattern = "unknown";

  try {
    if (method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }
    const m = router.match(method, url.pathname);
    if (!m) {
      if (router.hasPath(url.pathname)) throw new ApiError(405, "method_not_allowed", "method not allowed");
      throw new ApiError(404, "not_found", "no such endpoint");
    }
    routePattern = m.route.pattern;

    let principal = "public";
    if (!m.route.public) {
      try {
        principal = authenticate(req);
      } catch (err) {
        if (err instanceof ApiError && err.status === 401) authFailures.inc();
        throw err;
      }
      const rl = rateLimit(principal);
      res.setHeader("x-ratelimit-limit", String(rl.limit));
      res.setHeader("x-ratelimit-remaining", String(rl.remaining));
      res.setHeader("x-ratelimit-reset", String(Math.ceil(rl.resetAt / 1000)));
      if (!rl.allowed) {
        rateLimited.inc({ route: routePattern });
        const retry = Math.max(1, Math.ceil((rl.resetAt - Date.now()) / 1000));
        throw new ApiError(429, "rate_limited", "rate limit exceeded", { "retry-after": String(retry) });
      }
    }

    const ctx: Ctx = { req, res, url, params: m.params, query: url.searchParams, principal, requestId };
    const result = await m.route.handler(ctx);
    if (!res.writableEnded) sendJson(res, 200, result);
  } catch (err) {
    if (!res.writableEnded) handleError(res, err, routePattern);
  } finally {
    const seconds = Number(process.hrtime.bigint() - start) / 1e9;
    httpRequests.inc({ route: routePattern, method, status: String(res.statusCode) });
    httpDuration.observe({ route: routePattern, method }, seconds);
    log.info("request", {
      requestId,
      method,
      path: url.pathname,
      status: res.statusCode,
      ms: Math.round(seconds * 1000),
    });
  }
});

function main() {
  const port = apiConfig.port();
  apiUp.set(1);
  const sweep = setInterval(sweepBuckets, 60_000);
  server.listen(port, () =>
    log.info("api listening", {
      port,
      authDisabled: apiConfig.authDisabled(),
      keys: apiConfig.apiKeys().length,
      rateLimit: `${apiConfig.rateLimitMax()}/${apiConfig.rateLimitWindowSeconds()}s`,
      subgraph: apiConfig.subgraphUrl(),
    }),
  );

  const shutdown = (sig: string) => {
    log.info("shutting down", { signal: sig });
    apiUp.set(0);
    clearInterval(sweep);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main();
