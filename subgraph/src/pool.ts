import {
  LPDeposit,
  LPWithdrawal,
  Borrowed,
  Repaid,
  UtilizationUpdated,
} from "../generated/LiquidityPool/LiquidityPool";
import { LpDeposit } from "../generated/schema";
import { getPool, getUser, eventId, ONE } from "./helpers";

export function handleLpDeposit(event: LPDeposit): void {
  let pool = getPool(event.params.poolType);
  let user = getUser(event.params.user);

  let dep = new LpDeposit(eventId(event));
  dep.user = user.id;
  dep.pool = pool.id;
  dep.amount = event.params.amount;
  dep.lpTokens = event.params.lpTokens;
  dep.token = event.params.token;
  dep.isWithdrawal = false;
  dep.timestamp = event.block.timestamp;
  dep.tx = event.transaction.hash;
  dep.save();

  pool.netDeposited = pool.netDeposited.plus(event.params.amount);
  pool.depositCount = pool.depositCount.plus(ONE);
  pool.save();
}

export function handleLpWithdrawal(event: LPWithdrawal): void {
  let pool = getPool(event.params.poolType);
  let user = getUser(event.params.user);

  let dep = new LpDeposit(eventId(event));
  dep.user = user.id;
  dep.pool = pool.id;
  dep.amount = event.params.amount;
  dep.lpTokens = event.params.lpTokens;
  dep.token = event.params.token;
  dep.isWithdrawal = true;
  dep.timestamp = event.block.timestamp;
  dep.tx = event.transaction.hash;
  dep.save();

  pool.netDeposited = pool.netDeposited.minus(event.params.amount);
  pool.withdrawalCount = pool.withdrawalCount.plus(ONE);
  pool.save();
}

export function handleBorrowed(event: Borrowed): void {
  let pool = getPool(event.params.poolType);
  pool.totalBorrowed = pool.totalBorrowed.plus(event.params.amount);
  pool.borrowCount = pool.borrowCount.plus(ONE);
  pool.save();
}

export function handleRepaid(event: Repaid): void {
  let pool = getPool(event.params.poolType);
  pool.totalBorrowed = pool.totalBorrowed.minus(event.params.amount);
  pool.repayCount = pool.repayCount.plus(ONE);
  pool.save();
}

export function handleUtilizationUpdated(event: UtilizationUpdated): void {
  let pool = getPool(event.params.poolType);
  pool.utilization = event.params.newRate;
  pool.save();
}
