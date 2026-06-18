import { apiConfig } from "./config.js";

interface Bucket {
  count: number;
  resetAt: number;
}

const buckets = new Map<string, Bucket>();

export interface RateResult {
  allowed: boolean;
  limit: number;
  remaining: number;
  resetAt: number;
}

// Fixed-window per-principal limiter. In-memory: fine for a single instance;
// front with a shared store (Redis) before scaling horizontally.
export function rateLimit(principal: string): RateResult {
  const limit = apiConfig.rateLimitMax();
  const windowMs = apiConfig.rateLimitWindowSeconds() * 1000;
  const now = Date.now();
  let b = buckets.get(principal);
  if (!b || now >= b.resetAt) {
    b = { count: 0, resetAt: now + windowMs };
    buckets.set(principal, b);
  }
  b.count++;
  return {
    allowed: b.count <= limit,
    limit,
    remaining: Math.max(0, limit - b.count),
    resetAt: b.resetAt,
  };
}

export function sweepBuckets(): void {
  const now = Date.now();
  for (const [k, b] of buckets) if (now >= b.resetAt) buckets.delete(k);
}
