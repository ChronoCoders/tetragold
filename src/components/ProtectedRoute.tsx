import React from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { useWeb3 } from '../contexts/Web3Context';
import { Loader, Wallet, AlertTriangle } from 'lucide-react';

interface ProtectedRouteProps {
  children: React.ReactNode;
  requireWallet?: boolean;
  requireKYC?: boolean;
}

const ProtectedRoute: React.FC<ProtectedRouteProps> = ({ 
  children, 
  requireWallet = false,
  requireKYC = false
}) => {
  const { isConnected, kycStatus, loading } = useWeb3();
  const location = useLocation();

  // Show loading spinner while checking connection
  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50 dark:bg-gray-900">
        <div className="text-center">
          <Loader className="animate-spin h-8 w-8 text-amber-600 mx-auto mb-4" />
          <p className="text-gray-600 dark:text-gray-400">Connecting to wallet...</p>
        </div>
      </div>
    );
  }

  // If route requires wallet connection and wallet is not connected
  if (requireWallet && !isConnected) {
    return <Navigate to="/" state={{ from: location }} replace />;
  }

  // If route requires KYC and user hasn't completed KYC
  if (requireKYC && kycStatus !== 'approved') {
    if (kycStatus === 'none') {
      return <Navigate to="/kyc" state={{ from: location }} replace />;
    }
    
    if (kycStatus === 'pending') {
      return (
        <div className="min-h-screen flex items-center justify-center bg-gray-50 dark:bg-gray-900">
          <div className="text-center max-w-md mx-auto p-8">
            <div className="bg-yellow-100 dark:bg-yellow-900/20 p-4 rounded-full w-16 h-16 mx-auto mb-6 flex items-center justify-center">
              <Loader className="h-8 w-8 text-yellow-600 animate-spin" />
            </div>
            <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-4">
              KYC Under Review
            </h2>
            <p className="text-gray-600 dark:text-gray-400 mb-6">
              Your KYC application is being reviewed. This process typically takes 24-48 hours.
              You'll receive an email notification once the review is complete.
            </p>
            <button
              onClick={() => window.location.href = '/'}
              className="bg-amber-600 hover:bg-amber-700 text-white px-6 py-2 rounded-lg transition-colors"
            >
              Return to Home
            </button>
          </div>
        </div>
      );
    }
    
    if (kycStatus === 'rejected') {
      return (
        <div className="min-h-screen flex items-center justify-center bg-gray-50 dark:bg-gray-900">
          <div className="text-center max-w-md mx-auto p-8">
            <div className="bg-red-100 dark:bg-red-900/20 p-4 rounded-full w-16 h-16 mx-auto mb-6 flex items-center justify-center">
              <AlertTriangle className="h-8 w-8 text-red-600" />
            </div>
            <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-4">
              KYC Application Rejected
            </h2>
            <p className="text-gray-600 dark:text-gray-400 mb-6">
              Unfortunately, your KYC application was not approved. Please contact support
              for more information or to resubmit your application.
            </p>
            <div className="space-y-3">
              <button
                onClick={() => window.location.href = '/kyc'}
                className="w-full bg-amber-600 hover:bg-amber-700 text-white px-6 py-2 rounded-lg transition-colors"
              >
                Resubmit KYC
              </button>
              <button
                onClick={() => window.location.href = '/'}
                className="w-full bg-gray-200 hover:bg-gray-300 text-gray-800 px-6 py-2 rounded-lg transition-colors"
              >
                Return to Home
              </button>
            </div>
          </div>
        </div>
      );
    }
  }

  return <>{children}</>;
};

export default ProtectedRoute;