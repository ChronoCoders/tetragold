interface Entry {
  value: unknown;
  expiresAt: number;
}

const store = new Map<string, Entry>();
const inflight = new Map<string, Promise<unknown>>();

// TTL cache with single-flight: concurrent misses share one loader call,
// shielding the RPC/subgraph from request stampedes.
export async function cached<T>(key: string, ttlSeconds: number, loader: () => Promise<T>): Promise<T> {
  const hit = store.get(key);
  if (hit && Date.now() < hit.expiresAt) return hit.value as T;

  const existing = inflight.get(key);
  if (existing) return existing as Promise<T>;

  const p = (async () => {
    try {
      const value = await loader();
      store.set(key, { value, expiresAt: Date.now() + ttlSeconds * 1000 });
      return value;
    } finally {
      inflight.delete(key);
    }
  })();
  inflight.set(key, p);
  return p as Promise<T>;
}
