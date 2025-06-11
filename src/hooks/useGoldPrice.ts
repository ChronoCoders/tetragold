import { useState, useEffect, useCallback } from 'react';

export interface PriceData {
  price: number;
  timestamp: number;
  change24h: number;
  changePercent24h: number;
  high24h: number;
  low24h: number;
  volume24h: number;
  marketCap: number;
  totalSupply: number;
  backingRatio: number;
}

export interface PriceHistory {
  timestamp: number;
  price: number;
  volume: number;
}

const REFRESH_INTERVAL = 30000; // 30 seconds
const BASE_PRICE = 3350;
const BASE_SUPPLY = 1000000;
const BASE_MARKET_CAP = BASE_PRICE * BASE_SUPPLY;

// Simulate realistic price movements
const generatePriceMovement = (lastPrice: number): number => {
  const volatility = 0.002; // 0.2% max change per update
  const trend = Math.random() < 0.52 ? 1 : -1; // Slight upward bias
  const change = (Math.random() * volatility * trend) + (Math.random() * 0.001 - 0.0005);
  
  let newPrice = lastPrice * (1 + change);
  newPrice = Math.max(3300, Math.min(3400, newPrice)); // Keep within bounds
  
  return Number(newPrice.toFixed(2));
};

export const useGoldPrice = () => {
  const [currentData, setCurrentData] = useState<PriceData>({
    price: BASE_PRICE,
    timestamp: Date.now(),
    change24h: 0,
    changePercent24h: 0,
    high24h: BASE_PRICE,
    low24h: BASE_PRICE,
    volume24h: 2500000,
    marketCap: BASE_MARKET_CAP,
    totalSupply: BASE_SUPPLY,
    backingRatio: 98.5
  });

  const [priceHistory, setPriceHistory] = useState<PriceHistory[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Initialize price history
  useEffect(() => {
    const initializeHistory = () => {
      const history: PriceHistory[] = [];
      const now = Date.now();
      let price = BASE_PRICE;
      
      // Generate 24 hours of historical data (every 5 minutes = 288 points)
      for (let i = 288; i >= 0; i--) {
        price = generatePriceMovement(price);
        history.push({
          timestamp: now - (i * 5 * 60 * 1000),
          price,
          volume: Math.random() * 50000 + 10000
        });
      }
      
      setPriceHistory(history);
      
      // Calculate 24h stats
      const firstPrice = history[0].price;
      const lastPrice = history[history.length - 1].price;
      const change24h = lastPrice - firstPrice;
      const changePercent24h = (change24h / firstPrice) * 100;
      const prices = history.map(h => h.price);
      const high24h = Math.max(...prices);
      const low24h = Math.min(...prices);
      const volume24h = history.reduce((sum, h) => sum + h.volume, 0);
      
      setCurrentData(prev => ({
        ...prev,
        price: lastPrice,
        change24h,
        changePercent24h,
        high24h,
        low24h,
        volume24h,
        timestamp: now
      }));
      
      setIsLoading(false);
    };

    initializeHistory();
  }, []);

  // Update price periodically
  useEffect(() => {
    if (priceHistory.length === 0) return;

    const interval = setInterval(() => {
      const newPrice = generatePriceMovement(currentData.price);
      const now = Date.now();
      
      // Add new price to history
      const newHistoryPoint: PriceHistory = {
        timestamp: now,
        price: newPrice,
        volume: Math.random() * 50000 + 10000
      };
      
      setPriceHistory(prev => {
        const updated = [...prev.slice(-287), newHistoryPoint]; // Keep last 24h
        
        // Recalculate 24h stats
        const firstPrice = updated[0].price;
        const change24h = newPrice - firstPrice;
        const changePercent24h = (change24h / firstPrice) * 100;
        const prices = updated.map(h => h.price);
        const high24h = Math.max(...prices);
        const low24h = Math.min(...prices);
        const volume24h = updated.reduce((sum, h) => sum + h.volume, 0);
        
        setCurrentData(prevData => ({
          ...prevData,
          price: newPrice,
          change24h,
          changePercent24h,
          high24h,
          low24h,
          volume24h,
          marketCap: newPrice * prevData.totalSupply,
          timestamp: now
        }));
        
        return updated;
      });
    }, REFRESH_INTERVAL);

    return () => clearInterval(interval);
  }, [currentData.price, priceHistory.length]);

  const getHistoryForTimeframe = useCallback((timeframe: '1H' | '4H' | '1D' | '1W' | '1M') => {
    const now = Date.now();
    let cutoffTime: number;
    
    switch (timeframe) {
      case '1H':
        cutoffTime = now - (60 * 60 * 1000);
        break;
      case '4H':
        cutoffTime = now - (4 * 60 * 60 * 1000);
        break;
      case '1D':
        cutoffTime = now - (24 * 60 * 60 * 1000);
        break;
      case '1W':
        cutoffTime = now - (7 * 24 * 60 * 60 * 1000);
        break;
      case '1M':
        cutoffTime = now - (30 * 24 * 60 * 60 * 1000);
        break;
      default:
        cutoffTime = now - (24 * 60 * 60 * 1000);
    }
    
    return priceHistory.filter(point => point.timestamp >= cutoffTime);
  }, [priceHistory]);

  return {
    currentData,
    priceHistory,
    getHistoryForTimeframe,
    isLoading,
    error,
    refresh: () => {
      setIsLoading(true);
      // Trigger a refresh
      setTimeout(() => setIsLoading(false), 1000);
    }
  };
};