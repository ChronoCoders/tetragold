import React from 'react';
import { TrendingUp, TrendingDown, DollarSign, Coins, BarChart3, Shield, Clock, RefreshCw } from 'lucide-react';
import { useGoldPrice } from '../hooks/useGoldPrice';
import { formatCurrency, formatPercentage, formatNumber } from '../utils/calculations';

const MetricsPanel: React.FC = () => {
  const { currentData, isLoading, refresh } = useGoldPrice();

  const metrics = [
    {
      title: 'Current Price',
      value: formatCurrency(currentData.price),
      change: currentData.changePercent24h,
      icon: DollarSign,
      color: 'amber'
    },
    {
      title: '24h Change',
      value: formatCurrency(Math.abs(currentData.change24h)),
      change: currentData.changePercent24h,
      icon: currentData.changePercent24h >= 0 ? TrendingUp : TrendingDown,
      color: currentData.changePercent24h >= 0 ? 'green' : 'red'
    },
    {
      title: 'Market Cap',
      value: `$${formatNumber(currentData.marketCap)}`,
      change: currentData.changePercent24h,
      icon: BarChart3,
      color: 'blue'
    },
    {
      title: 'Total Supply',
      value: formatNumber(currentData.totalSupply),
      change: 0,
      icon: Coins,
      color: 'purple'
    },
    {
      title: '24h Volume',
      value: `$${formatNumber(currentData.volume24h)}`,
      change: Math.random() * 20 - 10, // Simulated volume change
      icon: BarChart3,
      color: 'indigo'
    },
    {
      title: 'Backing Ratio',
      value: `${currentData.backingRatio.toFixed(1)}%`,
      change: 0,
      icon: Shield,
      color: 'emerald'
    }
  ];

  const getColorClasses = (color: string, isBackground: boolean = false) => {
    const prefix = isBackground ? 'bg' : 'text';
    const colorMap: Record<string, string> = {
      amber: `${prefix}-amber-600`,
      green: `${prefix}-green-600`,
      red: `${prefix}-red-600`,
      blue: `${prefix}-blue-600`,
      purple: `${prefix}-purple-600`,
      indigo: `${prefix}-indigo-600`,
      emerald: `${prefix}-emerald-600`
    };
    return colorMap[color] || `${prefix}-gray-600`;
  };

  return (
    <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6">
      <div className="flex items-center justify-between mb-6">
        <h2 className="text-xl font-bold text-gray-900 dark:text-white">Market Overview</h2>
        <div className="flex items-center space-x-2">
          <div className="flex items-center text-sm text-gray-500 dark:text-gray-400">
            <Clock className="h-4 w-4 mr-1" />
            <span>Last updated: {new Date(currentData.timestamp).toLocaleTimeString()}</span>
          </div>
          <button
            onClick={refresh}
            disabled={isLoading}
            className="p-2 text-gray-500 hover:text-amber-600 transition-colors disabled:opacity-50"
          >
            <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {metrics.map((metric, index) => {
          const Icon = metric.icon;
          const isPositive = metric.change >= 0;
          
          return (
            <div
              key={index}
              className="bg-gray-50 dark:bg-gray-700 rounded-lg p-4 hover:shadow-md transition-shadow"
            >
              <div className="flex items-center justify-between mb-2">
                <div className={`p-2 rounded-lg ${getColorClasses(metric.color, true)} bg-opacity-10`}>
                  <Icon className={`h-5 w-5 ${getColorClasses(metric.color)}`} />
                </div>
                {metric.change !== 0 && (
                  <div className={`flex items-center text-sm ${isPositive ? 'text-green-600' : 'text-red-600'}`}>
                    {isPositive ? (
                      <TrendingUp className="h-3 w-3 mr-1" />
                    ) : (
                      <TrendingDown className="h-3 w-3 mr-1" />
                    )}
                    <span>{formatPercentage(Math.abs(metric.change))}</span>
                  </div>
                )}
              </div>
              
              <div className="text-sm text-gray-600 dark:text-gray-400 mb-1">
                {metric.title}
              </div>
              
              <div className="text-2xl font-bold text-gray-900 dark:text-white">
                {metric.value}
              </div>
            </div>
          );
        })}
      </div>

      <div className="mt-6 grid grid-cols-1 md:grid-cols-2 gap-4">
        <div className="bg-gradient-to-r from-amber-50 to-yellow-50 dark:from-amber-900/20 dark:to-yellow-900/20 rounded-lg p-4">
          <div className="flex items-center mb-2">
            <TrendingUp className="h-5 w-5 text-green-600 mr-2" />
            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">24h High</span>
          </div>
          <div className="text-xl font-bold text-gray-900 dark:text-white">
            {formatCurrency(currentData.high24h)}
          </div>
        </div>

        <div className="bg-gradient-to-r from-red-50 to-pink-50 dark:from-red-900/20 dark:to-pink-900/20 rounded-lg p-4">
          <div className="flex items-center mb-2">
            <TrendingDown className="h-5 w-5 text-red-600 mr-2" />
            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">24h Low</span>
          </div>
          <div className="text-xl font-bold text-gray-900 dark:text-white">
            {formatCurrency(currentData.low24h)}
          </div>
        </div>
      </div>
    </div>
  );
};

export default MetricsPanel;