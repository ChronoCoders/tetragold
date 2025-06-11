import React, { useState, useEffect } from 'react';
import { ArrowUpDown, Settings, AlertTriangle, CheckCircle, Loader, DollarSign, Coins } from 'lucide-react';
import { useGoldPrice } from '../hooks/useGoldPrice';
import { 
  estimateGasPrice, 
  estimateTransactionCost, 
  calculateMinimumReceived, 
  calculateMaximumSent,
  calculatePriceImpact,
  formatCurrency,
  formatPercentage,
  validateAmount,
  validateSlippage
} from '../utils/calculations';

type TradeType = 'mint' | 'redeem';

const TradingPanel: React.FC = () => {
  const { currentData } = useGoldPrice();
  const [tradeType, setTradeType] = useState<TradeType>('mint');
  const [amount, setAmount] = useState('');
  const [slippageTolerance, setSlippageTolerance] = useState(0.5);
  const [showSettings, setShowSettings] = useState(false);
  const [gasPrice, setGasPrice] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Mock user balance
  const [userBalance] = useState({
    eth: 2.5,
    tgaux: 150.75,
    usd: 8500
  });

  useEffect(() => {
    estimateGasPrice().then(setGasPrice);
  }, []);

  const handleAmountChange = (value: string) => {
    setAmount(value);
    setError(null);
  };

  const handleMaxClick = () => {
    if (tradeType === 'mint') {
      setAmount((userBalance.usd / currentData.price).toFixed(6));
    } else {
      setAmount(userBalance.tgaux.toString());
    }
  };

  const handleTradeTypeSwitch = () => {
    setTradeType(prev => prev === 'mint' ? 'redeem' : 'mint');
    setAmount('');
    setError(null);
  };

  const validateTransaction = (): string | null => {
    const numAmount = parseFloat(amount);
    
    if (!amount || isNaN(numAmount) || numAmount <= 0) {
      return 'Please enter a valid amount';
    }

    if (tradeType === 'mint') {
      const requiredUSD = numAmount * currentData.price;
      if (requiredUSD > userBalance.usd) {
        return 'Insufficient USD balance';
      }
    } else {
      if (numAmount > userBalance.tgaux) {
        return 'Insufficient TGAUx balance';
      }
    }

    const slippageError = validateSlippage(slippageTolerance);
    if (slippageError) return slippageError;

    return null;
  };

  const handleTrade = async () => {
    const validationError = validateTransaction();
    if (validationError) {
      setError(validationError);
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      // Simulate transaction
      await new Promise(resolve => setTimeout(resolve, 2000));
      
      // Reset form on success
      setAmount('');
      alert(`${tradeType === 'mint' ? 'Mint' : 'Redeem'} transaction successful!`);
    } catch (err) {
      setError('Transaction failed. Please try again.');
    } finally {
      setIsLoading(false);
    }
  };

  const numAmount = parseFloat(amount) || 0;
  const outputAmount = tradeType === 'mint' ? numAmount : numAmount * currentData.price;
  const priceImpact = calculatePriceImpact(numAmount * currentData.price, 10000000); // $10M liquidity
  const transactionCost = estimateTransactionCost(gasPrice);
  
  const minReceived = tradeType === 'mint' 
    ? calculateMinimumReceived(numAmount, slippageTolerance)
    : calculateMinimumReceived(outputAmount, slippageTolerance);

  return (
    <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6">
      <div className="flex items-center justify-between mb-6">
        <h2 className="text-xl font-bold text-gray-900 dark:text-white">Trade TGAUx</h2>
        <button
          onClick={() => setShowSettings(!showSettings)}
          className="p-2 text-gray-500 hover:text-amber-600 transition-colors"
        >
          <Settings className="h-5 w-5" />
        </button>
      </div>

      {/* Settings Panel */}
      {showSettings && (
        <div className="mb-6 p-4 bg-gray-50 dark:bg-gray-700 rounded-lg">
          <div className="flex items-center justify-between mb-3">
            <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
              Slippage Tolerance
            </label>
            <span className="text-sm text-gray-500">{slippageTolerance}%</span>
          </div>
          <div className="flex space-x-2 mb-3">
            {[0.1, 0.5, 1.0].map((value) => (
              <button
                key={value}
                onClick={() => setSlippageTolerance(value)}
                className={`px-3 py-1 rounded text-sm ${
                  slippageTolerance === value
                    ? 'bg-amber-600 text-white'
                    : 'bg-gray-200 dark:bg-gray-600 text-gray-700 dark:text-gray-300'
                }`}
              >
                {value}%
              </button>
            ))}
          </div>
          <input
            type="range"
            min="0.1"
            max="5"
            step="0.1"
            value={slippageTolerance}
            onChange={(e) => setSlippageTolerance(parseFloat(e.target.value))}
            className="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer"
          />
        </div>
      )}

      {/* Trade Type Selector */}
      <div className="flex bg-gray-100 dark:bg-gray-700 rounded-lg p-1 mb-6">
        <button
          onClick={() => setTradeType('mint')}
          className={`flex-1 py-2 px-4 rounded-md text-sm font-medium transition-colors ${
            tradeType === 'mint'
              ? 'bg-amber-600 text-white'
              : 'text-gray-600 dark:text-gray-300'
          }`}
        >
          Mint TGAUx
        </button>
        <button
          onClick={() => setTradeType('redeem')}
          className={`flex-1 py-2 px-4 rounded-md text-sm font-medium transition-colors ${
            tradeType === 'redeem'
              ? 'bg-amber-600 text-white'
              : 'text-gray-600 dark:text-gray-300'
          }`}
        >
          Redeem TGAUx
        </button>
      </div>

      {/* Input Section */}
      <div className="space-y-4 mb-6">
        <div className="bg-gray-50 dark:bg-gray-700 rounded-lg p-4">
          <div className="flex items-center justify-between mb-2">
            <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
              {tradeType === 'mint' ? 'You Pay' : 'You Redeem'}
            </label>
            <span className="text-sm text-gray-500">
              Balance: {tradeType === 'mint' 
                ? formatCurrency(userBalance.usd) 
                : `${userBalance.tgaux.toFixed(6)} TGAUx`
              }
            </span>
          </div>
          
          <div className="flex items-center space-x-3">
            <input
              type="number"
              value={amount}
              onChange={(e) => handleAmountChange(e.target.value)}
              placeholder="0.00"
              className="flex-1 bg-transparent text-2xl font-semibold text-gray-900 dark:text-white placeholder-gray-400 border-none outline-none"
            />
            <div className="flex items-center space-x-2">
              <div className="flex items-center space-x-1 text-gray-700 dark:text-gray-300">
                {tradeType === 'mint' ? (
                  <DollarSign className="h-5 w-5" />
                ) : (
                  <Coins className="h-5 w-5" />
                )}
                <span className="font-medium">
                  {tradeType === 'mint' ? 'USD' : 'TGAUx'}
                </span>
              </div>
              <button
                onClick={handleMaxClick}
                className="px-2 py-1 bg-amber-600 text-white text-xs rounded hover:bg-amber-700 transition-colors"
              >
                MAX
              </button>
            </div>
          </div>
        </div>

        {/* Swap Arrow */}
        <div className="flex justify-center">
          <button
            onClick={handleTradeTypeSwitch}
            className="p-2 bg-gray-100 dark:bg-gray-700 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
          >
            <ArrowUpDown className="h-5 w-5 text-gray-600 dark:text-gray-300" />
          </button>
        </div>

        {/* Output Section */}
        <div className="bg-gray-50 dark:bg-gray-700 rounded-lg p-4">
          <div className="flex items-center justify-between mb-2">
            <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
              {tradeType === 'mint' ? 'You Receive' : 'You Get'}
            </label>
            <span className="text-sm text-gray-500">
              Rate: {formatCurrency(currentData.price)}
            </span>
          </div>
          
          <div className="flex items-center justify-between">
            <div className="text-2xl font-semibold text-gray-900 dark:text-white">
              {outputAmount.toFixed(6)}
            </div>
            <div className="flex items-center space-x-1 text-gray-700 dark:text-gray-300">
              {tradeType === 'mint' ? (
                <Coins className="h-5 w-5" />
              ) : (
                <DollarSign className="h-5 w-5" />
              )}
              <span className="font-medium">
                {tradeType === 'mint' ? 'TGAUx' : 'USD'}
              </span>
            </div>
          </div>
        </div>
      </div>

      {/* Transaction Details */}
      {numAmount > 0 && (
        <div className="bg-gray-50 dark:bg-gray-700 rounded-lg p-4 mb-6 space-y-2">
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">Price Impact</span>
            <span className={`${priceImpact > 1 ? 'text-red-600' : 'text-green-600'}`}>
              {formatPercentage(priceImpact)}
            </span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">Minimum Received</span>
            <span className="text-gray-900 dark:text-white">
              {minReceived.toFixed(6)} {tradeType === 'mint' ? 'TGAUx' : 'USD'}
            </span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">Network Fee</span>
            <span className="text-gray-900 dark:text-white">
              ~{transactionCost.toFixed(6)} ETH (${gasPrice} gwei)
            </span>
          </div>
        </div>
      )}

      {/* Error Message */}
      {error && (
        <div className="mb-4 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg flex items-center">
          <AlertTriangle className="h-5 w-5 text-red-600 mr-2" />
          <span className="text-red-700 dark:text-red-400 text-sm">{error}</span>
        </div>
      )}

      {/* Trade Button */}
      <button
        onClick={handleTrade}
        disabled={isLoading || !amount || !!validateTransaction()}
        className="w-full bg-amber-600 hover:bg-amber-700 disabled:bg-gray-300 disabled:cursor-not-allowed text-white font-medium py-3 px-4 rounded-lg transition-colors flex items-center justify-center"
      >
        {isLoading ? (
          <>
            <Loader className="animate-spin h-5 w-5 mr-2" />
            Processing...
          </>
        ) : (
          <>
            <CheckCircle className="h-5 w-5 mr-2" />
            {tradeType === 'mint' ? 'Mint TGAUx' : 'Redeem TGAUx'}
          </>
        )}
      </button>

      {/* Disclaimer */}
      <div className="mt-4 text-xs text-gray-500 dark:text-gray-400 text-center">
        Transactions are subject to network congestion and gas fees. 
        Always verify transaction details before confirming.
      </div>
    </div>
  );
};

export default TradingPanel;