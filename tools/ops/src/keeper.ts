import "dotenv/config";
import { decodeAbiParameters } from "viem";
import { keeperConfig, loadAddresses } from "./config.js";
import { keeperWallet, publicClient } from "./chain.js";
import { liquidationEngineAbi, oracleAbi } from "./abi.js";
import { log } from "./logger.js";
import {
  keeperActions,
  keeperBalanceWei,
  keeperDryRun,
  keeperLastTick,
  keeperUp,
  serveMetrics,
} from "./metrics.js";

const a = loadAddresses();
const pub = publicClient();
const { wallet, account } = keeperWallet();
const dryRun = keeperConfig.dryRun();

const EMPTY_BYTES = "0x" as const;
const MAX_DRAIN_ITERATIONS = 5;

let lastTwapSentAt = 0;

async function send(
  action: string,
  address: `0x${string}`,
  abi: readonly unknown[],
  functionName: string,
  args: readonly unknown[],
  gasOverride?: bigint,
): Promise<boolean> {
  if (dryRun) {
    log.info("dry-run: would send tx", { action, functionName, args });
    keeperActions.inc({ action, outcome: "dry_run" });
    return false;
  }
  try {
    const { request } = await pub.simulateContract({
      account,
      address,
      abi: abi as never,
      functionName: functionName as never,
      args: args as never,
    });
    // gasOverride bypasses estimateContractGas for calls whose revert is
    // swallowed internally (e.g. performUpkeep's try/catch): estimation would
    // return the inner-OOG-then-caught minimum and starve the real work.
    let gasLimit: bigint;
    if (gasOverride !== undefined) {
      gasLimit = gasOverride;
    } else {
      const gas = await pub.estimateContractGas({
        account,
        address,
        abi: abi as never,
        functionName: functionName as never,
        args: args as never,
      });
      gasLimit = BigInt(Math.ceil(Number(gas) * keeperConfig.gasLimitMultiplier()));
    }

    const hash = await wallet.writeContract({ ...request, gas: gasLimit } as never);
    log.info("tx sent", { action, functionName, hash });
    const receipt = await pub.waitForTransactionReceipt({
      hash,
      confirmations: keeperConfig.txConfirmations(),
    });
    const ok = receipt.status === "success";
    keeperActions.inc({ action, outcome: ok ? "success" : "reverted" });
    log.info("tx mined", { action, hash, status: receipt.status, gasUsed: receipt.gasUsed });
    return ok;
  } catch (err) {
    keeperActions.inc({ action, outcome: "error" });
    log.error("tx failed", { action, functionName, error: (err as Error).message });
    return false;
  }
}

async function maintainOracle(nowSec: number) {
  const [lastUpdateTime, paused, minInterval] = await Promise.all([
    pub.readContract({ address: a.oracle, abi: oracleAbi, functionName: "lastUpdateTime" }),
    pub.readContract({ address: a.oracle, abi: oracleAbi, functionName: "paused" }),
    pub.readContract({ address: a.oracle, abi: oracleAbi, functionName: "MIN_UPDATE_INTERVAL" }),
  ]);

  if (paused) {
    log.warn("oracle paused -- skipping TWAP refresh (circuit breaker or admin pause)");
    return;
  }

  const age = nowSec - Number(lastUpdateTime);
  const minInt = Math.max(Number(minInterval), keeperConfig.oracleMinUpdateInterval());
  const sinceOurLast = nowSec - lastTwapSentAt;

  if (age < keeperConfig.oracleMaxStaleness()) return;
  if (Number(lastUpdateTime) !== 0 && age < minInt) return;
  if (sinceOurLast < minInt) return;

  log.info("refreshing oracle TWAP", { ageSeconds: age });
  const ok = await send("oracle_update", a.oracle, oracleAbi, "updateTwap", []);
  if (ok || dryRun) lastTwapSentAt = nowSec;
}

async function processLiquidations() {
  const enginePaused = await pub.readContract({
    address: a.liquidationEngine,
    abi: liquidationEngineAbi,
    functionName: "paused",
  });
  if (enginePaused) {
    log.warn("liquidation engine paused -- skipping");
    return;
  }

  for (let i = 0; i < MAX_DRAIN_ITERATIONS; i++) {
    const [upkeepNeeded, performData] = (await pub.readContract({
      address: a.liquidationEngine,
      abi: liquidationEngineAbi,
      functionName: "checkUpkeep",
      args: [EMPTY_BYTES],
    })) as [boolean, `0x${string}`];

    if (!upkeepNeeded) {
      if (i === 0) log.debug("no liquidations needed");
      return;
    }

    let positionCount = 1;
    try {
      const [ids] = decodeAbiParameters([{ type: "uint256[]" }], performData) as [bigint[]];
      positionCount = Math.max(ids.length, 1);
    } catch {
      // keep default of 1 if performData is not the expected uint256[] encoding
    }
    const gasLimit = BigInt(
      keeperConfig.performUpkeepBaseGas() +
        positionCount * keeperConfig.performUpkeepGasPerPosition(),
    );

    log.info("upkeep needed -- performing", { iteration: i + 1, positionCount, gasLimit: Number(gasLimit) });
    const ok = await send(
      "perform_upkeep",
      a.liquidationEngine,
      liquidationEngineAbi,
      "performUpkeep",
      [performData],
      gasLimit,
    );
    if (!ok) return;
  }
  log.warn("liquidation backlog not fully drained this tick", { iterations: MAX_DRAIN_ITERATIONS });
}

async function tick() {
  try {
    const block = await pub.getBlock({ blockTag: "latest" });
    const nowSec = Number(block.timestamp);

    const balance = await pub.getBalance({ address: account.address });
    keeperBalanceWei.set(Number(balance));
    if (balance === 0n && !dryRun) {
      log.error("keeper account has zero gas balance -- cannot act", { account: account.address });
    }

    await maintainOracle(nowSec);
    await processLiquidations();

    keeperLastTick.set(Math.floor(Date.now() / 1000));
  } catch (err) {
    log.error("tick failed", { error: (err as Error).message });
  }
}

async function main() {
  const once = keeperConfig.once();
  keeperUp.set(1);
  keeperDryRun.set(dryRun ? 1 : 0);
  if (!once) serveMetrics(keeperConfig.metricsPort(), "keeper");
  log.info("keeper started", {
    account: account.address,
    dryRun,
    once,
    pollSeconds: keeperConfig.pollSeconds(),
    oracleMaxStaleness: keeperConfig.oracleMaxStaleness(),
    engine: a.liquidationEngine,
  });
  if (dryRun) log.warn("KEEPER_DRY_RUN is enabled -- no transactions will be sent");

  await tick();
  if (once) {
    log.info("single tick complete, exiting");
    process.exit(0);
  }
  const timer = setInterval(tick, keeperConfig.pollSeconds() * 1000);

  const shutdown = (sig: string) => {
    log.info("shutting down", { signal: sig });
    keeperUp.set(0);
    clearInterval(timer);
    process.exit(0);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main().catch((err) => {
  log.error("keeper fatal", { error: (err as Error).message });
  process.exit(1);
});
