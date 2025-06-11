// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IOracleAggregator.sol";
import "./interfaces/ICircuitBreaker.sol";

/**
 * @title TGAUx - TetraGold Synthetic Token
 * @dev Algorithmic gold-backed token with multi-oracle price feeds and security controls
 * @author TetraGold Team
 */
contract TGAUx is 
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // Role definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // State variables
    IOracleAggregator public oracleAggregator;
    ICircuitBreaker public circuitBreaker;
    
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_SUPPLY = 100_000_000 * PRECISION; // 100M tokens
    uint256 public constant MIN_MINT_AMOUNT = 1e15; // 0.001 tokens
    uint256 public constant MAX_MINT_AMOUNT = 1_000_000 * PRECISION; // 1M tokens per tx
    
    uint256 public mintFee; // Basis points (100 = 1%)
    uint256 public redeemFee; // Basis points (100 = 1%)
    uint256 public lastPriceUpdate;
    uint256 public emergencyPauseDuration;
    
    bool public emergencyMode;
    address public feeRecipient;
    
    // Events
    event Mint(address indexed user, uint256 usdAmount, uint256 tokenAmount, uint256 fee);
    event Redeem(address indexed user, uint256 tokenAmount, uint256 usdAmount, uint256 fee);
    event PriceUpdate(uint256 newPrice, uint256 timestamp);
    event EmergencyModeActivated(address indexed activator, string reason);
    event EmergencyModeDeactivated(address indexed deactivator);
    event FeesUpdated(uint256 mintFee, uint256 redeemFee);
    event OracleAggregatorUpdated(address indexed newAggregator);
    event CircuitBreakerTriggered(uint256 oldPrice, uint256 newPrice, uint256 deviation);

    // Errors
    error InvalidAmount();
    error InsufficientBalance();
    error ExceedsMaxSupply();
    error PriceStale();
    error CircuitBreakerActive();
    error EmergencyModeActive();
    error InvalidFeeRecipient();
    error InvalidOracle();
    error UnauthorizedUpgrade();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _oracleAggregator Oracle aggregator contract address
     * @param _circuitBreaker Circuit breaker contract address
     * @param _feeRecipient Address to receive fees
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _oracleAggregator,
        address _circuitBreaker,
        address _feeRecipient
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(ORACLE_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        // Set initial parameters
        oracleAggregator = IOracleAggregator(_oracleAggregator);
        circuitBreaker = ICircuitBreaker(_circuitBreaker);
        feeRecipient = _feeRecipient;
        mintFee = 50; // 0.5%
        redeemFee = 50; // 0.5%
        emergencyPauseDuration = 24 hours;
        lastPriceUpdate = block.timestamp;
    }

    /**
     * @dev Mint TGAUx tokens by depositing USD equivalent
     * @param usdAmount Amount of USD to deposit (in wei precision)
     * @param minTokensOut Minimum tokens to receive (slippage protection)
     */
    function mint(uint256 usdAmount, uint256 minTokensOut) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (emergencyMode) revert EmergencyModeActive();
        if (usdAmount < MIN_MINT_AMOUNT || usdAmount > MAX_MINT_AMOUNT) {
            revert InvalidAmount();
        }

        // Get current gold price from oracle
        uint256 goldPrice = _getValidatedPrice();
        
        // Calculate tokens to mint (1 token = $1 worth of gold)
        uint256 tokensToMint = (usdAmount * PRECISION) / goldPrice;
        
        // Apply mint fee
        uint256 fee = (tokensToMint * mintFee) / 10000;
        uint256 tokensAfterFee = tokensToMint - fee;
        
        // Slippage protection
        if (tokensAfterFee < minTokensOut) revert InvalidAmount();
        
        // Check max supply
        if (totalSupply() + tokensToMint > MAX_SUPPLY) {
            revert ExceedsMaxSupply();
        }

        // Mint tokens
        _mint(msg.sender, tokensAfterFee);
        if (fee > 0) {
            _mint(feeRecipient, fee);
        }

        emit Mint(msg.sender, usdAmount, tokensAfterFee, fee);
    }

    /**
     * @dev Redeem TGAUx tokens for USD equivalent
     * @param tokenAmount Amount of tokens to redeem
     * @param minUsdOut Minimum USD to receive (slippage protection)
     */
    function redeem(uint256 tokenAmount, uint256 minUsdOut) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (emergencyMode) revert EmergencyModeActive();
        if (tokenAmount == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < tokenAmount) revert InsufficientBalance();

        // Get current gold price from oracle
        uint256 goldPrice = _getValidatedPrice();
        
        // Calculate USD to return
        uint256 usdAmount = (tokenAmount * goldPrice) / PRECISION;
        
        // Apply redeem fee
        uint256 fee = (usdAmount * redeemFee) / 10000;
        uint256 usdAfterFee = usdAmount - fee;
        
        // Slippage protection
        if (usdAfterFee < minUsdOut) revert InvalidAmount();

        // Burn tokens
        _burn(msg.sender, tokenAmount);

        emit Redeem(msg.sender, tokenAmount, usdAfterFee, fee);
    }

    /**
     * @dev Get validated price from oracle aggregator with circuit breaker check
     */
    function _getValidatedPrice() internal returns (uint256) {
        (uint256 price, uint256 timestamp) = oracleAggregator.getLatestPrice();
        
        // Check price staleness (max 1 hour old)
        if (block.timestamp - timestamp > 3600) revert PriceStale();
        
        // Check circuit breaker
        if (circuitBreaker.isTriggered()) revert CircuitBreakerActive();
        
        // Update circuit breaker with new price
        circuitBreaker.checkPrice(price);
        
        lastPriceUpdate = timestamp;
        emit PriceUpdate(price, timestamp);
        
        return price;
    }

    /**
     * @dev Get current token price without state changes
     */
    function getCurrentPrice() external view returns (uint256 price, uint256 timestamp) {
        return oracleAggregator.getLatestPrice();
    }

    /**
     * @dev Emergency pause function
     */
    function emergencyPause(string calldata reason) 
        external 
        onlyRole(EMERGENCY_ROLE) 
    {
        emergencyMode = true;
        _pause();
        emit EmergencyModeActivated(msg.sender, reason);
    }

    /**
     * @dev Deactivate emergency mode
     */
    function deactivateEmergency() 
        external 
        onlyRole(EMERGENCY_ROLE) 
    {
        emergencyMode = false;
        _unpause();
        emit EmergencyModeDeactivated(msg.sender);
    }

    /**
     * @dev Update fee parameters
     */
    function updateFees(uint256 _mintFee, uint256 _redeemFee) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(_mintFee <= 1000 && _redeemFee <= 1000, "Fee too high"); // Max 10%
        mintFee = _mintFee;
        redeemFee = _redeemFee;
        emit FeesUpdated(_mintFee, _redeemFee);
    }

    /**
     * @dev Update oracle aggregator
     */
    function updateOracleAggregator(address _newAggregator) 
        external 
        onlyRole(ORACLE_MANAGER_ROLE) 
    {
        if (_newAggregator == address(0)) revert InvalidOracle();
        oracleAggregator = IOracleAggregator(_newAggregator);
        emit OracleAggregatorUpdated(_newAggregator);
    }

    /**
     * @dev Update fee recipient
     */
    function updateFeeRecipient(address _newRecipient) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (_newRecipient == address(0)) revert InvalidFeeRecipient();
        feeRecipient = _newRecipient;
    }

    /**
     * @dev Pause contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Authorize upgrade (UUPS pattern)
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        onlyRole(UPGRADER_ROLE) 
        override 
    {
        // Additional upgrade validation can be added here
        if (newImplementation == address(0)) revert UnauthorizedUpgrade();
    }

    /**
     * @dev Override transfer to add pause functionality
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @dev Get contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}