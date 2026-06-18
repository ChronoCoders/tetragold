import type { IncomingMessage, ServerResponse } from "node:http";

export class ApiError extends Error {
  status: number;
  code: string;
  headers?: Record<string, string>;
  constructor(status: number, code: string, message: string, headers?: Record<string, string>) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

export interface Ctx {
  req: IncomingMessage;
  res: ServerResponse;
  url: URL;
  params: Record<string, string>;
  query: URLSearchParams;
  principal: string;
  requestId: string;
}

export type Handler = (ctx: Ctx) => Promise<unknown> | unknown;

function jsonReplacer(_key: string, value: unknown) {
  return typeof value === "bigint" ? value.toString() : value;
}

export function sendJson(
  res: ServerResponse,
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
): void {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", ...headers });
  res.end(JSON.stringify(body, jsonReplacer));
}

export function sendError(
  res: ServerResponse,
  status: number,
  code: string,
  message: string,
  headers: Record<string, string> = {},
): void {
  sendJson(res, status, { error: { code, message } }, headers);
}

export async function readJsonBody(req: IncomingMessage, limitBytes = 1_000_000): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > limitBytes) throw new ApiError(413, "payload_too_large", "request body too large");
    chunks.push(chunk as Buffer);
  }
  if (chunks.length === 0) return undefined;
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new ApiError(400, "invalid_json", "request body is not valid JSON");
  }
}

interface Route {
  method: string;
  pattern: string;
  segments: string[];
  handler: Handler;
  public: boolean;
}

export class Router {
  private routes: Route[] = [];

  add(method: string, pattern: string, handler: Handler, opts: { public?: boolean } = {}): this {
    this.routes.push({
      method,
      pattern,
      segments: pattern.split("/").filter(Boolean),
      handler,
      public: opts.public === true,
    });
    return this;
  }

  match(method: string, pathname: string): { route: Route; params: Record<string, string> } | null {
    const parts = pathname.split("/").filter(Boolean);
    for (const route of this.routes) {
      if (route.method !== method) continue;
      if (route.segments.length !== parts.length) continue;
      const params: Record<string, string> = {};
      let ok = true;
      for (let i = 0; i < route.segments.length; i++) {
        const seg = route.segments[i] as string;
        const part = parts[i] as string;
        if (seg.startsWith(":")) params[seg.slice(1)] = decodeURIComponent(part);
        else if (seg !== part) {
          ok = false;
          break;
        }
      }
      if (ok) return { route, params };
    }
    return null;
  }

  // True if any route matches the path under a different method (drives 405 vs 404).
  hasPath(pathname: string): boolean {
    const parts = pathname.split("/").filter(Boolean);
    return this.routes.some(
      (r) =>
        r.segments.length === parts.length &&
        r.segments.every((s, i) => s.startsWith(":") || s === parts[i]),
    );
  }
}
