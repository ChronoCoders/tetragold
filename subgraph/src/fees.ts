import { FeesCollected } from "../generated/FeeDistributor/FeeDistributor";
import { FeeEvent } from "../generated/schema";
import { eventId } from "./helpers";

export function handleFeesCollected(event: FeesCollected): void {
  let e = new FeeEvent(eventId(event));
  e.source = "FeeDistributor";
  e.token = event.params.token;
  e.total = event.params.total;
  e.toInsurance = event.params.toInsurance;
  e.toTreasury = event.params.toTreasury;
  e.toStakers = event.params.toStakers;
  e.timestamp = event.block.timestamp;
  e.tx = event.transaction.hash;
  e.save();
}
