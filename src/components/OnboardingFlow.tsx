import React, { useState } from 'react';
import { X, ChevronRight, ChevronLeft, Play, Wallet, BarChart3, ArrowUpDown, Shield, CheckCircle } from 'lucide-react';

interface OnboardingFlowProps {
  isOpen: boolean;
  onClose: () => void;
}

const OnboardingFlow: React.FC<OnboardingFlowProps> = ({ isOpen, onClose }) => {
  const [currentStep, setCurrentStep] = useState(0);
  const [isSandboxMode, setIsSandboxMode] = useState(false);

  const steps = [
    {
      title: 'Welcome to TetraGold',
      icon: Shield,
      content: (
        <div className="text-center">
          <p className="text-gray-600 dark:text-gray-300 mb-6">
            TetraGold (TGAUx) is a synthetic token that tracks real-time gold prices through 
            decentralized oracles, providing instant liquidity without physical storage.
          </p>
          <div className="bg-amber-50 dark:bg-amber-900/20 rounded-lg p-4">
            <h4 className="font-semibold text-amber-800 dark:text-amber-200 mb-2">Key Benefits:</h4>
            <ul className="text-sm text-amber-700 dark:text-amber-300 space-y-1">
              <li>• 24/7 trading with instant settlement</li>
              <li>• Zero storage costs or custody risks</li>
              <li>• Transparent, on-chain price tracking</li>
              <li>• Capital efficient synthetic design</li>
            </ul>
          </div>
        </div>
      )
    },
    {
      title: 'Understanding the Dashboard',
      icon: BarChart3,
      content: (
        <div>
          <p className="text-gray-600 dark:text-gray-300 mb-4">
            Your dashboard provides real-time market data and trading tools:
          </p>
          <div className="space-y-3">
            <div className="flex items-start space-x-3">
              <div className="bg-amber-100 dark:bg-amber-900/30 p-2 rounded-lg">
                <BarChart3 className="h-5 w-5 text-amber-600" />
              </div>
              <div>
                <h4 className="font-medium text-gray-900 dark:text-white">Market Overview</h4>
                <p className="text-sm text-gray-600 dark:text-gray-300">
                  Current price, 24h changes, volume, and market cap
                </p>
              </div>
            </div>
            <div className="flex items-start space-x-3">
              <div className="bg-amber-100 dark:bg-amber-900/30 p-2 rounded-lg">
                <BarChart3 className="h-5 w-5 text-amber-600" />
              </div>
              <div>
                <h4 className="font-medium text-gray-900 dark:text-white">Interactive Chart</h4>
                <p className="text-sm text-gray-600 dark:text-gray-300">
                  Real-time price charts with multiple timeframes
                </p>
              </div>
            </div>
            <div className="flex items-start space-x-3">
              <div className="bg-amber-100 dark:bg-amber-900/30 p-2 rounded-lg">
                <ArrowUpDown className="h-5 w-5 text-amber-600" />
              </div>
              <div>
                <h4 className="font-medium text-gray-900 dark:text-white">Trading Panel</h4>
                <p className="text-sm text-gray-600 dark:text-gray-300">
                  Mint and redeem TGAUx tokens with slippage controls
                </p>
              </div>
            </div>
          </div>
        </div>
      )
    },
    {
      title: 'How Trading Works',
      icon: ArrowUpDown,
      content: (
        <div>
          <p className="text-gray-600 dark:text-gray-300 mb-4">
            TetraGold uses a simple mint/redeem mechanism:
          </p>
          <div className="space-y-4">
            <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4">
              <h4 className="font-semibold text-green-800 dark:text-green-200 mb-2">Minting TGAUx</h4>
              <p className="text-sm text-green-700 dark:text-green-300">
                Deposit USD to mint TGAUx tokens at the current gold price. 
                Each token represents $1 worth of gold exposure.
              </p>
            </div>
            <div className="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4">
              <h4 className="font-semibold text-blue-800 dark:text-blue-200 mb-2">Redeeming TGAUx</h4>
              <p className="text-sm text-blue-700 dark:text-blue-300">
                Burn TGAUx tokens to receive USD at the current gold price. 
                Instant settlement with minimal fees.
              </p>
            </div>
            <div className="bg-amber-50 dark:bg-amber-900/20 rounded-lg p-4">
              <h4 className="font-semibold text-amber-800 dark:text-amber-200 mb-2">Price Tracking</h4>
              <p className="text-sm text-amber-700 dark:text-amber-300">
                Oracle network ensures TGAUx price accurately reflects real-time gold market prices.
              </p>
            </div>
          </div>
        </div>
      )
    },
    {
      title: 'Connect Your Wallet',
      icon: Wallet,
      content: (
        <div className="text-center">
          <p className="text-gray-600 dark:text-gray-300 mb-6">
            To start trading, you'll need to connect a compatible wallet. 
            We support MetaMask, WalletConnect, and other popular wallets.
          </p>
          <div className="space-y-3 mb-6">
            <button className="w-full bg-orange-500 hover:bg-orange-600 text-white py-3 px-4 rounded-lg font-medium transition-colors flex items-center justify-center">
              <img src="https://upload.wikimedia.org/wikipedia/commons/3/36/MetaMask_Fox.svg" alt="MetaMask" className="h-6 w-6 mr-2" />
              Connect MetaMask
            </button>
            <button className="w-full bg-blue-500 hover:bg-blue-600 text-white py-3 px-4 rounded-lg font-medium transition-colors">
              WalletConnect
            </button>
          </div>
          <div className="bg-gray-50 dark:bg-gray-700 rounded-lg p-4">
            <p className="text-sm text-gray-600 dark:text-gray-300">
              Don't have a wallet? Download MetaMask or another Web3 wallet to get started.
            </p>
          </div>
        </div>
      )
    },
    {
      title: 'Try Sandbox Mode',
      icon: Play,
      content: (
        <div className="text-center">
          <p className="text-gray-600 dark:text-gray-300 mb-6">
            Want to explore without connecting a wallet? Try our sandbox mode 
            with simulated trading and real market data.
          </p>
          <div className="bg-gradient-to-r from-amber-50 to-yellow-50 dark:from-amber-900/20 dark:to-yellow-900/20 rounded-lg p-6 mb-6">
            <h4 className="font-semibold text-amber-800 dark:text-amber-200 mb-2">Sandbox Features:</h4>
            <ul className="text-sm text-amber-700 dark:text-amber-300 space-y-1">
              <li>• Virtual $10,000 USD balance</li>
              <li>• Real-time price data</li>
              <li>• Full trading interface</li>
              <li>• Risk-free exploration</li>
            </ul>
          </div>
          <button
            onClick={() => setIsSandboxMode(true)}
            className="w-full bg-amber-600 hover:bg-amber-700 text-white py-3 px-4 rounded-lg font-medium transition-colors flex items-center justify-center"
          >
            <Play className="h-5 w-5 mr-2" />
            Enter Sandbox Mode
          </button>
        </div>
      )
    }
  ];

  const nextStep = () => {
    if (currentStep < steps.length - 1) {
      setCurrentStep(currentStep + 1);
    }
  };

  const prevStep = () => {
    if (currentStep > 0) {
      setCurrentStep(currentStep - 1);
    }
  };

  const handleComplete = () => {
    if (isSandboxMode) {
      // Enable sandbox mode in the app
      localStorage.setItem('sandboxMode', 'true');
    }
    onClose();
  };

  if (!isOpen) return null;

  const currentStepData = steps[currentStep];
  const Icon = currentStepData.icon;

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-2xl max-w-2xl w-full max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-center justify-between p-6 border-b border-gray-200 dark:border-gray-700">
          <div className="flex items-center space-x-3">
            <div className="bg-amber-100 dark:bg-amber-900/30 p-2 rounded-lg">
              <Icon className="h-6 w-6 text-amber-600" />
            </div>
            <div>
              <h2 className="text-xl font-bold text-gray-900 dark:text-white">
                {currentStepData.title}
              </h2>
              <p className="text-sm text-gray-500">
                Step {currentStep + 1} of {steps.length}
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-2 text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 transition-colors"
          >
            <X className="h-6 w-6" />
          </button>
        </div>

        {/* Progress Bar */}
        <div className="px-6 pt-4">
          <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2">
            <div
              className="bg-amber-600 h-2 rounded-full transition-all duration-300"
              style={{ width: `${((currentStep + 1) / steps.length) * 100}%` }}
            />
          </div>
        </div>

        {/* Content */}
        <div className="p-6">
          {currentStepData.content}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between p-6 border-t border-gray-200 dark:border-gray-700">
          <button
            onClick={prevStep}
            disabled={currentStep === 0}
            className="flex items-center px-4 py-2 text-gray-600 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            <ChevronLeft className="h-5 w-5 mr-1" />
            Previous
          </button>

          <div className="flex space-x-2">
            {steps.map((_, index) => (
              <div
                key={index}
                className={`w-2 h-2 rounded-full transition-colors ${
                  index === currentStep
                    ? 'bg-amber-600'
                    : index < currentStep
                    ? 'bg-amber-300'
                    : 'bg-gray-300 dark:bg-gray-600'
                }`}
              />
            ))}
          </div>

          {currentStep === steps.length - 1 ? (
            <button
              onClick={handleComplete}
              className="flex items-center px-6 py-2 bg-amber-600 hover:bg-amber-700 text-white rounded-lg font-medium transition-colors"
            >
              <CheckCircle className="h-5 w-5 mr-2" />
              Get Started
            </button>
          ) : (
            <button
              onClick={nextStep}
              className="flex items-center px-4 py-2 text-amber-600 hover:text-amber-700 font-medium transition-colors"
            >
              Next
              <ChevronRight className="h-5 w-5 ml-1" />
            </button>
          )}
        </div>
      </div>
    </div>
  );
};

export default OnboardingFlow;