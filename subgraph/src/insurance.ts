import {
  FundsDeposited,
  CoverageProvided,
  FundHealthUpdated,
  Rebalanced,
} from "../generated/InsuranceFund/InsuranceFund";
import { InsuranceEvent } from "../generated/schema";
import { eventId } from "./helpers";

export function handleFundsDeposited(event: FundsDeposited): void {
  let e = new InsuranceEvent(eventId(event));
  e.kind = "DEPOSIT";
  e.amount = event.params.amount;
  e.token = event.params.token;
  e.timestamp = event.block.timestamp;
  e.tx = event.transaction.hash;
  e.save();
}

export function handleCoverageProvided(event: CoverageProvided): void {
  let e = new InsuranceEvent(eventId(event));
  e.kind = "COVERAGE";
  e.amount = event.params.amount;
  e.positionId = event.params.positionId;
  e.timestamp = event.block.timestamp;
  e.tx = event.transaction.hash;
  e.save();
}

export function handleFundHealthUpdated(event: FundHealthUpdated): void {
  let e = new InsuranceEvent(eventId(event));
  e.kind = "HEALTH";
  e.oldHealth = event.params.oldHealth;
  e.newHealth = event.params.newHealth;
  e.timestamp = event.block.timestamp;
  e.tx = event.transaction.hash;
  e.save();
}

export function handleRebalanced(event: Rebalanced): void {
  let e = new InsuranceEvent(eventId(event));
  e.kind = "REBALANCE";
  e.amount = event.params.deployed;
  e.token = event.params.token;
  e.timestamp = event.block.timestamp;
  e.tx = event.transaction.hash;
  e.save();
}
