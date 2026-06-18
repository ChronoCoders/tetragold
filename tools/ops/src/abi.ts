import { parseAbi } from "viem";

export const oracleAbi = parseAbi([
  "function lastPrice() view returns (uint256)",
  "function lastUpdateTime() view returns (uint256)",
  "function paused() view returns (bool)",
  "function priceDeviationThreshold() view returns (uint256)",
  "function circuitBreakerThreshold() view returns (uint256)",
  "function MIN_UPDATE_INTERVAL() view returns (uint256)",
  "function MAX_PRICE_AGE() view returns (uint256)",
  "function updateTwap()",
  "event PriceUpdated(uint256 price, uint256 timestamp)",
  "event CircuitBreakerTriggered(uint256 oldPrice, uint256 newPrice, uint256 deviation)",
  "event OracleFailed(string oracleName, string reason)",
]);

export const vaultAbi = parseAbi([
  "function totalValueLocked() view returns (uint256)",
  "function activePositionCount() view returns (uint256)",
  "function nextPositionId() view returns (uint256)",
  "function getActivePositionIds() view returns (uint256[])",
  "function getActivePositionIds(uint256 offset, uint256 limit) view returns (uint256[], uint256)",
  "function getPositionHealth(uint256 positionId) view returns (uint256)",
  "function isLiquidatable(uint256 positionId) view returns (bool)",
  "function getPosition(uint256 positionId) view returns ((address owner,uint256 collateralAmount,address collateralToken,uint256 tgauxMinted,uint256 borrowedAmount,uint256 leverage,uint256 openPrice,uint256 lastUpdateTimestamp,bool isActive))",
  "function paused() view returns (bool)",
  "event BadDebtRealized(uint256 indexed positionId, address indexed token, uint256 shortfall)",
]);

export const poolAbi = parseAbi([
  "function getPoolInfo(uint8 poolType) view returns (uint256 deposits, uint256 borrowed, uint256 utilization, address lpToken, uint256 lpPrice)",
  "function paused() view returns (bool)",
]);

export const liquidationEngineAbi = parseAbi([
  "function checkUpkeep(bytes checkData) view returns (bool upkeepNeeded, bytes performData)",
  "function performUpkeep(bytes performData)",
  "function getLiquidatablePositions() view returns (uint256[])",
  "function markForLiquidation(uint256 positionId)",
  "function liquidatePosition(uint256 positionId) returns (uint256)",
  "function getPositionLiquidationInfo(uint256 positionId) view returns ((bool isMarked,uint256 markedTime,uint256 tranchesLiquidated,uint256 totalPenalty,bool canLiquidate))",
  "function totalLiquidations() view returns (uint256)",
  "function totalPenaltiesCollected() view returns (uint256)",
  "function GRACE_PERIOD() view returns (uint256)",
  "function MARK_VALIDITY() view returns (uint256)",
  "function paused() view returns (bool)",
  "event PositionMarkedForLiquidation(uint256 indexed positionId, uint256 timestamp)",
  "event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 penalty, uint256 portion)",
]);

export const insuranceAbi = parseAbi([
  "function getTotalReserves() view returns (uint256)",
  "function getTargetReserve() view returns (uint256)",
  "function getFundHealth() view returns (uint8)",
  "function paused() view returns (bool)",
]);

export const tgauxAbi = parseAbi([
  "function totalSupply() view returns (uint256)",
]);

export const FUND_HEALTH = ["CRITICAL", "WARNING", "HEALTHY", "OVERCAPITALIZED"] as const;
