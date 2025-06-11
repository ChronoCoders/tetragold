import React, { useState, useMemo } from 'react';
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend,
  Filler,
  type ChartOptions
} from 'chart.js';
import { Line } from 'react-chartjs-2';
import { Clock, TrendingUp, TrendingDown, BarChart3, Maximize2 } from 'lucide-react';
import { useGoldPrice } from '../hooks/useGoldPrice';
import { formatCurrency, formatPercentage } from '../utils/calculations';

ChartJS.register(
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend,
  Filler
);

type Timeframe = '1H' | '4H' | '1D' | '1W' | '1M';

const EnhancedChart: React.FC = () => {
  const { currentData, getHistoryForTimeframe, isLoading } = useGoldPrice();
  const [selectedTimeframe, setSelectedTimeframe] = useState<Timeframe>('1D');
  const [isFullscreen, setIsFullscreen] = useState(false);

  const timeframes: { key: Timeframe; label: string }[] = [
    { key: '1H', label: '1H' },
    { key: '4H', label: '4H' },
    { key: '1D', label: '1D' },
    { key: '1W', label: '1W' },
    { key: '1M', label: '1M' }
  ];

  const chartData = useMemo(() => {
    const history = getHistoryForTimeframe(selectedTimeframe);
    
    return {
      labels: history.map(point => {
        const date = new Date(point.timestamp);
        switch (selectedTimeframe) {
          case '1H':
          case '4H':
            return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
          case '1D':
            return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
          case '1W':
            return date.toLocaleDateString([], { month: 'short', day: 'numeric' });
          case '1M':
            return date.toLocaleDateString([], { month: 'short', day: 'numeric' });
          default:
            return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        }
      }),
      datasets: [
        {
          label: 'TGAUx Price',
          data: history.map(point => point.price),
          borderColor: '#d97706',
          backgroundColor: 'rgba(217, 119, 6, 0.1)',
          fill: true,
          tension: 0.4,
          borderWidth: 2,
          pointRadius: 0,
          pointHoverRadius: 6,
          pointBackgroundColor: '#d97706',
          pointBorderColor: '#ffffff',
          pointBorderWidth: 2
        }
      ]
    };
  }, [getHistoryForTimeframe, selectedTimeframe]);

  const chartOptions: ChartOptions<'line'> = {
    responsive: true,
    maintainAspectRatio: false,
    animation: {
      duration: 750,
      easing: 'easeInOutQuart'
    },
    plugins: {
      legend: {
        display: false
      },
      tooltip: {
        mode: 'index',
        intersect: false,
        backgroundColor: 'rgba(255, 255, 255, 0.95)',
        titleColor: '#1f2937',
        bodyColor: '#1f2937',
        borderColor: '#d1d5db',
        borderWidth: 1,
        padding: 12,
        cornerRadius: 8,
        displayColors: false,
        callbacks: {
          title: (tooltipItems) => {
            return `Time: ${tooltipItems[0].label}`;
          },
          label: (context) => {
            const value = context.parsed.y;
            return `Price: ${formatCurrency(value)}`;
          }
        }
      }
    },
    scales: {
      y: {
        type: 'linear',
        display: true,
        grid: {
          color: 'rgba(0, 0, 0, 0.05)',
          drawBorder: false
        },
        ticks: {
          callback: (value) => formatCurrency(value as number),
          font: {
            size: 11
          },
          color: '#6b7280'
        },
        border: {
          display: false
        }
      },
      x: {
        type: 'category',
        grid: {
          display: false
        },
        ticks: {
          maxRotation: 0,
          autoSkip: true,
          maxTicksLimit: 8,
          font: {
            size: 11
          },
          color: '#6b7280'
        },
        border: {
          display: false
        }
      }
    },
    interaction: {
      intersect: false,
      mode: 'index'
    },
    elements: {
      point: {
        hoverBorderWidth: 3
      }
    }
  };

  const priceChange = currentData.changePercent24h;
  const isPositive = priceChange >= 0;

  return (
    <div className={`bg-white dark:bg-gray-800 rounded-xl shadow-lg ${isFullscreen ? 'fixed inset-4 z-50' : ''}`}>
      <div className="p-6">
        {/* Header */}
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center space-x-4">
            <div className="flex items-center space-x-2">
              <BarChart3 className="h-6 w-6 text-amber-600" />
              <h2 className="text-xl font-bold text-gray-900 dark:text-white">TGAUx Price Chart</h2>
            </div>
            
            <div className="flex items-center space-x-2">
              <div className="text-2xl font-bold text-gray-900 dark:text-white">
                {formatCurrency(currentData.price)}
              </div>
              <div className={`flex items-center text-sm ${isPositive ? 'text-green-600' : 'text-red-600'}`}>
                {isPositive ? (
                  <TrendingUp className="h-4 w-4 mr-1" />
                ) : (
                  <TrendingDown className="h-4 w-4 mr-1" />
                )}
                <span>{formatPercentage(Math.abs(priceChange))}</span>
              </div>
            </div>
          </div>

          <button
            onClick={() => setIsFullscreen(!isFullscreen)}
            className="p-2 text-gray-500 hover:text-amber-600 transition-colors"
          >
            <Maximize2 className="h-5 w-5" />
          </button>
        </div>

        {/* Timeframe Selector */}
        <div className="flex items-center justify-between mb-6">
          <div className="flex space-x-1 bg-gray-100 dark:bg-gray-700 rounded-lg p-1">
            {timeframes.map((timeframe) => (
              <button
                key={timeframe.key}
                onClick={() => setSelectedTimeframe(timeframe.key)}
                className={`px-3 py-1 rounded-md text-sm font-medium transition-colors ${
                  selectedTimeframe === timeframe.key
                    ? 'bg-amber-600 text-white'
                    : 'text-gray-600 dark:text-gray-300 hover:text-amber-600'
                }`}
              >
                {timeframe.label}
              </button>
            ))}
          </div>

          <div className="flex items-center text-sm text-gray-500 dark:text-gray-400">
            <Clock className="h-4 w-4 mr-1" />
            <span>Real-time data</span>
          </div>
        </div>

        {/* Chart */}
        <div className={`${isFullscreen ? 'h-96' : 'h-80'} relative`}>
          {isLoading ? (
            <div className="absolute inset-0 flex items-center justify-center">
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-amber-600"></div>
            </div>
          ) : (
            <Line options={chartOptions} data={chartData} />
          )}
        </div>

        {/* Chart Stats */}
        <div className="mt-6 grid grid-cols-2 md:grid-cols-4 gap-4">
          <div className="text-center">
            <div className="text-sm text-gray-500 dark:text-gray-400">24h High</div>
            <div className="text-lg font-semibold text-green-600">
              {formatCurrency(currentData.high24h)}
            </div>
          </div>
          <div className="text-center">
            <div className="text-sm text-gray-500 dark:text-gray-400">24h Low</div>
            <div className="text-lg font-semibold text-red-600">
              {formatCurrency(currentData.low24h)}
            </div>
          </div>
          <div className="text-center">
            <div className="text-sm text-gray-500 dark:text-gray-400">24h Volume</div>
            <div className="text-lg font-semibold text-gray-900 dark:text-white">
              ${(currentData.volume24h / 1000000).toFixed(2)}M
            </div>
          </div>
          <div className="text-center">
            <div className="text-sm text-gray-500 dark:text-gray-400">Market Cap</div>
            <div className="text-lg font-semibold text-gray-900 dark:text-white">
              ${(currentData.marketCap / 1000000).toFixed(2)}M
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default EnhancedChart;