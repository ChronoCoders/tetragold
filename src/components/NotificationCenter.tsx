import React, { useState, useEffect } from 'react';
import { Bell, X, TrendingUp, TrendingDown, AlertTriangle, CheckCircle, Settings } from 'lucide-react';
import { useGoldPrice } from '../hooks/useGoldPrice';
import { formatCurrency, formatPercentage } from '../utils/calculations';

interface Notification {
  id: string;
  type: 'price_alert' | 'trade_complete' | 'system' | 'warning';
  title: string;
  message: string;
  timestamp: number;
  read: boolean;
  data?: any;
}

interface PriceAlert {
  id: string;
  type: 'above' | 'below';
  price: number;
  enabled: boolean;
}

const NotificationCenter: React.FC = () => {
  const { currentData } = useGoldPrice();
  const [isOpen, setIsOpen] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const [notifications, setNotifications] = useState<Notification[]>([]);
  const [priceAlerts, setPriceAlerts] = useState<PriceAlert[]>([
    { id: '1', type: 'above', price: 3400, enabled: true },
    { id: '2', type: 'below', price: 3300, enabled: true }
  ]);
  const [newAlertPrice, setNewAlertPrice] = useState('');
  const [newAlertType, setNewAlertType] = useState<'above' | 'below'>('above');

  // Check for price alerts
  useEffect(() => {
    priceAlerts.forEach(alert => {
      if (!alert.enabled) return;

      const shouldTrigger = 
        (alert.type === 'above' && currentData.price >= alert.price) ||
        (alert.type === 'below' && currentData.price <= alert.price);

      if (shouldTrigger) {
        const existingAlert = notifications.find(n => 
          n.type === 'price_alert' && n.data?.alertId === alert.id
        );

        if (!existingAlert) {
          addNotification({
            type: 'price_alert',
            title: 'Price Alert Triggered',
            message: `TGAUx price is ${alert.type} ${formatCurrency(alert.price)}`,
            data: { alertId: alert.id, price: currentData.price }
          });

          // Disable the alert after triggering
          setPriceAlerts(prev => 
            prev.map(a => a.id === alert.id ? { ...a, enabled: false } : a)
          );
        }
      }
    });
  }, [currentData.price, priceAlerts, notifications]);

  // Add sample notifications on mount
  useEffect(() => {
    const sampleNotifications: Notification[] = [
      {
        id: '1',
        type: 'system',
        title: 'Welcome to TetraGold',
        message: 'Your account has been successfully set up. Start trading TGAUx tokens now!',
        timestamp: Date.now() - 3600000,
        read: false
      },
      {
        id: '2',
        type: 'trade_complete',
        title: 'Trade Completed',
        message: 'Successfully minted 50.00 TGAUx tokens',
        timestamp: Date.now() - 7200000,
        read: true
      }
    ];
    setNotifications(sampleNotifications);
  }, []);

  const addNotification = (notification: Omit<Notification, 'id' | 'timestamp' | 'read'>) => {
    const newNotification: Notification = {
      ...notification,
      id: Date.now().toString(),
      timestamp: Date.now(),
      read: false
    };
    setNotifications(prev => [newNotification, ...prev]);
  };

  const markAsRead = (id: string) => {
    setNotifications(prev => 
      prev.map(n => n.id === id ? { ...n, read: true } : n)
    );
  };

  const markAllAsRead = () => {
    setNotifications(prev => prev.map(n => ({ ...n, read: true })));
  };

  const deleteNotification = (id: string) => {
    setNotifications(prev => prev.filter(n => n.id !== id));
  };

  const addPriceAlert = () => {
    const price = parseFloat(newAlertPrice);
    if (isNaN(price) || price <= 0) return;

    const newAlert: PriceAlert = {
      id: Date.now().toString(),
      type: newAlertType,
      price,
      enabled: true
    };

    setPriceAlerts(prev => [...prev, newAlert]);
    setNewAlertPrice('');
  };

  const toggleAlert = (id: string) => {
    setPriceAlerts(prev => 
      prev.map(alert => 
        alert.id === id ? { ...alert, enabled: !alert.enabled } : alert
      )
    );
  };

  const deleteAlert = (id: string) => {
    setPriceAlerts(prev => prev.filter(alert => alert.id !== id));
  };

  const unreadCount = notifications.filter(n => !n.read).length;

  const getNotificationIcon = (type: Notification['type']) => {
    switch (type) {
      case 'price_alert':
        return <TrendingUp className="h-5 w-5 text-amber-600" />;
      case 'trade_complete':
        return <CheckCircle className="h-5 w-5 text-green-600" />;
      case 'warning':
        return <AlertTriangle className="h-5 w-5 text-red-600" />;
      default:
        return <Bell className="h-5 w-5 text-blue-600" />;
    }
  };

  return (
    <div className="relative">
      {/* Notification Bell */}
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="relative p-2 text-gray-500 hover:text-amber-600 transition-colors"
      >
        <Bell className="h-6 w-6" />
        {unreadCount > 0 && (
          <span className="absolute -top-1 -right-1 bg-red-500 text-white text-xs rounded-full h-5 w-5 flex items-center justify-center">
            {unreadCount > 9 ? '9+' : unreadCount}
          </span>
        )}
      </button>

      {/* Notification Panel */}
      {isOpen && (
        <div className="absolute right-0 top-full mt-2 w-96 bg-white dark:bg-gray-800 rounded-xl shadow-2xl border border-gray-200 dark:border-gray-700 z-50">
          {/* Header */}
          <div className="flex items-center justify-between p-4 border-b border-gray-200 dark:border-gray-700">
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white">
              Notifications
            </h3>
            <div className="flex items-center space-x-2">
              <button
                onClick={() => setShowSettings(!showSettings)}
                className="p-1 text-gray-500 hover:text-amber-600 transition-colors"
              >
                <Settings className="h-4 w-4" />
              </button>
              <button
                onClick={() => setIsOpen(false)}
                className="p-1 text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 transition-colors"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
          </div>

          {/* Settings Panel */}
          {showSettings && (
            <div className="p-4 border-b border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-700">
              <h4 className="font-medium text-gray-900 dark:text-white mb-3">Price Alerts</h4>
              
              {/* Add New Alert */}
              <div className="flex space-x-2 mb-3">
                <select
                  value={newAlertType}
                  onChange={(e) => setNewAlertType(e.target.value as 'above' | 'below')}
                  className="px-3 py-1 border border-gray-300 dark:border-gray-600 rounded text-sm bg-white dark:bg-gray-800"
                >
                  <option value="above">Above</option>
                  <option value="below">Below</option>
                </select>
                <input
                  type="number"
                  value={newAlertPrice}
                  onChange={(e) => setNewAlertPrice(e.target.value)}
                  placeholder="Price"
                  className="flex-1 px-3 py-1 border border-gray-300 dark:border-gray-600 rounded text-sm bg-white dark:bg-gray-800"
                />
                <button
                  onClick={addPriceAlert}
                  className="px-3 py-1 bg-amber-600 text-white rounded text-sm hover:bg-amber-700 transition-colors"
                >
                  Add
                </button>
              </div>

              {/* Existing Alerts */}
              <div className="space-y-2">
                {priceAlerts.map(alert => (
                  <div key={alert.id} className="flex items-center justify-between text-sm">
                    <div className="flex items-center space-x-2">
                      <input
                        type="checkbox"
                        checked={alert.enabled}
                        onChange={() => toggleAlert(alert.id)}
                        className="rounded"
                      />
                      <span className="text-gray-700 dark:text-gray-300">
                        {alert.type === 'above' ? '↗' : '↘'} {formatCurrency(alert.price)}
                      </span>
                    </div>
                    <button
                      onClick={() => deleteAlert(alert.id)}
                      className="text-red-500 hover:text-red-700 transition-colors"
                    >
                      <X className="h-3 w-3" />
                    </button>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Actions */}
          {notifications.length > 0 && (
            <div className="p-3 border-b border-gray-200 dark:border-gray-700">
              <button
                onClick={markAllAsRead}
                className="text-sm text-amber-600 hover:text-amber-700 transition-colors"
              >
                Mark all as read
              </button>
            </div>
          )}

          {/* Notifications List */}
          <div className="max-h-96 overflow-y-auto">
            {notifications.length === 0 ? (
              <div className="p-8 text-center text-gray-500 dark:text-gray-400">
                <Bell className="h-12 w-12 mx-auto mb-3 opacity-50" />
                <p>No notifications yet</p>
              </div>
            ) : (
              <div className="divide-y divide-gray-200 dark:divide-gray-700">
                {notifications.map(notification => (
                  <div
                    key={notification.id}
                    className={`p-4 hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors ${
                      !notification.read ? 'bg-amber-50 dark:bg-amber-900/10' : ''
                    }`}
                  >
                    <div className="flex items-start space-x-3">
                      <div className="flex-shrink-0 mt-1">
                        {getNotificationIcon(notification.type)}
                      </div>
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center justify-between">
                          <h4 className={`text-sm font-medium ${
                            !notification.read 
                              ? 'text-gray-900 dark:text-white' 
                              : 'text-gray-700 dark:text-gray-300'
                          }`}>
                            {notification.title}
                          </h4>
                          <button
                            onClick={() => deleteNotification(notification.id)}
                            className="text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 transition-colors"
                          >
                            <X className="h-3 w-3" />
                          </button>
                        </div>
                        <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                          {notification.message}
                        </p>
                        <p className="text-xs text-gray-500 dark:text-gray-500 mt-2">
                          {new Date(notification.timestamp).toLocaleString()}
                        </p>
                      </div>
                    </div>
                    {!notification.read && (
                      <button
                        onClick={() => markAsRead(notification.id)}
                        className="mt-2 text-xs text-amber-600 hover:text-amber-700 transition-colors"
                      >
                        Mark as read
                      </button>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
};

export default NotificationCenter;