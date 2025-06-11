import React, { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { Hexagon, Circle, Coins, Sun, Moon, HelpCircle, LogOut, User } from 'lucide-react';
import { useTheme } from '../contexts/ThemeContext';
import { useAuth } from '../contexts/AuthContext';
import MetricsPanel from '../components/MetricsPanel';
import EnhancedChart from '../components/EnhancedChart';
import TradingPanel from '../components/TradingPanel';
import OnboardingFlow from '../components/OnboardingFlow';
import NotificationCenter from '../components/NotificationCenter';

function TetraLogo() {
  return (
    <div className="relative w-8 h-8 flex items-center justify-center">
      <Hexagon className="w-8 h-8 text-amber-600 absolute" strokeWidth={1.5} />
      <Circle className="w-5 h-5 text-amber-500 absolute" strokeWidth={2} />
      <Coins className="w-3 h-3 text-amber-700 absolute" strokeWidth={2} />
    </div>
  );
}

const Dashboard: React.FC = () => {
  const { theme, toggleTheme } = useTheme();
  const { user, signOut } = useAuth();
  const [showOnboarding, setShowOnboarding] = useState(false);
  const [isSandboxMode, setIsSandboxMode] = useState(false);

  useEffect(() => {
    // Check if user is new or wants onboarding
    const hasSeenOnboarding = localStorage.getItem('hasSeenOnboarding');
    const sandboxMode = localStorage.getItem('sandboxMode');
    
    if (!hasSeenOnboarding) {
      setShowOnboarding(true);
    }
    
    if (sandboxMode === 'true') {
      setIsSandboxMode(true);
    }
  }, []);

  const handleOnboardingClose = () => {
    setShowOnboarding(false);
    localStorage.setItem('hasSeenOnboarding', 'true');
  };

  const toggleSandboxMode = () => {
    const newMode = !isSandboxMode;
    setIsSandboxMode(newMode);
    localStorage.setItem('sandboxMode', newMode.toString());
  };

  const handleSignOut = async () => {
    try {
      await signOut();
    } catch (error) {
      console.error('Error signing out:', error);
    }
  };
  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 transition-colors">
      {/* Navigation */}
      <nav className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 transition-colors">
        <div className="container mx-auto px-4 py-4">
          <div className="flex justify-between items-center">
            <Link to="/" className="flex items-center space-x-3">
              <TetraLogo />
              <div>
                <span className="text-xl font-bold text-gray-900 dark:text-white">Tetra Gold</span>
                {isSandboxMode && (
                  <span className="ml-2 px-2 py-1 bg-amber-100 dark:bg-amber-900/30 text-amber-800 dark:text-amber-200 text-xs rounded-full">
                    Sandbox
                  </span>
                )}
              </div>
            </Link>
            
            <div className="flex items-center space-x-4">
              {/* Sandbox Toggle */}
              <button
                onClick={toggleSandboxMode}
                className={`px-3 py-1 rounded-lg text-sm font-medium transition-colors ${
                  isSandboxMode
                    ? 'bg-amber-600 text-white hover:bg-amber-700'
                    : 'bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-300 dark:hover:bg-gray-600'
                }`}
              >
                {isSandboxMode ? 'Exit Sandbox' : 'Sandbox Mode'}
              </button>

              {/* Notifications */}
              <NotificationCenter />

              {/* Theme Toggle */}
              <button
                onClick={toggleTheme}
                className="p-2 text-gray-500 hover:text-amber-600 transition-colors"
              >
                {theme === 'light' ? <Moon className="h-5 w-5" /> : <Sun className="h-5 w-5" />}
              </button>

              {/* Help */}
              <button
                onClick={() => setShowOnboarding(true)}
                className="p-2 text-gray-500 hover:text-amber-600 transition-colors"
              >
                <HelpCircle className="h-5 w-5" />
              </button>

              {/* User Menu */}
              <div className="flex items-center space-x-2">
                <div className="w-8 h-8 bg-amber-600 rounded-full flex items-center justify-center" title={user?.email || 'User'}>
                  <User className="h-4 w-4 text-white" />
                </div>
                <button 
                  onClick={handleSignOut}
                  className="p-2 text-gray-500 hover:text-red-600 transition-colors"
                  title="Sign out"
                >
                  <LogOut className="h-5 w-5" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </nav>

      {/* Main Content */}
      <main className="container mx-auto px-4 py-8">
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          {/* Left Column - Metrics and Chart */}
          <div className="lg:col-span-2 space-y-8">
            <MetricsPanel />
            <EnhancedChart />
          </div>

          {/* Right Column - Trading Panel */}
          <div className="lg:col-span-1">
            <TradingPanel />
          </div>
        </div>

        {/* Additional Information */}
        <div className="mt-12 grid grid-cols-1 md:grid-cols-3 gap-6">
          <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6">
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-3">
              Oracle Status
            </h3>
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">Chainlink</span>
                <span className="text-sm text-green-600">Active</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">Band Protocol</span>
                <span className="text-sm text-green-600">Active</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">Last Update</span>
                <span className="text-sm text-gray-900 dark:text-white">2 min ago</span>
              </div>
            </div>
          </div>

          <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6">
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-3">
              Network Stats
            </h3>
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">Gas Price</span>
                <span className="text-sm text-gray-900 dark:text-white">25 gwei</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">Block Time</span>
                <span className="text-sm text-gray-900 dark:text-white">12.5s</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">Network</span>
                <span className="text-sm text-green-600">Ethereum</span>
              </div>
            </div>
          </div>

          <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6">
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-3">
              Security
            </h3>
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">Smart Contract</span>
                <span className="text-sm text-green-600">Audited</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">Timelock</span>
                <span className="text-sm text-green-600">48h</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">Circuit Breaker</span>
                <span className="text-sm text-green-600">Active</span>
              </div>
            </div>
          </div>
        </div>
      </main>

      {/* Onboarding Flow */}
      <OnboardingFlow 
        isOpen={showOnboarding} 
        onClose={handleOnboardingClose} 
      />
    </div>
  );
};

export default Dashboard;