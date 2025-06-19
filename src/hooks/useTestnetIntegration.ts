import { useState, useEffect, useCallback } from 'react';
import { ethers, BrowserProvider } from 'ethers';
import { TESTNET_CONFIG, TGAUX_ABI, ORACLE_AGGREGATOR_ABI, CIRCUIT_BREAKER_ABI, ERROR_MESSAGES } from '../config/testnet';

interface TestnetState {
  isConnected: boolean;
  account: string | null;
  balance: string;
  tgauxBalance: string;
  networkId: number | null;
  isCorrectNetwork: boolean;
  provider: BrowserProvider | null;
  signer: ethers.JsonRpcSigner | null;
}

interface ContractInstances {
  tgaux: ethers.Contract | null;
  oracleAggregator: ethers.Contract | null;
  circuitBreaker: ethers.Contract | null;
}

export const useTestnetIntegration = () => {
  const [state, setState] = useState<TestnetState>({
    isConnected: false,
    account: null,
    balance: '0',
    tgauxBalance: '0',
    networkId: null,
    isCorrectNetwork: false,
    provider: null,
    signer: null
  });

  const [contracts, setContracts] = useState<ContractInstances>({
    tgaux: null,
    oracleAggregator: null,
    circuitBreaker: null
  });

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Initialize Web3 connection
  const connectWallet = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);

      if (!window.ethereum) {
        throw new Error('MetaMask is not installed');
      }

      // Request account access
      await window.ethereum.request({ method: 'eth_requestAccounts' });

      const provider = new BrowserProvider(window.ethereum);
      const signer = provider.getSigner();
      const account = await signer.getAddress();
      const network = await provider.getNetwork();
      const balance = await provider.getBalance(account);

      const isCorrectNetwork = network.chainId === TESTNET_CONFIG.NETWORK_ID;

      setState({
        isConnected: true,
        account,
        balance: ethers.utils.formatEther(balance),
        tgauxBalance: '0',
        networkId: network.chainId,
        isCorrectNetwork,
        provider,
        signer
      });

      // Initialize contracts if on correct network
      if (isCorrectNetwork) {
        const tgaux = new ethers.Contract(TESTNET_CONFIG.CONTRACTS.TGAUX, TGAUX_ABI, signer);
        const oracleAggregator = new ethers.Contract(TESTNET_CONFIG.CONTRACTS.ORACLE_AGGREGATOR, ORACLE_AGGREGATOR_ABI, provider);
        const circuitBreaker = new ethers.Contract(TESTNET_CONFIG.CONTRACTS.CIRCUIT_BREAKER, CIRCUIT_BREAKER_ABI, provider);

        setContracts({ tgaux, oracleAggregator, circuitBreaker });

        // Get TGAUx balance
        try {
          const tgauxBalance = await tgaux.balanceOf(account);
          setState(prev => ({
            ...prev,
            tgauxBalance: ethers.formatEther(tgauxBalance)
          }));
        } catch (err) {
          console.warn('Could not fetch TGAUx balance:', err);
        }
      }

    } catch (err: any) {
      setError(err.message || 'Failed to connect wallet');
    } finally {
      setLoading(false);
    }
  }, []);

  // Switch to testnet
  const switchToTestnet = useCallback(async () => {
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: `0x${TESTNET_CONFIG.NETWORK_ID.toString(16)}` }],
      });
    } catch (switchError: any) {
      // This error code indicates that the chain has not been added to MetaMask
      if (switchError.code === 4902) {
        try {
          await window.ethereum.request({
            method: 'wallet_addEthereumChain',
            params: [{
              chainId: `0x${TESTNET_CONFIG.NETWORK_ID.toString(16)}`,
              chainName: 'Sepolia Testnet',
              nativeCurrency: {
                name: 'Sepolia ETH',
                symbol: 'SEP',
                decimals: 18,
              },
              rpcUrls: [TESTNET_CONFIG.RPC_URL],
              blockExplorerUrls: ['https://sepolia.etherscan.io/'],
            }],
          });
        } catch (addError) {
          throw new Error('Failed to add Sepolia network to MetaMask');
        }
      } else {
        throw new Error('Failed to switch to Sepolia network');
      }
    }
  }, []);

  // Mint TGAUx tokens
  const mintTokens = useCallback(async (usdAmount: string, minTokensOut: string) => {
    if (!contracts.tgaux || !state.isCorrectNetwork) {
      throw new Error(ERROR_MESSAGES.WRONG_NETWORK);
    }

    try {
      setLoading(true);
      setError(null);

      const usdAmountWei = ethers.parseEther(usdAmount);
      const minTokensOutWei = ethers.parseEther(minTokensOut);

      const tx = await contracts.tgaux.mint(usdAmountWei, minTokensOutWei);
      const receipt = await tx.wait();

      // Update balance
      const newBalance = await contracts.tgaux.balanceOf(state.account);
      setState(prev => ({
        ...prev,
        tgauxBalance: ethers.formatEther(newBalance)
      }));

      return receipt;
    } catch (err: any) {
      const errorMessage = err.reason || err.message || 'Mint transaction failed';
      setError(errorMessage);
      throw new Error(errorMessage);
    } finally {
      setLoading(false);
    }
  }, [contracts.tgaux, state.isCorrectNetwork, state.account]);

  // Redeem TGAUx tokens
  const redeemTokens = useCallback(async (tokenAmount: string, minUsdOut: string) => {
    if (!contracts.tgaux || !state.isCorrectNetwork) {
      throw new Error(ERROR_MESSAGES.WRONG_NETWORK);
    }

    try {
      setLoading(true);
      setError(null);

      const tokenAmountWei = ethers.parseEther(tokenAmount);
      const minUsdOutWei = ethers.parseEther(minUsdOut);

      const tx = await contracts.tgaux.redeem(tokenAmountWei, minUsdOutWei);
      const receipt = await tx.wait();

      // Update balance
      const newBalance = await contracts.tgaux.balanceOf(state.account);
      setState(prev => ({
        ...prev,
        tgauxBalance: ethers.formatEther(newBalance)
      }));

      return receipt;
    } catch (err: any) {
      const errorMessage = err.reason || err.message || 'Redeem transaction failed';
      setError(errorMessage);
      throw new Error(errorMessage);
    } finally {
      setLoading(false);
    }
  }, [contracts.tgaux, state.isCorrectNetwork, state.account]);

  // Get current price from oracle
  const getCurrentPrice = useCallback(async () => {
    if (!contracts.oracleAggregator) return null;

    try {
      const [price, timestamp] = await contracts.oracleAggregator.getLatestPrice();
      return {
        price: ethers.formatEther(price),
        timestamp: timestamp.toNumber()
      };
    } catch (err) {
      console.warn('Could not fetch current price:', err);
      return null;
    }
  }, [contracts.oracleAggregator]);

  // Check circuit breaker status
  const getCircuitBreakerStatus = useCallback(async () => {
    if (!contracts.circuitBreaker) return null;

    try {
      const [isTriggered, timeUntilReset] = await Promise.all([
        contracts.circuitBreaker.isTriggered(),
        contracts.circuitBreaker.getTimeUntilReset()
      ]);

      return {
        isTriggered,
        timeUntilReset: timeUntilReset.toNumber()
      };
    } catch (err) {
      console.warn('Could not fetch circuit breaker status:', err);
      return null;
    }
  }, [contracts.circuitBreaker]);

  // Listen for account changes
  useEffect(() => {
    if (window.ethereum) {
      const handleAccountsChanged = (accounts: string[]) => {
        if (accounts.length === 0) {
          setState(prev => ({
            ...prev,
            isConnected: false,
            account: null,
            balance: '0',
            tgauxBalance: '0'
          }));
          setContracts({ tgaux: null, oracleAggregator: null, circuitBreaker: null });
        } else {
          connectWallet();
        }
      };

      const handleChainChanged = (chainId: string) => {
        const newChainId = parseInt(chainId, 16);
        setState(prev => ({
          ...prev,
          networkId: newChainId,
          isCorrectNetwork: newChainId === TESTNET_CONFIG.NETWORK_ID
        }));

        if (newChainId === TESTNET_CONFIG.NETWORK_ID) {
          connectWallet();
        } else {
          setContracts({ tgaux: null, oracleAggregator: null, circuitBreaker: null });
        }
      };

      window.ethereum.on('accountsChanged', handleAccountsChanged);
      window.ethereum.on('chainChanged', handleChainChanged);

      return () => {
        window.ethereum.removeListener('accountsChanged', handleAccountsChanged);
        window.ethereum.removeListener('chainChanged', handleChainChanged);
      };
    }
  }, [connectWallet]);

  // Auto-connect if previously connected
  useEffect(() => {
    const autoConnect = async () => {
      if (window.ethereum) {
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

  return {
    // State
    ...state,
    loading,
    error,
    
    // Actions
    connectWallet,
    switchToTestnet,
    mintTokens,
    redeemTokens,
    getCurrentPrice,
    getCircuitBreakerStatus,
    
    // Utilities
    clearError: () => setError(null),
    isTestnetMode: true,
    config: TESTNET_CONFIG
  };
};

// Type declarations for window.ethereum
declare global {
  interface Window {
    ethereum?: any;
  }
}

export default useTestnetIntegration;