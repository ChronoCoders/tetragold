import { createHash, timingSafeEqual } from "node:crypto";
import type { IncomingMessage } from "node:http";
import { apiConfig } from "./config.js";
import { ApiError } from "./http.js";

function extractKey(req: IncomingMessage): string | null {
  const auth = req.headers["authorization"];
  if (typeof auth === "string" && auth.startsWith("Bearer ")) return auth.slice(7).trim();
  const x = req.headers["x-api-key"];
  if (typeof x === "string" && x.length > 0) return x.trim();
  return null;
}

function matches(provided: string, keys: string[]): boolean {
  const p = Buffer.from(provided);
  let ok = false;
  for (const k of keys) {
    const kb = Buffer.from(k);
    if (kb.length === p.length && timingSafeEqual(kb, p)) ok = true;
  }
  return ok;
}

function keyId(key: string): string {
  return "key_" + createHash("sha256").update(key).digest("hex").slice(0, 12);
}

// Returns a principal id for rate-limit keying and logging; never the raw key.
export function authenticate(req: IncomingMessage): string {
  if (apiConfig.authDisabled()) return "anon";
  const keys = apiConfig.apiKeys();
  if (keys.length === 0) {
    throw new ApiError(
      503,
      "auth_unconfigured",
      "no API keys configured; set API_KEYS or API_AUTH_DISABLED=true",
    );
  }
  const provided = extractKey(req);
  if (!provided) {
    throw new ApiError(
      401,
      "unauthorized",
      "missing API key (send 'Authorization: Bearer <key>' or 'x-api-key')",
    );
  }
  if (!matches(provided, keys)) throw new ApiError(401, "unauthorized", "invalid API key");
  return keyId(provided);
}
