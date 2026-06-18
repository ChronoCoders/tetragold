import { BigInt } from "@graphprotocol/graph-ts";
import {
  PositionLiquidated,
  PositionMarkedForLiquidation,
  LiquidationMarkCleared,
} from "../generated/LiquidationEngine/LiquidationEngine";
import { Position, Liquidation, LiquidationMark } from "../generated/schema";
import { getProtocol, getUser, getDayData, eventId, ZERO, ONE } from "./helpers";

const MAX_TRANCHES = 4;
const BASIS_POINTS = 10000;
const LIQUIDATOR_SHARE = 5000;

export function handleEngineLiquidation(event: PositionLiquidated): void {
  let position = Position.load(event.params.positionId.toString());
  if (position == null) return;

  let liq = new Liquidation(eventId(event));
  liq.position = position.id;
  liq.liquidator = event.params.liquidator;
  liq.penalty = event.params.penalty;
  liq.portion = event.params.portion;
  liq.timestamp = event.block.timestamp;
  liq.block = event.block.number;
  liq.tx = event.transaction.hash;
  liq.save();

  position.tranchesLiquidated = position.tranchesLiquidated + 1;

  let settled =
    event.params.portion.toI32() >= BASIS_POINTS || position.tranchesLiquidated >= MAX_TRANCHES;
  if (settled && position.status == "OPEN") {
    position.status = "LIQUIDATED";
    position.closedAt = event.block.timestamp;
  }
  position.save();

  let liquidatorReward = event.params.penalty.times(BigInt.fromI32(LIQUIDATOR_SHARE)).div(BigInt.fromI32(BASIS_POINTS));
  let liquidator = getUser(event.params.liquidator);
  liquidator.liquidationsPerformed = liquidator.liquidationsPerformed.plus(ONE);
  liquidator.penaltiesEarned = liquidator.penaltiesEarned.plus(liquidatorReward);
  liquidator.save();

  let p = getProtocol();
  p.totalLiquidations = p.totalLiquidations.plus(ONE);
  p.totalPenaltiesCollected = p.totalPenaltiesCollected.plus(event.params.penalty);
  if (settled) {
    p.totalPositionsLiquidated = p.totalPositionsLiquidated.plus(ONE);
    if (p.openPositionCount.gt(ZERO)) p.openPositionCount = p.openPositionCount.minus(ONE);
  }
  p.save();

  let day = getDayData(event);
  day.penalties = day.penalties.plus(event.params.penalty);
  if (settled) day.positionsLiquidated = day.positionsLiquidated.plus(ONE);
  day.save();
}

export function handleMarked(event: PositionMarkedForLiquidation): void {
  let position = Position.load(event.params.positionId.toString());
  if (position == null) return;

  let mark = new LiquidationMark(event.params.positionId.toString());
  mark.position = position.id;
  mark.markedTime = event.params.timestamp;
  mark.cleared = false;
  mark.clearedAt = null;
  mark.timestamp = event.block.timestamp;
  mark.tx = event.transaction.hash;
  mark.save();
}

export function handleMarkCleared(event: LiquidationMarkCleared): void {
  let mark = LiquidationMark.load(event.params.positionId.toString());
  if (mark == null) return;
  mark.cleared = true;
  mark.clearedAt = event.block.timestamp;
  mark.save();
}
