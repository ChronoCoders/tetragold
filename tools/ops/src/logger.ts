import { logConfig } from "./config.js";

type Level = "debug" | "info" | "warn" | "error";
const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

const threshold = ORDER[(logConfig.level() as Level)] ?? ORDER.info;
const pretty = logConfig.format() === "pretty";

function replacer(_key: string, value: unknown) {
  return typeof value === "bigint" ? value.toString() : value;
}

function emit(level: Level, msg: string, fields?: Record<string, unknown>) {
  if (ORDER[level] < threshold) return;
  const ts = new Date().toISOString();
  if (pretty) {
    const extra = fields ? " " + JSON.stringify(fields, replacer) : "";
    const line = `${ts} ${level.toUpperCase().padEnd(5)} ${msg}${extra}`;
    (level === "error" ? console.error : console.log)(line);
    return;
  }
  const record = { ts, level, msg, ...fields };
  (level === "error" ? console.error : console.log)(JSON.stringify(record, replacer));
}

export const log = {
  debug: (msg: string, fields?: Record<string, unknown>) => emit("debug", msg, fields),
  info: (msg: string, fields?: Record<string, unknown>) => emit("info", msg, fields),
  warn: (msg: string, fields?: Record<string, unknown>) => emit("warn", msg, fields),
  error: (msg: string, fields?: Record<string, unknown>) => emit("error", msg, fields),
};
