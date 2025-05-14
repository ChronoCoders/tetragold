import React, { useEffect, useState } from 'react';
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
import { AlertCircle, TrendingUp, TrendingDown, Clock, DollarSign } from 'lucide-react';

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

const REFRESH_INTERVAL = 60000; // Update every minute
const BASE_PRICE = 3350; // Base gold price
const MAX_PRICE_CHANGE = 0.05; // Maximum 0.05% change per minute
const HISTORY_POINTS = 120; // 2 hours of data

const chartOptions: ChartOptions<'line'> = {
  responsive: true,
  maintainAspectRatio: false,
  animation: {
    duration: 750,
    easing: 'linear'
  },
  plugins: {
    legend: {
      display: false
    },
    tooltip: {
      mode: 'index',
      intersect: false,
      backgroundColor: 'rgba(255, 255, 255, 0.9)',
      titleColor: '#1f2937',
      bodyColor: '#1f2937',
      borderColor: '#d1d5db',
      borderWidth: 1,
      padding: 12,
      cornerRadius: 8,
      callbacks: {
        label: (context) => {
          const value = context.parsed.y;
          return `Price: $${value.toFixed(2)}`;
        },
        title: (tooltipItems) => {
          return `Time: ${tooltipItems[0].label}`;
        }
      }
    }
  },
  scales: {
    y: {
      type: 'linear',
      display: true,
      min: 3327,
      max: 3400,
      grid: {
        color: 'rgba(0, 0, 0, 0.1)'
      },
      ticks: {
        callback: (value) => `$${value}`,
        stepSize: 10,
        font: {
          size: 11
        }
      },
      title: {
        display: true,
        text: 'Price (USD)',
        font: {
          size: 12,
          weight: 'bold'
        }
      }
    },
    x: {
      type: 'category',
      grid: {
        display: false
      },
      ticks: {
        maxRotation: 45,
        autoSkip: true,
        maxTicksLimit: 12,
        font: {
          size: 11
        }
      },
      title: {
        display: true,
        text: 'Time',
        font: {
          size: 12,
          weight: 'bold'
        }
      }
    }
  },
  interaction: {
    intersect: false,
    mode: 'nearest'
  },
  elements: {
    line: {
      tension: 0.4,
      borderWidth: 2,
      fill: 'start'
    },
    point: {
      radius: 0,
      hitRadius: 10,
      hoverRadius: 4
    }
  }
};

const GoldPriceChart = () => {
  const [priceHistory, setPriceHistory] = useState<{ price: number; timestamp: number }[]>([]);
  const [currentPrice, setCurrentPrice] = useState(BASE_PRICE);
  const [highPrice, setHighPrice] = useState(BASE_PRICE);
  const [lowPrice, setLowPrice] = useState(BASE_PRICE);

  useEffect(() => {
    const generateNewPrice = (lastPrice: number) => {
      // Calculate maximum allowed change (0.05% of current price)
      const maxChange = lastPrice * (MAX_PRICE_CHANGE / 100);
      
      // Generate a smaller random change with slight upward bias (60% chance of increase)
      const bias = Math.random() < 0.6 ? 0.1 : -0.1;
      const change = (Math.random() - 0.5 + bias) * maxChange;
      
      // Calculate new price
      let newPrice = lastPrice + change;
      
      // Ensure price stays within bounds
      newPrice = Math.max(3327, Math.min(3400, newPrice));
      
      return Number(newPrice.toFixed(2));
    };

    const updatePrice = () => {
      const newPrice = generateNewPrice(currentPrice);
      setCurrentPrice(newPrice);
      setPriceHistory(prev => {
        const newHistory = [...prev, { price: newPrice, timestamp: Date.now() }];
        const slicedHistory = newHistory.slice(-HISTORY_POINTS);
        
        // Update high/low prices
        const prices = slicedHistory.map(point => point.price);
        setHighPrice(Math.max(...prices));
        setLowPrice(Math.min(...prices));
        
        return slicedHistory;
      });
    };

    // Initial price history
    if (priceHistory.length === 0) {
      const initialHistory = [];
      let lastPrice = BASE_PRICE;
      const now = Date.now();
      
      for (let i = HISTORY_POINTS - 1; i >= 0; i--) {
        lastPrice = generateNewPrice(lastPrice);
        initialHistory.push({
          price: lastPrice,
          timestamp: now - (i * REFRESH_INTERVAL)
        });
      }
      
      setPriceHistory(initialHistory);
      
      // Set initial high/low prices
      const prices = initialHistory.map(point => point.price);
      setHighPrice(Math.max(...prices));
      setLowPrice(Math.min(...prices));
    }

    const interval = setInterval(updatePrice, REFRESH_INTERVAL);
    return () => clearInterval(interval);
  }, [currentPrice]);

  const prevPrice = priceHistory[priceHistory.length - 2]?.price || currentPrice;
  const priceChange = currentPrice - prevPrice;
  const priceChangePercent = prevPrice ? (priceChange / prevPrice) * 100 : 0;

  const chartData = {
    labels: priceHistory.map(point => 
      new Date(point.timestamp).toLocaleTimeString([], {
        hour: '2-digit',
        minute: '2-digit'
      })
    ),
    datasets: [
      {
        label: 'Tetra Gold Price (USD)',
        data: priceHistory.map(point => point.price),
        borderColor: '#d97706',
        backgroundColor: 'rgba(217, 119, 6, 0.1)',
        fill: true
      }
    ]
  };

  return (
    <div className="bg-white p-6 rounded-lg shadow-xl">
      <div className="mb-6">
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-lg font-semibold text-gray-700">Tetra Gold Price</h3>
          <div className="flex items-center gap-2 text-sm text-gray-500">
            <Clock className="h-4 w-4" />
            <span>2H Chart</span>
          </div>
        </div>
        
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
          <div className="bg-amber-50 p-4 rounded-lg">
            <div className="text-sm text-gray-600 mb-1">Current Price</div>
            <div className="text-2xl font-bold text-amber-600">
              ${currentPrice.toFixed(2)}
            </div>
          </div>
          
          <div className="bg-green-50 p-4 rounded-lg">
            <div className="text-sm text-gray-600 mb-1">24h High</div>
            <div className="text-2xl font-bold text-green-600">
              ${highPrice.toFixed(2)}
            </div>
          </div>
          
          <div className="bg-red-50 p-4 rounded-lg">
            <div className="text-sm text-gray-600 mb-1">24h Low</div>
            <div className="text-2xl font-bold text-red-600">
              ${lowPrice.toFixed(2)}
            </div>
          </div>
          
          <div className={`p-4 rounded-lg ${priceChange >= 0 ? 'bg-green-50' : 'bg-red-50'}`}>
            <div className="text-sm text-gray-600 mb-1">Change</div>
            <div className={`text-2xl font-bold flex items-center ${priceChange >= 0 ? 'text-green-600' : 'text-red-600'}`}>
              {priceChange >= 0 ? (
                <TrendingUp className="h-5 w-5 mr-1" />
              ) : (
                <TrendingDown className="h-5 w-5 mr-1" />
              )}
              {Math.abs(priceChangePercent).toFixed(2)}%
            </div>
          </div>
        </div>
      </div>
      
      <div className="h-80">
        <Line options={chartOptions} data={chartData} />
      </div>
      
      <div className="mt-4 text-xs text-gray-500 flex items-center justify-end">
        <Clock className="h-4 w-4 mr-1" />
        Last updated: {new Date().toLocaleTimeString()}
      </div>
    </div>
  );
};

export default GoldPriceChart;