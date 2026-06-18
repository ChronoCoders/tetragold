import { BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import { Protocol, User, Pool, ProtocolDayData } from "../generated/schema";

export const PROTOCOL_ID = "tetragold";
export const ZERO = BigInt.fromI32(0);
export const ONE = BigInt.fromI32(1);
export const DAY = 86400;

export function poolName(poolType: i32): string {
  return poolType == 0 ? "CONSERVATIVE" : "AGGRESSIVE";
}

export function getProtocol(): Protocol {
  let p = Protocol.load(PROTOCOL_ID);
  if (p == null) {
    p = new Protocol(PROTOCOL_ID);
    p.totalPositionsOpened = ZERO;
    p.totalPositionsClosed = ZERO;
    p.totalPositionsLiquidated = ZERO;
    p.openPositionCount = ZERO;
    p.totalCollateralOpened = ZERO;
    p.totalTgauxMinted = ZERO;
    p.totalLiquidations = ZERO;
    p.totalPenaltiesCollected = ZERO;
    p.totalBadDebt = ZERO;
    p.lastGoldPrice = ZERO;
    p.lastPriceUpdate = ZERO;
    p.circuitBreakerTrips = ZERO;
  }
  return p as Protocol;
}

export function getUser(address: Bytes): User {
  let id = address.toHexString();
  let u = User.load(id);
  if (u == null) {
    u = new User(id);
    u.positionsOpened = ZERO;
    u.positionsLiquidated = ZERO;
    u.liquidationsPerformed = ZERO;
    u.penaltiesEarned = ZERO;
    u.save();
  }
  return u as User;
}

export function getPool(poolType: i32): Pool {
  let id = poolType.toString();
  let pool = Pool.load(id);
  if (pool == null) {
    pool = new Pool(id);
    pool.poolType = poolType;
    pool.name = poolName(poolType);
    pool.netDeposited = ZERO;
    pool.totalBorrowed = ZERO;
    pool.utilization = ZERO;
    pool.depositCount = ZERO;
    pool.withdrawalCount = ZERO;
    pool.borrowCount = ZERO;
    pool.repayCount = ZERO;
  }
  return pool as Pool;
}

export function getDayData(event: ethereum.Event): ProtocolDayData {
  let dayId = event.block.timestamp.toI32() / DAY;
  let id = dayId.toString();
  let d = ProtocolDayData.load(id);
  if (d == null) {
    d = new ProtocolDayData(id);
    d.date = dayId * DAY;
    d.positionsOpened = ZERO;
    d.positionsClosed = ZERO;
    d.positionsLiquidated = ZERO;
    d.penalties = ZERO;
    d.badDebt = ZERO;
    d.collateralOpened = ZERO;
    d.goldPriceClose = ZERO;
  }
  return d as ProtocolDayData;
}

export function eventId(event: ethereum.Event): string {
  return event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
}
