import { Counter, Gauge, Histogram } from "prom-client";
import { registry } from "./metrics.js";

export const apiUp = new Gauge({
  name: "tetragold_api_up",
  help: "1 while the API server is running.",
  registers: [registry],
});
export const httpRequests = new Counter({
  name: "tetragold_api_requests_total",
  help: "API requests by route, method, and status.",
  labelNames: ["route", "method", "status"],
  registers: [registry],
});
export const httpDuration = new Histogram({
  name: "tetragold_api_request_duration_seconds",
  help: "API request duration in seconds.",
  labelNames: ["route", "method"],
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5],
  registers: [registry],
});
export const rateLimited = new Counter({
  name: "tetragold_api_rate_limited_total",
  help: "Requests rejected by the rate limiter.",
  labelNames: ["route"],
  registers: [registry],
});
export const authFailures = new Counter({
  name: "tetragold_api_auth_failures_total",
  help: "Failed authentication attempts.",
  registers: [registry],
});
