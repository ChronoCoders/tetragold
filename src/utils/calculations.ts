// Gas estimation utilities
export const estimateGasPrice = (): Promise<number> => {
  return new Promise((resolve) => {
    // Simulate gas price estimation
    setTimeout(() => {
      const baseGas = 20; // Base gas price in gwei
      const networkCongestion = Math.random() * 10; // Random congestion factor
      resolve(Math.round(baseGas + networkCongestion));
    }, 500);
  });
};

export const estimateTransactionCost = (gasPrice: number, gasLimit: number = 150000): number => {
  // Calculate transaction cost in ETH
  return (gasPrice * gasLimit) / 1e9; // Convert from gwei to ETH
};

// Slippage calculations
export const calculateSlippage = (amount: number, slippageTolerance: number): number => {
  return amount * (slippageTolerance / 100);
};

export const calculateMinimumReceived = (amount: number, slippageTolerance: number): number => {
  return amount - calculateSlippage(amount, slippageTolerance);
};

export const calculateMaximumSent = (amount: number, slippageTolerance: number): number => {
  return amount + calculateSlippage(amount, slippageTolerance);
};

// Price impact calculations
export const calculatePriceImpact = (tradeAmount: number, liquidity: number): number => {
  // Simplified price impact calculation
  const impact = (tradeAmount / liquidity) * 100;
  return Math.min(impact, 15); // Cap at 15%
};

// Format utilities
export const formatCurrency = (amount: number, currency: string = 'USD'): string => {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency,
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  }).format(amount);
};

export const formatPercentage = (value: number, decimals: number = 2): string => {
  return `${value >= 0 ? '+' : ''}${value.toFixed(decimals)}%`;
};

export const formatNumber = (value: number, decimals: number = 2): string => {
  if (value >= 1e9) {
    return `${(value / 1e9).toFixed(decimals)}B`;
  } else if (value >= 1e6) {
    return `${(value / 1e6).toFixed(decimals)}M`;
  } else if (value >= 1e3) {
    return `${(value / 1e3).toFixed(decimals)}K`;
  }
  return value.toFixed(decimals);
};

// Validation utilities
export const validateAmount = (amount: string, balance: number): string | null => {
  const numAmount = parseFloat(amount);
  
  if (isNaN(numAmount) || numAmount <= 0) {
    return 'Please enter a valid amount';
  }
  
  if (numAmount > balance) {
    return 'Insufficient balance';
  }
  
  return null;
};

export const validateSlippage = (slippage: number): string | null => {
  if (slippage < 0.1) {
    return 'Slippage too low - transaction may fail';
  }
  
  if (slippage > 10) {
    return 'Slippage too high - consider reducing';
  }
  
  return null;
};