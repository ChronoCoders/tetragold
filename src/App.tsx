import React from 'react';
import { Hexagon, Circle, ArrowRight, ChevronDown, Shield, BarChart3, Coins, Globe, Github, Twitter, Lock, Zap, Network, Bell, Newspaper, ExternalLink, Building2, Wallet, Database, Boxes } from 'lucide-react';
import { Link } from 'react-router-dom';
import GoldPriceChart from './components/GoldPriceChart';

function TetraLogo() {
  return (
    <div className="relative w-10 h-10 flex items-center justify-center">
      <Hexagon className="w-10 h-10 text-amber-600 absolute" strokeWidth={1.5} />
      <Circle className="w-7 h-7 text-amber-500 absolute" strokeWidth={2} />
      <Coins className="w-5 h-5 text-amber-700 absolute" strokeWidth={2} />
    </div>
  );
}

function App() {
  return (
    <div className="min-h-screen bg-gradient-to-b from-amber-50 to-white">
      {/* Navigation */}
      <nav className="container mx-auto px-4 py-6">
        <div className="flex justify-between items-center">
          <Link to="/" className="flex items-center space-x-3">
            <TetraLogo />
            <span className="text-2xl font-bold text-gray-900">Tetra Gold</span>
          </Link>
          <div className="hidden md:flex items-center space-x-8">
            <a href="#about" className="text-gray-700 hover:text-amber-600 transition-colors">About</a>
            <a href="#tokenomics" className="text-gray-700 hover:text-amber-600 transition-colors">Tokenomics</a>
            <a href="#whitepaper" className="text-gray-700 hover:text-amber-600 transition-colors">Whitepaper</a>
            <Link to="/login" className="text-gray-700 hover:text-amber-600 transition-colors">Login</Link>
            <Link 
              to="/signup" 
              className="bg-amber-600 text-white px-6 py-2 rounded-lg hover:bg-amber-700 transition-colors"
            >
              Sign Up
            </Link>
          </div>
        </div>
      </nav>

      {/* Hero Section */}
      <section className="container mx-auto px-4 py-20 flex flex-col md:flex-row items-center">
        <div className="md:w-1/2 mb-10 md:mb-0">
          <h1 className="text-4xl md:text-6xl font-bold text-gray-900 leading-tight mb-6">
            The Future of <span className="text-amber-600">Gold-Indexed</span> Digital Assets
          </h1>
          <p className="text-xl text-gray-700 mb-8">
            Tetra Gold (TGAUx) is a revolutionary token that tracks real-time gold prices through decentralized oracles, bringing the stability of gold markets to DeFi.
          </p>
          <div className="flex flex-col sm:flex-row space-y-4 sm:space-y-0 sm:space-x-4">
            <button className="bg-amber-600 hover:bg-amber-700 text-white px-8 py-3 rounded-lg font-medium transition-colors flex items-center justify-center">
              Learn More <ChevronDown className="ml-2 h-5 w-5" />
            </button>
          </div>
        </div>
        <div className="md:w-1/2">
          <GoldPriceChart />
        </div>
      </section>

      {/* Features Section */}
      <section id="about" className="bg-white py-20">
        <div className="container mx-auto px-4">
          <div className="text-center mb-16">
            <h2 className="text-3xl md:text-4xl font-bold text-gray-900 mb-4">Why Choose Tetra Gold?</h2>
            <p className="text-xl text-gray-700 max-w-3xl mx-auto">
              Our gold-indexed token model provides accurate price tracking, security, and transparency in the volatile world of digital assets.
            </p>
          </div>
          
          <div className="grid grid-cols-1 md:grid-cols-3 gap-10">
            <div className="bg-amber-50 p-8 rounded-xl">
              <Zap className="h-12 w-12 text-amber-600 mb-6" />
              <h3 className="text-xl font-bold text-gray-900 mb-3">Instant Settlement</h3>
              <p className="text-gray-700">
                Trade gold exposure 24/7 with immediate settlement. No waiting for vault operations or custody transfers.
              </p>
            </div>
            
            <div className="bg-amber-50 p-8 rounded-xl">
              <Coins className="h-12 w-12 text-amber-600 mb-6" />
              <h3 className="text-xl font-bold text-gray-900 mb-3">Zero Storage Costs</h3>
              <p className="text-gray-700">
                Eliminate vault fees, insurance costs, and storage concerns. Pure price exposure without physical custody overhead.
              </p>
            </div>
            
            <div className="bg-amber-50 p-8 rounded-xl">
              <BarChart3 className="h-12 w-12 text-amber-600 mb-6" />
              <h3 className="text-xl font-bold text-gray-900 mb-3">Algorithmic Price Tracking</h3>
              <p className="text-gray-700">
                Multi-source oracle aggregation ensures accurate real-time gold price tracking without centralized custody risks.
              </p>
            </div>

            <div className="bg-amber-50 p-8 rounded-xl">
              <Shield className="h-12 w-12 text-amber-600 mb-6" />
              <h3 className="text-xl font-bold text-gray-900 mb-3">Capital Efficiency</h3>
              <p className="text-gray-700">
                Synthetic design eliminates 1:1 physical backing requirements, enabling efficient scaling and reduced counterparty risk.
              </p>
            </div>

            <div className="bg-amber-50 p-8 rounded-xl">
              <Network className="h-12 w-12 text-amber-600 mb-6" />
              <h3 className="text-xl font-bold text-gray-900 mb-3">Complete Transparency</h3>
              <p className="text-gray-700">
                All price feeds, transactions, and smart contract operations are fully auditable on-chain.
              </p>
            </div>

            <div className="bg-amber-50 p-8 rounded-xl">
              <Lock className="h-12 w-12 text-amber-600 mb-6" />
              <h3 className="text-xl font-bold text-gray-900 mb-3">Decentralized Security</h3>
              <p className="text-gray-700">
                Multi-layer security with circuit breakers, timelock governance, and continuous monitoring eliminates single points of failure.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Tokenomics Section */}
      <section id="tokenomics" className="py-20">
        <div className="container mx-auto px-4">
          <div className="text-center mb-16">
            <h2 className="text-3xl md:text-4xl font-bold text-gray-900 mb-4">Tokenomics</h2>
            <p className="text-xl text-gray-700 max-w-3xl mx-auto">
              Understanding the economic model behind Tetra Gold
            </p>
          </div>
          
          <div className="grid grid-cols-1 md:grid-cols-2 gap-10">
            <div className="bg-white p-8 rounded-xl shadow-lg">
              <h3 className="text-2xl font-bold text-gray-900 mb-6">Token Supply & Distribution</h3>
              <ul className="space-y-4">
                <li className="flex items-start">
                  <div className="bg-amber-100 p-2 rounded-full mr-4 mt-1">
                    <div className="bg-amber-600 h-3 w-3 rounded-full"></div>
                  </div>
                  <div>
                    <h4 className="font-bold text-gray-900">Dynamic Supply</h4>
                    <p className="text-gray-700">Token supply adjusts based on market demand and trading activity</p>
                  </div>
                </li>
                <li className="flex items-start">
                  <div className="bg-amber-100 p-2 rounded-full mr-4 mt-1">
                    <div className="bg-amber-600 h-3 w-3 rounded-full"></div>
                  </div>
                  <div>
                    <h4 className="font-bold text-gray-900">Price Tracking</h4>
                    <p className="text-gray-700">Token value tracks real-time gold market prices via oracle network</p>
                  </div>
                </li>
                <li className="flex items-start">
                  <div className="bg-amber-100 p-2 rounded-full mr-4 mt-1">
                    <div className="bg-amber-600 h-3 w-3 rounded-full"></div>
                  </div>
                  <div>
                    <h4 className="font-bold text-gray-900">Transaction Fees</h4>
                    <p className="text-gray-700">Minimal fees to ensure sustainability and liquidity</p>
                  </div>
                </li>
              </ul>
            </div>
            
            <div className="bg-white p-8 rounded-xl shadow-lg">
              <h3 className="text-2xl font-bold text-gray-900 mb-6">Oracle & Price Mechanism</h3>
              <ul className="space-y-4">
                <li className="flex items-start">
                  <div className="bg-amber-100 p-2 rounded-full mr-4 mt-1">
                    <div className="bg-amber-600 h-3 w-3 rounded-full"></div>
                  </div>
                  <div>
                    <h4 className="font-bold text-gray-900">Decentralized Oracles</h4>
                    <p className="text-gray-700">Multiple trusted data sources ensure accurate gold price tracking</p>
                  </div>
                </li>
                <li className="flex items-start">
                  <div className="bg-amber-100 p-2 rounded-full mr-4 mt-1">
                    <div className="bg-amber-600 h-3 w-3 rounded-full"></div>
                  </div>
                  <div>
                    <h4 className="font-bold text-gray-900">Price Updates</h4>
                    <p className="text-gray-700">Continuous real-time price updates reflect current gold market conditions</p>
                  </div>
                </li>
                <li className="flex items-start">
                  <div className="bg-amber-100 p-2 rounded-full mr-4 mt-1">
                    <div className="bg-amber-600 h-3 w-3 rounded-full"></div>
                  </div>
                  <div>
                    <h4 className="font-bold text-gray-900">Failsafe Mechanisms</h4>
                    <p className="text-gray-700">Multiple backup systems ensure continuous price feed reliability</p>
                  </div>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </section>

      {/* Partners & Integrations Section */}
      <section className="py-20 bg-white">
        <div className="container mx-auto px-4">
          <div className="text-center mb-16">
            <h2 className="text-3xl md:text-4xl font-bold text-gray-900 mb-4">Partners & Integrations</h2>
            <p className="text-xl text-gray-700 max-w-3xl mx-auto">
              Connecting with leading platforms and protocols
            </p>
          </div>
          
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-8">
            {/* Partner Card 1 */}
            <div className="bg-gray-50 p-6 rounded-xl hover:shadow-lg transition-shadow">
              <div className="h-20 flex items-center justify-center mb-4">
                <Building2 className="h-16 w-16 text-amber-600" />
              </div>
              <h3 className="text-lg font-bold text-gray-900 mb-2">Major Exchanges</h3>
              <p className="text-gray-600 text-sm">Listed on leading cryptocurrency exchanges for maximum liquidity</p>
            </div>

            {/* Partner Card 2 */}
            <div className="bg-gray-50 p-6 rounded-xl hover:shadow-lg transition-shadow">
              <div className="h-20 flex items-center justify-center mb-4">
                <Boxes className="h-16 w-16 text-amber-600" />
              </div>
              <h3 className="text-lg font-bold text-gray-900 mb-2">Financial Protocols</h3>
              <p className="text-gray-600 text-sm">Integrated with top financial platforms for yield generation</p>
            </div>

            {/* Partner Card 3 */}
            <div className="bg-gray-50 p-6 rounded-xl hover:shadow-lg transition-shadow">
              <div className="h-20 flex items-center justify-center mb-4">
                <Database className="h-16 w-16 text-amber-600" />
              </div>
              <h3 className="text-lg font-bold text-gray-900 mb-2">Oracle Networks</h3>
              <p className="text-gray-600 text-sm">Powered by industry-leading decentralized oracle solutions</p>
            </div>

            {/* Partner Card 4 */}
            <div className="bg-gray-50 p-6 rounded-xl hover:shadow-lg transition-shadow">
              <div className="h-20 flex items-center justify-center mb-4">
                <Wallet className="h-16 w-16 text-amber-600" />
              </div>
              <h3 className="text-lg font-bold text-gray-900 mb-2">Custody Solutions</h3>
              <p className="text-gray-600 text-sm">Compatible with major custody and banking solutions</p>
            </div>
          </div>
        </div>
      </section>

      {/* Latest Updates Section */}
      <section className="py-20">
        <div className="container mx-auto px-4">
          <div className="text-center mb-16">
            <h2 className="text-3xl md:text-4xl font-bold text-gray-900 mb-4">Latest Updates</h2>
            <p className="text-xl text-gray-700 max-w-3xl mx-auto">
              Stay informed about Tetra Gold's development and ecosystem growth
            </p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
            {/* Update Card 1 */}
            <div className="bg-white rounded-xl shadow-md overflow-hidden hover:shadow-lg transition-shadow">
              <div className="bg-amber-50 p-8">
                <Bell className="h-24 w-24 text-amber-600 mx-auto" />
              </div>
              <div className="p-6">
                <div className="flex items-center text-amber-600 text-sm mb-2">
                  <Bell className="h-4 w-4 mr-2" />
                  <span>Announcement</span>
                </div>
                <h3 className="text-xl font-bold text-gray-900 mb-2">Enhanced Oracle Network</h3>
                <p className="text-gray-600 mb-4">Upgraded price feed infrastructure with multiple data sources for improved accuracy.</p>
                <a href="#" className="text-amber-600 hover:text-amber-700 font-medium flex items-center">
                  Read More <ExternalLink className="h-4 w-4 ml-1" />
                </a>
              </div>
            </div>

            {/* Update Card 2 */}
            <div className="bg-white rounded-xl shadow-md overflow-hidden hover:shadow-lg transition-shadow">
              <div className="bg-amber-50 p-8">
                <Newspaper className="h-24 w-24 text-amber-600 mx-auto" />
              </div>
              <div className="p-6">
                <div className="flex items-center text-amber-600 text-sm mb-2">
                  <Newspaper className="h-4 w-4 mr-2" />
                  <span>Partnership</span>
                </div>
                <h3 className="text-xl font-bold text-gray-900 mb-2">New Exchange Listing</h3>
                <p className="text-gray-600 mb-4">Tetra Gold is now available on another major cryptocurrency exchange.</p>
                <a href="#" className="text-amber-600 hover:text-amber-700 font-medium flex items-center">
                  Read More <ExternalLink className="h-4 w-4 ml-1" />
                </a>
              </div>
            </div>

            {/* Update Card 3 */}
            <div className="bg-white rounded-xl shadow-md overflow-hidden hover:shadow-lg transition-shadow">
              <div className="bg-amber-50 p-8">
                <Zap className="h-24 w-24 text-amber-600 mx-auto" />
              </div>
              <div className="p-6">
                <div className="flex items-center text-amber-600 text-sm mb-2">
                  <Zap className="h-4 w-4 mr-2" />
                  <span>Development</span>
                </div>
                <h3 className="text-xl font-bold text-gray-900 mb-2">Mobile App Beta</h3>
                <p className="text-gray-600 mb-4">Our mobile wallet application enters public beta testing phase.</p>
                <a href="#" className="text-amber-600 hover:text-amber-700 font-medium flex items-center">
                  Read More <ExternalLink className="h-4 w-4 ml-1" />
                </a>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* CTA Section */}
      <section id="whitepaper" className="py-20 bg-gradient-to-r from-amber-600 to-amber-700 text-white">
        <div className="container mx-auto px-4 text-center">
          <h2 className="text-3xl md:text-4xl font-bold mb-6">Ready to Join the Future of Gold Markets?</h2>
          <p className="text-xl mb-10 max-w-3xl mx-auto">
            Download our comprehensive whitepaper to learn more about Tetra Gold's oracle network, tokenomics, and vision.
          </p>
          <button className="bg-white text-amber-700 hover:bg-amber-100 px-8 py-3 rounded-lg font-medium transition-colors inline-flex items-center">
            Download Whitepaper <ArrowRight className="ml-2 h-5 w-5" />
          </button>
        </div>
      </section>

      {/* Footer */}
      <footer className="bg-gray-900 text-white py-12">
        <div className="container mx-auto px-4">
          <div className="grid grid-cols-1 md:grid-cols-4 gap-8">
            <div>
              <div className="flex items-center space-x-2 mb-6">
                <TetraLogo />
                <span className="text-2xl font-bold">Tetra Gold</span>
              </div>
              <p className="text-gray-400 mb-6">
                The future of gold-indexed digital assets, combining real-time gold price tracking with the flexibility of modern financial technology.
              </p>
              <div className="flex space-x-4">
                <a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">
                  <Twitter className="h-6 w-6" />
                </a>
                <a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">
                  <Github className="h-6 w-6" />
                </a>
                <a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">
                  <Globe className="h-6 w-6" />
                </a>
              </div>
            </div>
            
            <div>
              <h3 className="text-lg font-bold mb-6">Quick Links</h3>
              <ul className="space-y-3">
                <li><Link to="/" className="text-gray-400 hover:text-amber-500 transition-colors">Home</Link></li>
                <li><a href="#about" className="text-gray-400 hover:text-amber-500 transition-colors">About</a></li>
                <li><a href="#tokenomics" className="text-gray-400 hover:text-amber-500 transition-colors">Tokenomics</a></li>
                <li><a href="#whitepaper" className="text-gray-400 hover:text-amber-500 transition-colors">Whitepaper</a></li>
                <li><Link to="/login" className="text-gray-400 hover:text-amber-500 transition-colors">Login</Link></li>
                <li><Link to="/signup" className="text-gray-400 hover:text-amber-500 transition-colors">Sign Up</Link></li>
              </ul>
            </div>
            
            <div>
              <h3 className="text-lg font-bold mb-6">Resources</h3>
              <ul className="space-y-3">
                <li><a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">Documentation</a></li>
                <li><a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">API</a></li>
                <li><a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">Oracle Network</a></li>
                <li><a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">Security</a></li>
                <li><a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">FAQ</a></li>
              </ul>
            </div>
            
            <div>
              <h3 className="text-lg font-bold mb-6">Contact</h3>
              <ul className="space-y-3">
                <li className="text-gray-400">info@tetragold.io</li>
                <li className="text-gray-400">Support: support@tetragold.io</li>
                <li className="text-gray-400">Partnerships: partners@tetragold.io</li>
              </ul>
            </div>
          </div>
          
          <div className="border-t border-gray-800 mt-12 pt-8 flex flex-col md:flex-row justify-between items-center">
            <p className="text-gray-400 mb-4 md:mb-0">© 2025 Tetra Gold. All rights reserved.</p>
            <div className="flex space-x-6">
              <a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">Privacy Policy</a>
              <a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">Terms of Service</a>
              <a href="#" className="text-gray-400 hover:text-amber-500 transition-colors">Legal</a>
            </div>
          </div>
        </div>
      </footer>
    </div>
  );
}

export default App;