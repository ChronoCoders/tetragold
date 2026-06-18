import { formatUnits, type PublicClient } from "viem";
import type { Addresses } from "./config.js";
import { insuranceAbi, oracleAbi, poolAbi, tgauxAbi, vaultAbi } from "./abi.js";

export const USD_DECIMALS = 6;
export const PRICE_DECIMALS = 8;
export const TGAUX_DECIMALS = 18;
export const BPS = 10000;

export function toFloat(value: bigint, decimals: number): number {
  return Number(formatUnits(value, decimals));
}

export interface ProtocolSnapshot {
  goldPriceUsd: number;
  oracleLastUpdate: number;
  oraclePriceAgeSeconds: number;
  oraclePaused: boolean;
  vaultPaused: boolean;
  poolPaused: boolean;
  insurancePaused: boolean;
  tvlUsd: number;
  activePositions: number;
  liquidatable: number;
  minHealthRatio: number | null;
  pools: { name: string; deposits: number; borrowed: number; utilization: number }[];
  insuranceReserves: number;
  insuranceTarget: number;
  insuranceHealth: number;
  tgauxSupply: number;
}

const POOL_NAMES = ["CONSERVATIVE", "AGGRESSIVE"] as const;

export async function readSnapshot(
  client: PublicClient,
  a: Addresses,
  maxPositions: number,
): Promise<ProtocolSnapshot> {
  const block = await client.getBlock({ blockTag: "latest" });
  const nowSec = Number(block.timestamp);

  const [
    lastPrice,
    lastUpdateTime,
    oraclePaused,
    vaultPaused,
    poolPaused,
    insurancePaused,
    tvl,
    activeCount,
    reserves,
    target,
    fundHealth,
    supply,
  ] = await Promise.all([
    client.readContract({ address: a.oracle, abi: oracleAbi, functionName: "lastPrice" }),
    client.readContract({ address: a.oracle, abi: oracleAbi, functionName: "lastUpdateTime" }),
    client.readContract({ address: a.oracle, abi: oracleAbi, functionName: "paused" }),
    client.readContract({ address: a.vault, abi: vaultAbi, functionName: "paused" }),
    client.readContract({ address: a.pool, abi: poolAbi, functionName: "paused" }),
    client.readContract({ address: a.insurance, abi: insuranceAbi, functionName: "paused" }),
    client.readContract({ address: a.vault, abi: vaultAbi, functionName: "totalValueLocked" }),
    client.readContract({ address: a.vault, abi: vaultAbi, functionName: "activePositionCount" }),
    client.readContract({ address: a.insurance, abi: insuranceAbi, functionName: "getTotalReserves" }),
    client.readContract({ address: a.insurance, abi: insuranceAbi, functionName: "getTargetReserve" }),
    client.readContract({ address: a.insurance, abi: insuranceAbi, functionName: "getFundHealth" }),
    client.readContract({ address: a.tgaux, abi: tgauxAbi, functionName: "totalSupply" }),
  ]);

  const pools = await Promise.all(
    POOL_NAMES.map(async (name, i) => {
      const info = await client.readContract({
        address: a.pool,
        abi: poolAbi,
        functionName: "getPoolInfo",
        args: [i],
      });
      return {
        name,
        deposits: toFloat(info[0], USD_DECIMALS),
        borrowed: toFloat(info[1], USD_DECIMALS),
        utilization: Number(info[2]) / BPS,
      };
    }),
  );

  const ids = (await client.readContract({
    address: a.vault,
    abi: vaultAbi,
    functionName: "getActivePositionIds",
  })) as readonly bigint[];
  const sample = ids.slice(0, maxPositions);

  let liquidatable = 0;
  let minHealthRatio: number | null = null;
  for (const id of sample) {
    const [health, isLiq] = await Promise.all([
      client.readContract({ address: a.vault, abi: vaultAbi, functionName: "getPositionHealth", args: [id] }),
      client.readContract({ address: a.vault, abi: vaultAbi, functionName: "isLiquidatable", args: [id] }),
    ]);
    if (isLiq) liquidatable++;
    const ratio = Number(health) / BPS;
    if (minHealthRatio === null || ratio < minHealthRatio) minHealthRatio = ratio;
  }

  return {
    goldPriceUsd: toFloat(lastPrice, PRICE_DECIMALS),
    oracleLastUpdate: Number(lastUpdateTime),
    oraclePriceAgeSeconds: Number(lastUpdateTime) === 0 ? -1 : nowSec - Number(lastUpdateTime),
    oraclePaused,
    vaultPaused,
    poolPaused,
    insurancePaused,
    tvlUsd: toFloat(tvl, USD_DECIMALS),
    activePositions: Number(activeCount),
    liquidatable,
    minHealthRatio,
    pools,
    insuranceReserves: toFloat(reserves, USD_DECIMALS),
    insuranceTarget: toFloat(target, USD_DECIMALS),
    insuranceHealth: Number(fundHealth),
    tgauxSupply: toFloat(supply, TGAUX_DECIMALS),
  };
}
