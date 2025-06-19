import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import { ThemeProvider } from './contexts/ThemeContext';
import { Web3Provider } from './contexts/Web3Context';
import ProtectedRoute from './components/ProtectedRoute';
import App from './App.tsx';
import Dashboard from './pages/Dashboard.tsx';
import KYC from './pages/KYC.tsx';
import './index.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider>
      <Web3Provider>
        <Router>
          <Routes>
            <Route path="/" element={<App />} />
            <Route 
              path="/kyc" 
              element={
                <ProtectedRoute requireWallet={true} requireKYC={false}>
                  <KYC />
                </ProtectedRoute>
              } 
            />
            <Route 
              path="/dashboard" 
              element={
                <ProtectedRoute requireWallet={true} requireKYC={true}>
                  <Dashboard />
                </ProtectedRoute>
              } 
            />
          </Routes>
        </Router>
      </Web3Provider>
    </ThemeProvider>
  </StrictMode>
);