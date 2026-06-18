import { BigInt } from "@graphprotocol/graph-ts";
import {
  PositionOpened,
  PositionClosed,
  CollateralAdded,
  PositionLiquidated,
  BadDebtRealized,
  VaultManager,
} from "../generated/VaultManager/VaultManager";
import { Position, BadDebt } from "../generated/schema";
import { getProtocol, getUser, getDayData, eventId, ZERO, ONE } from "./helpers";

export function handlePositionOpened(event: PositionOpened): void {
  let id = event.params.positionId.toString();
  let user = getUser(event.params.owner);

  let position = new Position(id);
  position.positionId = event.params.positionId;
  position.owner = user.id;
  position.collateral = event.params.collateral;
  position.leverage = event.params.leverage;
  position.tgauxMinted = event.params.tgauxMinted;
  position.borrowedAmount = ZERO;
  position.openPrice = ZERO;
  position.status = "OPEN";
  position.collateralSeized = ZERO;
  position.badDebt = ZERO;
  position.tranchesLiquidated = 0;
  position.openedAt = event.block.timestamp;
  position.openedTx = event.transaction.hash;

  let vault = VaultManager.bind(event.address);
  let res = vault.try_getPosition(event.params.positionId);
  if (!res.reverted) {
    position.collateralToken = res.value.collateralToken;
    position.openPrice = res.value.openPrice;
    position.borrowedAmount = res.value.borrowedAmount;
  }
  position.save();

  user.positionsOpened = user.positionsOpened.plus(ONE);
  user.save();

  let p = getProtocol();
  p.totalPositionsOpened = p.totalPositionsOpened.plus(ONE);
  p.openPositionCount = p.openPositionCount.plus(ONE);
  p.totalCollateralOpened = p.totalCollateralOpened.plus(event.params.collateral);
  p.totalTgauxMinted = p.totalTgauxMinted.plus(event.params.tgauxMinted);
  p.save();

  let day = getDayData(event);
  day.positionsOpened = day.positionsOpened.plus(ONE);
  day.collateralOpened = day.collateralOpened.plus(event.params.collateral);
  day.save();
}

export function handlePositionClosed(event: PositionClosed): void {
  let position = Position.load(event.params.positionId.toString());
  if (position == null) return;

  if (position.status == "OPEN") {
    position.status = "CLOSED";
    position.returnAmount = event.params.returnAmount;
    position.closedAt = event.block.timestamp;
    position.save();

    let p = getProtocol();
    p.totalPositionsClosed = p.totalPositionsClosed.plus(ONE);
    if (p.openPositionCount.gt(ZERO)) p.openPositionCount = p.openPositionCount.minus(ONE);
    p.save();

    let day = getDayData(event);
    day.positionsClosed = day.positionsClosed.plus(ONE);
    day.save();
  }
}

export function handleCollateralAdded(event: CollateralAdded): void {
  let position = Position.load(event.params.positionId.toString());
  if (position == null) return;
  position.collateral = position.collateral.plus(event.params.amount);
  position.save();
}

export function handleVaultPositionLiquidated(event: PositionLiquidated): void {
  let position = Position.load(event.params.positionId.toString());
  if (position == null) return;
  position.collateralSeized = position.collateralSeized.plus(event.params.collateralSeized);
  position.save();
}

export function handleBadDebtRealized(event: BadDebtRealized): void {
  let position = Position.load(event.params.positionId.toString());
  if (position == null) return;

  let bd = new BadDebt(eventId(event));
  bd.position = position.id;
  bd.token = event.params.token;
  bd.shortfall = event.params.shortfall;
  bd.timestamp = event.block.timestamp;
  bd.tx = event.transaction.hash;
  bd.save();

  position.badDebt = position.badDebt.plus(event.params.shortfall);
  position.save();

  let p = getProtocol();
  p.totalBadDebt = p.totalBadDebt.plus(event.params.shortfall);
  p.save();

  let day = getDayData(event);
  day.badDebt = day.badDebt.plus(event.params.shortfall);
  day.save();
}
