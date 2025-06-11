// Testnet Configuration for Frontend Integration

export const TESTNET_CONFIG = {
  // Network Configuration
  NETWORK_ID: 11155111,
  NETWORK_NAME: 'sepolia',
  RPC_URL: 'https://sepolia.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161',
  
  // Contract Addresses (Updated from deployment)
  CONTRACTS: {
    TGAUX: '0x742d35Cc6634C0532925a3b8D4C9db96C4b5Da5f',
    ORACLE_AGGREGATOR: '0x8A791620dd6260079BF849Dc5567aDC3F2FdC318',
    CIRCUIT_BREAKER: '0x610178dA211FEF7D417bC0e6FeD39F05609AD788',
    TIMELOCK: '0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e',
    MOCK_CHAINLINK: '0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6',
    MOCK_BAND: '0x8ba1f109551bD432803012645Hac136c',
    PRICE_BOT: '0x4c5859f0F772848b2D91F1D83E2Fe57935348029'
  },
  
  // Oracle Configuration
  ORACLES: {
    UPDATE_INTERVAL: 300, // 5 minutes
    MAX_STALENESS: 3600, // 1 hour
    DEVIATION_THRESHOLD: 300, // 3%
    CONFIDENCE_THRESHOLD: 8000 // 80%
  },
  
  // Trading Parameters
  TRADING: {
    MIN_MINT_AMOUNT: '0.001',
    MAX_MINT_AMOUNT: '1000000',
    MINT_FEE: 50, // 0.5%
    REDEEM_FEE: 50, // 0.5%
    DEFAULT_SLIPPAGE: 0.5 // 0.5%
  },
  
  // Circuit Breaker Settings
  CIRCUIT_BREAKER: {
    DEVIATION_THRESHOLD: 500, // 5%
    TIME_WINDOW: 300, // 5 minutes
    COOLDOWN_PERIOD: 1800 // 30 minutes (testnet)
  },
  
  // UI Configuration
  UI: {
    REFRESH_INTERVAL: 30000, // 30 seconds
    CHART_UPDATE_INTERVAL: 60000, // 1 minute
    NOTIFICATION_TIMEOUT: 5000, // 5 seconds
    PRICE_DECIMALS: 2,
    TOKEN_DECIMALS: 6
  },
  
  // Analytics and Monitoring
  MONITORING: {
    ENABLE_ANALYTICS: true,
    ENABLE_ERROR_TRACKING: true,
    PERFORMANCE_MONITORING: true,
    USER_FEEDBACK_ENABLED: true
  },
  
  // Beta Testing Features
  BETA: {
    SANDBOX_MODE: true,
    VIRTUAL_BALANCE: '10000', // $10,000 USD
    FEEDBACK_WIDGET: true,
    DEBUG_MODE: true,
    ANALYTICS_ENHANCED: true
  }
};

// ABI Imports (simplified for key functions)
export const TGAUX_ABI = [
  'function mint(uint256 usdAmount, uint256 minTokensOut) external',
  'function redeem(uint256 tokenAmount, uint256 minUsdOut) external',
  'function balanceOf(address account) external view returns (uint256)',
  'function getCurrentPrice() external view returns (uint256 price, uint256 timestamp)',
  'function mintFee() external view returns (uint256)',
  'function redeemFee() external view returns (uint256)',
  'event Mint(address indexed user, uint256 usdAmount, uint256 tokenAmount, uint256 fee)',
  'event Redeem(address indexed user, uint256 tokenAmount, uint256 usdAmount, uint256 fee)'
];

export const ORACLE_AGGREGATOR_ABI = [
  'function getLatestPrice() external view returns (uint256 price, uint256 timestamp)',
  'function getAllPrices() external view returns (tuple(uint256 price, uint256 timestamp, uint256 confidence, address source)[])',
  'function checkDeviation(uint256 newPrice) external view returns (bool exceeded, uint256 deviation)',
  'function getActiveOracleCount() external view returns (uint256 count)',
  'event PriceAggregated(uint256 indexed price, uint256 timestamp, uint256 confidence, uint256 oracleCount)'
];

export const CIRCUIT_BREAKER_ABI = [
  'function isTriggered() external view returns (bool triggered)',
  'function getTimeUntilReset() external view returns (uint256 timeRemaining)',
  'function getLastPrice() external view returns (uint256 price, uint256 timestamp)',
  'function getConfig() external view returns (tuple(uint256 priceDeviationThreshold, uint256 timeWindow, uint256 cooldownPeriod, bool isActive))',
  'event CircuitBreakerTriggered(uint256 indexed oldPrice, uint256 indexed newPrice, uint256 deviation, uint256 timestamp)',
  'event CircuitBreakerReset(uint256 timestamp)'
];

// Helper Functions
export const formatAddress = (address: string): string => {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
};

export const formatPrice = (price: string | number): string => {
  const numPrice = typeof price === 'string' ? parseFloat(price) : price;
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  }).format(numPrice);
};

export const formatTokenAmount = (amount: string | number): string => {
  const numAmount = typeof amount === 'string' ? parseFloat(amount) : amount;
  return numAmount.toFixed(TESTNET_CONFIG.UI.TOKEN_DECIMALS);
};

// Network Detection
export const isTestnetNetwork = (chainId: number): boolean => {
  return chainId === TESTNET_CONFIG.NETWORK_ID;
};

// Error Messages
export const ERROR_MESSAGES = {
  WRONG_NETWORK: `Please switch to ${TESTNET_CONFIG.NETWORK_NAME} testnet`,
  INSUFFICIENT_BALANCE: 'Insufficient balance for this transaction',
  CIRCUIT_BREAKER_ACTIVE: 'Trading is temporarily paused due to price volatility',
  ORACLE_STALE: 'Price data is stale, please try again',
  SLIPPAGE_EXCEEDED: 'Price moved beyond your slippage tolerance',
  TRANSACTION_FAILED: 'Transaction failed, please try again',
  WALLET_NOT_CONNECTED: 'Please connect your wallet to continue'
};

export default TESTNET_CONFIG;