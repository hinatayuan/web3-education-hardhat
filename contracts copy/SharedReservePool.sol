// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/ExchangeLib.sol";
import "./YDToken.sol";

/**
 * @title SharedReservePool
 * @dev 共享储备池合约，为多个合约提供 ETH <-> YD token 兑换服务
 * 节省部署成本，只需要一次初始化储备
 */
contract SharedReservePool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ExchangeLib for ExchangeLib.ExchangeStorage;
    
    // Exchange storage for shared reserves
    ExchangeLib.ExchangeStorage public exchangeStorage;
    
    // Token addresses
    address public immutable YD_TOKEN;
    
    // 默认储备配置
    uint256 public constant DEFAULT_TOKEN_RESERVE = 2000000 * 10**18; // 200万 YD tokens (供两个合约使用)
    uint256 public constant DEFAULT_ETH_RESERVE = 0.1 ether; // 0.1 ETH 就足够了
    
    // 授权的合约地址，可以使用储备池
    mapping(address => bool) public authorizedContracts;
    
    // Events
    event ContractAuthorized(address indexed contractAddr, bool authorized);
    event ReservesInitialized(uint256 tokenReserve, uint256 ethReserve);
    event ETHReserveAdded(uint256 amount);
    event TokenReserveAdded(uint256 amount);
    
    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    constructor(address _ydToken, address initialOwner) 
        payable
        Ownable(initialOwner)
    {
        require(msg.value >= DEFAULT_ETH_RESERVE, "Insufficient ETH for reserves");
        require(_ydToken != address(0), "Invalid YD token address");
        
        YD_TOKEN = _ydToken;
        
        // 初始化 ETH 储备
        exchangeStorage.ethReserve = DEFAULT_ETH_RESERVE;
        
        // 注意：Token 储备将在部署后通过 initializeTokenReserve 函数设置
    }
    
    /**
     * @dev 初始化 token 储备（仅在部署后调用一次）
     */
    function initializeTokenReserve() external onlyOwner {
        require(exchangeStorage.tokenReserve == 0, "Token reserve already initialized");
        uint256 actualBalance = IERC20(YD_TOKEN).balanceOf(address(this));
        require(actualBalance >= DEFAULT_TOKEN_RESERVE, "Insufficient token balance");
        
        exchangeStorage.tokenReserve = DEFAULT_TOKEN_RESERVE;
        emit ReservesInitialized(DEFAULT_TOKEN_RESERVE, DEFAULT_ETH_RESERVE);
    }

    /**
     * @dev 授权合约使用储备池
     */
    function authorizeContract(address contractAddr, bool authorized) external onlyOwner {
        authorizedContracts[contractAddr] = authorized;
        emit ContractAuthorized(contractAddr, authorized);
    }
    
    /**
     * @dev 批量授权合约
     */
    function authorizeContracts(address[] calldata contractAddrs, bool authorized) external onlyOwner {
        for (uint256 i = 0; i < contractAddrs.length; i++) {
            authorizedContracts[contractAddrs[i]] = authorized;
            emit ContractAuthorized(contractAddrs[i], authorized);
        }
    }
    
    // ==================== 兑换函数 - 仅授权合约可调用 ====================
    
    /**
     * @dev Buy YD tokens with ETH (for authorized contracts)
     */
    function buyTokens(uint256 ethAmount, address recipient) 
        external 
        onlyAuthorized 
        nonReentrant 
        returns (uint256 tokenAmount) 
    {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        return exchangeStorage.buyTokens(YD_TOKEN, ethAmount, recipient);
    }
    
    /**
     * @dev Sell YD tokens for ETH (for authorized contracts)
     */
    function sellTokens(uint256 tokenAmount, address seller) 
        external 
        onlyAuthorized 
        nonReentrant 
        returns (uint256 ethAmount) 
    {
        return exchangeStorage.sellTokens(YD_TOKEN, tokenAmount, seller);
    }
    
    /**
     * @dev Convert YD tokens to ETH (internal exchange)
     */
    function convertYDToETH(uint256 ydAmount) 
        external 
        onlyAuthorized 
        returns (uint256 ethAmount) 
    {
        return exchangeStorage.convertYDToETH(ydAmount);
    }
    
    /**
     * @dev Convert ETH to YD tokens (internal exchange)
     */
    function convertETHToYD(uint256 ethAmount) 
        external 
        onlyAuthorized 
        returns (uint256 ydAmount) 
    {
        return exchangeStorage.convertETHToYD(ethAmount);
    }
    
    // ==================== 管理员函数 ====================
    
    function addETHReserve() external payable onlyOwner {
        require(msg.value > 0, "Must send ETH");
        exchangeStorage.addETHReserve(msg.value);
        emit ETHReserveAdded(msg.value);
    }
    
    function addTokenReserve(uint256 amount) external onlyOwner {
        exchangeStorage.addTokenReserve(YD_TOKEN, amount, msg.sender);
        emit TokenReserveAdded(amount);
    }
    
    function mintTokenReserve(uint256 amount) external onlyOwner {
        YDToken(YD_TOKEN).mint(address(this), amount);
        exchangeStorage.tokenReserve += amount;
        emit TokenReserveAdded(amount);
    }
    
    // ==================== 查询函数 ====================
    
    function getReserves() external view returns (uint256 ethReserve, uint256 tokenReserve) {
        return exchangeStorage.getReserves();
    }
    
    function getContractBalances() external view returns (uint256 ethBalance, uint256 tokenBalance) {
        return (address(this).balance, IERC20(YD_TOKEN).balanceOf(address(this)));
    }
    
    function isContractAuthorized(address contractAddr) external view returns (bool) {
        return authorizedContracts[contractAddr];
    }
    
    // ==================== 紧急功能 ====================
    
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }
    
    // Receive ETH and auto-add to reserve if from owner
    receive() external payable {
        if (msg.sender == owner()) {
            exchangeStorage.addETHReserve(msg.value);
            emit ETHReserveAdded(msg.value);
        }
    }
}