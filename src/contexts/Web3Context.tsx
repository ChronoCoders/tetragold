import React, { createContext, useContext, useEffect, useState, useCallback } from 'react';
import { ethers, BrowserProvider } from 'ethers';

interface Web3ContextType {
  account: string | null;
  provider: BrowserProvider | null;
  signer: ethers.JsonRpcSigner | null;
  isConnected: boolean;
  isCorrectNetwork: boolean;
  networkId: number | null;
  balance: string;
  loading: boolean;
  error: string | null;
  kycStatus: 'none' | 'pending' | 'approved' | 'rejected';
  connectWallet: () => Promise<void>;
  disconnectWallet: () => void;
  switchNetwork: () => Promise<void>;
  clearError: () => void;
}

const Web3Context = createContext<Web3ContextType | undefined>(undefined);

export const useWeb3 = () => {
  const context = useContext(Web3Context);
  if (context === undefined) {
    throw new Error('useWeb3 must be used within a Web3Provider');
  }
  return context;
};

const REQUIRED_NETWORK_ID = 11155111; // Sepolia testnet
const REQUIRED_NETWORK_NAME = 'Sepolia';

export const Web3Provider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [account, setAccount] = useState<string | null>(null);
  const [provider, setProvider] = useState<BrowserProvider | null>(null);
  const [signer, setSigner] = useState<ethers.JsonRpcSigner | null>(null);
  const [isConnected, setIsConnected] = useState(false);
  const [isCorrectNetwork, setIsCorrectNetwork] = useState(false);
  const [networkId, setNetworkId] = useState<number | null>(null);
  const [balance, setBalance] = useState('0');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [kycStatus, setKycStatus] = useState<'none' | 'pending' | 'approved' | 'rejected'>('none');

  const clearError = useCallback(() => setError(null), []);

  const checkKYCStatus = useCallback(async (address: string) => {
    try {
      // Check localStorage for KYC status (in production, this would be an API call)
      const storedKYC = localStorage.getItem(`kyc_${address.toLowerCase()}`);
      if (storedKYC) {
        setKycStatus(storedKYC as any);
      } else {
        setKycStatus('none');
      }
    } catch (err) {
      console.warn('Failed to check KYC status:', err);
      setKycStatus('none');
    }
  }, []);

  const updateBalance = useCallback(async (provider: BrowserProvider, address: string) => {
    try {
      const balance = await provider.getBalance(address);
      setBalance(ethers.formatEther(balance));
    } catch (err) {
      console.warn('Failed to fetch balance:', err);
    }
  }, []);

  const connectWallet = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);

      if (!window.ethereum) {
        throw new Error('MetaMask is not installed. Please install MetaMask to continue.');
      }

      // Request account access
      const accounts = await window.ethereum.request({ 
        method: 'eth_requestAccounts' 
      });

      if (accounts.length === 0) {
        throw new Error('No accounts found. Please unlock MetaMask.');
      }

      const provider = new BrowserProvider(window.ethereum);
      const signer = provider.getSigner();
      const account = accounts[0];
      const network = await provider.getNetwork();

      setProvider(provider);
      setSigner(signer);
      setAccount(account);
      setNetworkId(network.chainId);
      setIsCorrectNetwork(network.chainId === REQUIRED_NETWORK_ID);
      setIsConnected(true);

      // Update balance
      await updateBalance(provider, account);

      // Check KYC status
      await checkKYCStatus(account);

      // Store connection preference
      localStorage.setItem('walletConnected', 'true');

    } catch (err: any) {
      setError(err.message || 'Failed to connect wallet');
      console.error('Wallet connection error:', err);
    } finally {
      setLoading(false);
    }
  }, [updateBalance, checkKYCStatus]);

  const disconnectWallet = useCallback(() => {
    setAccount(null);
    setProvider(null);
    setSigner(null);
    setIsConnected(false);
    setIsCorrectNetwork(false);
    setNetworkId(null);
    setBalance('0');
    setKycStatus('none');
    localStorage.removeItem('walletConnected');
  }, []);

  const switchNetwork = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);

      if (!window.ethereum) {
        throw new Error('MetaMask is not installed');
      }

      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: `0x${REQUIRED_NETWORK_ID.toString(16)}` }],
      });
    } catch (switchError: any) {
      // This error code indicates that the chain has not been added to MetaMask
      if (switchError.code === 4902) {
        try {
          await window.ethereum.request({
            method: 'wallet_addEthereumChain',
            params: [{
              chainId: `0x${REQUIRED_NETWORK_ID.toString(16)}`,
              chainName: `${REQUIRED_NETWORK_NAME} Testnet`,
              nativeCurrency: {
                name: 'Sepolia ETH',
                symbol: 'SEP',
                decimals: 18,
              },
              rpcUrls: ['https://sepolia.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161'],
              blockExplorerUrls: ['https://sepolia.etherscan.io/'],
            }],
          });
        } catch (addError) {
          throw new Error(`Failed to add ${REQUIRED_NETWORK_NAME} network to MetaMask`);
        }
      } else {
        throw new Error(`Failed to switch to ${REQUIRED_NETWORK_NAME} network`);
      }
    } finally {
      setLoading(false);
    }
  }, []);

  // Listen for account changes
  useEffect(() => {
    if (window.ethereum) {
      const handleAccountsChanged = (accounts: string[]) => {
        if (accounts.length === 0) {
          disconnectWallet();
        } else if (accounts[0] !== account) {
          // Account changed, reconnect
          connectWallet();
        }
      };

      const handleChainChanged = (chainId: string) => {
        const newChainId = parseInt(chainId, 16);
        setNetworkId(newChainId);
        setIsCorrectNetwork(newChainId === REQUIRED_NETWORK_ID);
        
        if (newChainId === REQUIRED_NETWORK_ID && account) {
          // Refresh data when switching to correct network
          updateBalance(provider!, account);
        }
      };

      window.ethereum.on('accountsChanged', handleAccountsChanged);
      window.ethereum.on('chainChanged', handleChainChanged);

      return () => {
        window.ethereum.removeListener('accountsChanged', handleAccountsChanged);
        window.ethereum.removeListener('chainChanged', handleChainChanged);
      };
    }
  }, [account, provider, connectWallet, disconnectWallet, updateBalance]);

  // Auto-connect if previously connected
  useEffect(() => {
    const autoConnect = async () => {
      const wasConnected = localStorage.getItem('walletConnected');
      if (wasConnected && window.ethereum) {
        try {
          const accounts = await window.ethereum.request({ method: 'eth_accounts' });
          if (accounts.length > 0) {
            await connectWallet();
          }
        } catch (err) {
          console.warn('Auto-connect failed:', err);
        }
      }
    };

    autoConnect();
  }, [connectWallet]);

  const value = {
    account,
    provider,
    signer,
    isConnected,
    isCorrectNetwork,
    networkId,
    balance,
    loading,
    error,
    kycStatus,
    connectWallet,
    disconnectWallet,
    switchNetwork,
    clearError
  };

  return (
    <Web3Context.Provider value={value}>
      {children}
    </Web3Context.Provider>
  );
};

// Type declarations for window.ethereum
declare global {
  interface Window {
    ethereum?: any;
  }
}