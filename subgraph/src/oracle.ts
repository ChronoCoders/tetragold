import { PriceUpdated, CircuitBreakerTriggered } from "../generated/OracleAggregator/OracleAggregator";
import { OraclePrice, CircuitBreakerEvent } from "../generated/schema";
import { getProtocol, getDayData, eventId, ONE } from "./helpers";

export function handlePriceUpdated(event: PriceUpdated): void {
  let price = new OraclePrice(eventId(event));
  price.price = event.params.price;
  price.timestamp = event.params.timestamp;
  price.block = event.block.number;
  price.tx = event.transaction.hash;
  price.save();

  let p = getProtocol();
  p.lastGoldPrice = event.params.price;
  p.lastPriceUpdate = event.params.timestamp;
  p.save();

  let day = getDayData(event);
  day.goldPriceClose = event.params.price;
  day.save();
}

export function handleCircuitBreaker(event: CircuitBreakerTriggered): void {
  let cb = new CircuitBreakerEvent(eventId(event));
  cb.oldPrice = event.params.oldPrice;
  cb.newPrice = event.params.newPrice;
  cb.deviation = event.params.deviation;
  cb.timestamp = event.block.timestamp;
  cb.tx = event.transaction.hash;
  cb.save();

  let p = getProtocol();
  p.circuitBreakerTrips = p.circuitBreakerTrips.plus(ONE);
  p.save();
}
