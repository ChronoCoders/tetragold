import { apiConfig } from "./config.js";
import { ApiError } from "./http.js";

interface GraphResponse<T> {
  data?: T;
  errors?: { message: string }[];
}

export async function querySubgraph<T = unknown>(
  query: string,
  variables: Record<string, unknown> = {},
): Promise<T> {
  let res: Response;
  try {
    res = await fetch(apiConfig.subgraphUrl(), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query, variables }),
      signal: AbortSignal.timeout(apiConfig.subgraphTimeoutMs()),
    });
  } catch (err) {
    throw new ApiError(502, "subgraph_unreachable", `subgraph request failed: ${(err as Error).message}`);
  }
  if (!res.ok) throw new ApiError(502, "subgraph_error", `subgraph returned HTTP ${res.status}`);
  const body = (await res.json()) as GraphResponse<T>;
  if (body.errors && body.errors.length > 0) {
    throw new ApiError(502, "subgraph_error", body.errors.map((e) => e.message).join("; "));
  }
  if (!body.data) throw new ApiError(502, "subgraph_error", "subgraph returned no data");
  return body.data;
}

export function clampFirst(raw: string | null, fallback = 50): number {
  const n = raw === null ? fallback : Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(1000, Math.max(1, Math.floor(n)));
}

export function clampSkip(raw: string | null): number {
  const n = raw === null ? 0 : Number(raw);
  if (!Number.isFinite(n) || n < 0) return 0;
  return Math.min(5000, Math.floor(n));
}

export function pickOrder(raw: string | null, allowed: string[], fallback: string): string {
  return raw !== null && allowed.includes(raw) ? raw : fallback;
}

export function pickDir(raw: string | null): "asc" | "desc" {
  return raw === "asc" ? "asc" : "desc";
}

const POSITION_FIELDS = `
  id positionId owner { id } collateralToken collateral borrowedAmount leverage
  tgauxMinted openPrice status returnAmount collateralSeized badDebt
  tranchesLiquidated openedAt closedAt openedTx`;

export function overview() {
  return querySubgraph<{ protocol: unknown }>(`{
    protocol(id: "tetragold") {
      totalPositionsOpened totalPositionsClosed totalPositionsLiquidated openPositionCount
      totalCollateralOpened totalTgauxMinted totalLiquidations totalPenaltiesCollected
      totalBadDebt lastGoldPrice lastPriceUpdate circuitBreakerTrips
    }
  }`);
}

export function listPositions(opts: {
  first: number;
  skip: number;
  orderBy: string;
  orderDirection: "asc" | "desc";
  status?: string;
  owner?: string;
}) {
  const where: string[] = [];
  if (opts.status) where.push(`status: ${opts.status}`);
  if (opts.owner) where.push(`owner: "${opts.owner.toLowerCase()}"`);
  const whereClause = where.length > 0 ? `, where: { ${where.join(", ")} }` : "";
  return querySubgraph<{ positions: unknown[] }>(`{
    positions(first: ${opts.first}, skip: ${opts.skip}, orderBy: ${opts.orderBy}, orderDirection: ${opts.orderDirection}${whereClause}) {
      ${POSITION_FIELDS}
    }
  }`);
}

export function getPosition(id: string) {
  return querySubgraph<{ position: Record<string, unknown> | null }>(
    `query Position($id: ID!) {
      position(id: $id) {
        ${POSITION_FIELDS}
        liquidations(first: 10, orderBy: timestamp, orderDirection: desc) { id liquidator penalty portion timestamp tx }
        marks { id markedTime cleared clearedAt }
        badDebtEvents { id token shortfall timestamp }
      }
    }`,
    { id },
  );
}

export function listLiquidations(opts: { first: number; skip: number }) {
  return querySubgraph<{ liquidations: unknown[] }>(`{
    liquidations(first: ${opts.first}, skip: ${opts.skip}, orderBy: timestamp, orderDirection: desc) {
      id liquidator penalty portion timestamp block tx
      position { id positionId owner { id } status }
    }
  }`);
}

export function dailyStats(opts: { first: number }) {
  return querySubgraph<{ protocolDayDatas: unknown[] }>(`{
    protocolDayDatas(first: ${opts.first}, orderBy: date, orderDirection: desc) {
      id date positionsOpened positionsClosed positionsLiquidated penalties badDebt collateralOpened goldPriceClose
    }
  }`);
}
