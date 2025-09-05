// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// ===== Uniswap V3 接口定义 =====
// 用于代币交换功能（当前未使用，保留供未来扩展）
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;         // 输入代币地址
        address tokenOut;        // 输出代币地址
        uint24 fee;              // 手续费等级
        address recipient;       // 接收者地址
        uint256 deadline;        // 交易截止时间
        uint256 amountIn;        // 输入数量
        uint256 amountOutMinimum; // 最小输出数量
        uint160 sqrtPriceLimitX96; // 价格限制
    }
    
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

interface IQuoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

// ===== AAVE V3 核心接口定义 =====
// 用于与AAVE协议交互，实现资产存取和收益获取
interface IPool {
    // 向AAVE存入资产
    function supply(
        address asset,       // 要存入的资产地址
        uint256 amount,      // 存入数量
        address onBehalfOf,  // 代表存入的地址
        uint16 referralCode  // 推荐码
    ) external;
    
    // 从AAVE提取资产
    function withdraw(
        address asset,  // 要提取的资产地址
        uint256 amount, // 提取数量
        address to      // 接收地址
    ) external returns (uint256);
    
    function getUserAccountData(address user)
        external view returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

// AAVE aToken interface for precise yield calculations
interface IAToken is IERC20 {
    function getScaledBalanceOf(address user) external view returns (uint256);
    function scaledTotalSupply() external view returns (uint256);
    function getIncentivesController() external view returns (address);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

// AAVE Pool Data Provider for getting aToken addresses
interface IPoolDataProvider {
    function getReserveTokensAddresses(address asset)
        external view returns (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        );
    
    function getReserveData(address asset)
        external view returns (
            uint256 unbacked,
            uint256 accruedToTreasuryScaled,
            uint256 totalAToken,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        );
}

/**
 * @title StakingSystem - 质押系统合约
 * @dev 这是一个基于AAVE协议的质押收益系统
 * 主要功能包括：
 * 1. 用户可以质押USDT和LINK代币
 * 2. 质押的代币会自动存入AAVE协议获取收益
 * 3. 用户可以随时提取本金和收益
 * 4. 支持暂停和紧急操作
 */
contract StakingSystem is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // 支持的代币地址
    address public immutable USDT_TOKEN; // USDT代币地址
    address public immutable LINK_TOKEN; // LINK代币地址
    
    // AAVE协议相关地址
    address public immutable AAVE_POOL_PROVIDER;  // AAVE池地址提供者
    address public immutable AAVE_DATA_PROVIDER;  // AAVE数据提供者
    
    address public aavePool;    // AAVE池合约地址
    address public aUsdtToken;  // AAVE aUSDT代币（用于收益追踪）
    address public aLinkToken;  // AAVE aLINK代币（用于收益追踪）
    
    
    // USDT质押用户信息结构体
    struct UserInfo {
        uint256 stakedAmount;        // 用户原始质押USDT数量
        uint256 aTokenBalance;       // 从AAVE获得的aUSDT代币数量
        uint256 lastStakeTime;       // 最近一次质押时间戳
        uint256 totalRewardsClaimed; // 用户已累计提取的收益
    }
    
    // LINK质押用户信息结构体
    struct UserLinkInfo {
        uint256 stakedAmount;        // 用户原始质押LINK数量
        uint256 aTokenBalance;       // 从AAVE获得的aLINK代币数量
        uint256 lastStakeTime;       // 最近一次质押时间戳
        uint256 totalRewardsClaimed; // 用户已累计提取的收益
    }
    
    // 存储映射
    mapping(address => UserInfo) public userInfo;         // 用户地址 => USDT质押信息
    mapping(address => UserLinkInfo) public userLinkInfo; // 用户地址 => LINK质押信息
    
    // 系统统计数据
    uint256 public totalStaked;          // USDT总质押量
    uint256 public totalRewardsPaid;     // USDT已支付总收益
    uint256 public totalLinkStaked;      // LINK总质押量
    uint256 public totalLinkRewardsPaid; // LINK已支付总收益
    
    // Events
    event Staked(address indexed user, uint256 usdtAmount, uint256 aTokenAmount);
    event Withdrawn(address indexed user, uint256 usdtAmount, uint256 aTokenBurned);
    event RewardsClaimed(address indexed user, uint256 rewardAmount);
    
    event LinkStaked(address indexed user, uint256 linkAmount, uint256 aTokenAmount);
    event LinkWithdrawn(address indexed user, uint256 linkAmount, uint256 aTokenBurned);
    event LinkRewardsClaimed(address indexed user, uint256 rewardAmount);
    
    modifier validAmount(uint256 amount) {
        require(amount > 0, "Amount must be greater than 0");
        _;
    }
    
    constructor(
        address _usdtToken,
        address _linkToken,
        address _aavePoolProvider,
        address _aaveDataProvider,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_usdtToken != address(0), "Invalid USDT token address");
        require(_linkToken != address(0), "Invalid LINK token address");
        require(_aavePoolProvider != address(0), "Invalid AAVE pool provider address");
        require(_aaveDataProvider != address(0), "Invalid AAVE data provider address");
        
        USDT_TOKEN = _usdtToken;
        LINK_TOKEN = _linkToken;
        AAVE_POOL_PROVIDER = _aavePoolProvider;
        AAVE_DATA_PROVIDER = _aaveDataProvider;
        
        // Get AAVE pool and aToken addresses
        aavePool = IPoolAddressesProvider(_aavePoolProvider).getPool();
        (aUsdtToken,,) = IPoolDataProvider(_aaveDataProvider).getReserveTokensAddresses(_usdtToken);
        (aLinkToken,,) = IPoolDataProvider(_aaveDataProvider).getReserveTokensAddresses(_linkToken);
        
        // Approve tokens for AAVE
        IERC20(_usdtToken).forceApprove(aavePool, type(uint256).max);
        IERC20(_linkToken).forceApprove(aavePool, type(uint256).max);
    }
    
    /**
     * @dev 质押USDT到AAVE协议获取收益
     * @param usdtAmount 要质押的USDT数量
     * 流程：用户USDT -> 合约 -> AAVE协议 -> 获得aUSDT代币
     * aUSDT代币会随时间自动增值，实现收益的自动复利
     */
    function stake(uint256 usdtAmount) 
        external 
        nonReentrant 
        whenNotPaused 
        validAmount(usdtAmount) 
    {
        // 从用户转移USDT到合约
        IERC20(USDT_TOKEN).safeTransferFrom(msg.sender, address(this), usdtAmount);
        
        // 将USDT存入AAVE并获得aToken
        uint256 aTokenBalanceBefore = IAToken(aUsdtToken).balanceOf(address(this));
        IPool(aavePool).supply(USDT_TOKEN, usdtAmount, address(this), 0);
        uint256 aTokenBalanceAfter = IAToken(aUsdtToken).balanceOf(address(this));
        uint256 aTokensReceived = aTokenBalanceAfter - aTokenBalanceBefore;
        
        // 更新用户信息
        UserInfo storage user = userInfo[msg.sender];
        user.stakedAmount += usdtAmount;      // 累加质押量
        user.aTokenBalance += aTokensReceived; // 累加aToken余额
        user.lastStakeTime = block.timestamp;  // 更新质押旰间
        
        // 更新系统统计
        totalStaked += usdtAmount;
        
        emit Staked(msg.sender, usdtAmount, aTokensReceived);
    }
    
    /**
     * @dev Stake LINK directly into AAVE
     * @param linkAmount Amount of LINK to stake
     */
    function stakeLINK(uint256 linkAmount) 
        external 
        nonReentrant 
        whenNotPaused 
        validAmount(linkAmount) 
    {
        // Transfer LINK from user
        IERC20(LINK_TOKEN).safeTransferFrom(msg.sender, address(this), linkAmount);
        
        // Supply LINK to AAVE and get aTokens
        uint256 aTokenBalanceBefore = IAToken(aLinkToken).balanceOf(address(this));
        IPool(aavePool).supply(LINK_TOKEN, linkAmount, address(this), 0);
        uint256 aTokenBalanceAfter = IAToken(aLinkToken).balanceOf(address(this));
        uint256 aTokensReceived = aTokenBalanceAfter - aTokenBalanceBefore;
        
        // Update user info
        UserLinkInfo storage user = userLinkInfo[msg.sender];
        user.stakedAmount += linkAmount;
        user.aTokenBalance += aTokensReceived;
        user.lastStakeTime = block.timestamp;
        
        // Update system stats
        totalLinkStaked += linkAmount;
        
        emit LinkStaked(msg.sender, linkAmount, aTokensReceived);
    }
    
    /**
     * @dev Withdraw staked USDT from AAVE
     * @param usdtAmount Amount of USDT to withdraw
     */
    function withdraw(uint256 usdtAmount) 
        external 
        nonReentrant 
        validAmount(usdtAmount)
    {
        UserInfo storage user = userInfo[msg.sender];
        require(user.stakedAmount >= usdtAmount, "Insufficient staked amount");
        
        // Calculate proportional aToken amount to burn
        uint256 aTokensToBurn = (user.aTokenBalance * usdtAmount) / user.stakedAmount;
        
        // Withdraw from AAVE (burns aTokens)
        uint256 withdrawnAmount = IPool(aavePool).withdraw(
            USDT_TOKEN, 
            aTokensToBurn, 
            address(this)
        );
        
        // Update user info
        user.stakedAmount -= usdtAmount;
        user.aTokenBalance -= aTokensToBurn;
        totalStaked -= usdtAmount;
        
        // Transfer USDT to user
        IERC20(USDT_TOKEN).safeTransfer(msg.sender, withdrawnAmount);
        
        emit Withdrawn(msg.sender, withdrawnAmount, aTokensToBurn);
    }
    
    /**
     * @dev Withdraw staked LINK from AAVE
     * @param linkAmount Amount of LINK to withdraw
     */
    function withdrawLINK(uint256 linkAmount) 
        external 
        nonReentrant 
        validAmount(linkAmount)
    {
        UserLinkInfo storage user = userLinkInfo[msg.sender];
        require(user.stakedAmount >= linkAmount, "Insufficient staked amount");
        
        // Calculate proportional aToken amount to burn
        uint256 aTokensToBurn = (user.aTokenBalance * linkAmount) / user.stakedAmount;
        
        // Withdraw from AAVE (burns aTokens)
        uint256 withdrawnAmount = IPool(aavePool).withdraw(
            LINK_TOKEN, 
            aTokensToBurn, 
            address(this)
        );
        
        // Update user info
        user.stakedAmount -= linkAmount;
        user.aTokenBalance -= aTokensToBurn;
        totalLinkStaked -= linkAmount;
        
        // Transfer LINK to user
        IERC20(LINK_TOKEN).safeTransfer(msg.sender, withdrawnAmount);
        
        emit LinkWithdrawn(msg.sender, withdrawnAmount, aTokensToBurn);
    }
    
    /**
     * @dev Claim AAVE rewards - withdraw earned USDT from AAVE
     */
    function claimRewards() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.aTokenBalance > 0, "No staked amount");
        
        // Calculate user's unclaimed rewards based on aToken balance growth
        uint256 userRewards = _calculateUserRewards(msg.sender);
        require(userRewards > 0, "No rewards available");
        
        // Withdraw rewards from AAVE (proportional to user's rewards)
        uint256 withdrawnAmount = IPool(aavePool).withdraw(
            USDT_TOKEN,
            userRewards,
            address(this)
        );
        
        // Update user's reward tracking
        user.totalRewardsClaimed += withdrawnAmount;
        totalRewardsPaid += withdrawnAmount;
        
        // Transfer rewards to user
        IERC20(USDT_TOKEN).safeTransfer(msg.sender, withdrawnAmount);
        
        emit RewardsClaimed(msg.sender, withdrawnAmount);
    }
    
    /**
     * @dev Claim AAVE rewards for LINK - withdraw earned LINK from AAVE
     */
    function claimLinkRewards() external nonReentrant {
        UserLinkInfo storage user = userLinkInfo[msg.sender];
        require(user.aTokenBalance > 0, "No staked amount");
        
        // Calculate user's unclaimed rewards based on aToken balance growth
        uint256 userRewards = _calculateUserLinkRewards(msg.sender);
        require(userRewards > 0, "No rewards available");
        
        // Withdraw rewards from AAVE (proportional to user's rewards)
        uint256 withdrawnAmount = IPool(aavePool).withdraw(
            LINK_TOKEN,
            userRewards,
            address(this)
        );
        
        // Update user's reward tracking
        user.totalRewardsClaimed += withdrawnAmount;
        totalLinkRewardsPaid += withdrawnAmount;
        
        // Transfer rewards to user
        IERC20(LINK_TOKEN).safeTransfer(msg.sender, withdrawnAmount);
        
        emit LinkRewardsClaimed(msg.sender, withdrawnAmount);
    }
    
    /**
     * @dev Calculate user's unclaimed rewards based on aToken balance growth
     */
    function _calculateUserRewards(address userAddr) internal view returns (uint256) {
        UserInfo storage user = userInfo[userAddr];
        if (user.aTokenBalance == 0 || user.stakedAmount == 0) return 0;
        
        // Current value of user's aTokens in USDT terms
        uint256 currentATokenValue = user.aTokenBalance;
        
        // Basic rewards = current aToken value - original staked amount - already claimed rewards
        if (currentATokenValue > user.stakedAmount + user.totalRewardsClaimed) {
            return currentATokenValue - user.stakedAmount - user.totalRewardsClaimed;
        }
        
        return 0;
    }
    
    /**
     * @dev Calculate user's unclaimed LINK rewards based on aToken balance growth
     */
    function _calculateUserLinkRewards(address userAddr) internal view returns (uint256) {
        UserLinkInfo storage user = userLinkInfo[userAddr];
        if (user.aTokenBalance == 0 || user.stakedAmount == 0) return 0;
        
        // Current value of user's aTokens in LINK terms
        uint256 currentATokenValue = user.aTokenBalance;
        
        // Basic rewards = current aToken value - original staked amount - already claimed rewards
        if (currentATokenValue > user.stakedAmount + user.totalRewardsClaimed) {
            return currentATokenValue - user.stakedAmount - user.totalRewardsClaimed;
        }
        
        return 0;
    }
    
    /**
     * @dev Get user's staking information
     */
    function getUserInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 aTokenBalance,
        uint256 lastStakeTime,
        uint256 totalRewardsClaimed,
        uint256 availableRewards,
        uint256 currentValue
    ) {
        UserInfo memory info = userInfo[user];
        uint256 available = _calculateUserRewards(user);
        
        // Calculate current value of user's position (aToken balance represents current value)
        uint256 currentVal = info.aTokenBalance;
        
        return (
            info.stakedAmount,
            info.aTokenBalance,
            info.lastStakeTime,
            info.totalRewardsClaimed,
            available,
            currentVal
        );
    }
    
    /**
     * @dev Get user's LINK staking information
     */
    function getUserLinkInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 aTokenBalance,
        uint256 lastStakeTime,
        uint256 totalRewardsClaimed,
        uint256 availableRewards,
        uint256 currentValue
    ) {
        UserLinkInfo memory info = userLinkInfo[user];
        uint256 available = _calculateUserLinkRewards(user);
        
        // Calculate current value of user's position (aToken balance represents current value)
        uint256 currentVal = info.aTokenBalance;
        
        return (
            info.stakedAmount,
            info.aTokenBalance,
            info.lastStakeTime,
            info.totalRewardsClaimed,
            available,
            currentVal
        );
    }
    
    /**
     * @dev Get system statistics with AAVE data
     */
    function getSystemStats() external view returns (
        uint256 _totalStaked,
        uint256 _totalRewardsPaid,
        uint256 _totalATokens,
        uint256 _availableRewards,
        uint256 _currentAPY
    ) {
        uint256 totalATokens = IAToken(aUsdtToken).balanceOf(address(this));
        uint256 availableRewards = totalATokens > totalStaked ? totalATokens - totalStaked : 0;
        
        // Calculate approximate APY based on AAVE reserve data
        (, , , , , uint256 liquidityRate, , , , , ,) = 
            IPoolDataProvider(AAVE_DATA_PROVIDER).getReserveData(USDT_TOKEN);
        uint256 currentAPY = liquidityRate / 1e23; // Convert from ray to percentage
        
        return (
            totalStaked, 
            totalRewardsPaid, 
            totalATokens, 
            availableRewards,
            currentAPY
        );
    }
    
    /**
     * @dev Get LINK system statistics with AAVE data
     */
    function getLinkSystemStats() external view returns (
        uint256 _totalLinkStaked,
        uint256 _totalLinkRewardsPaid,
        uint256 _totalLinkATokens,
        uint256 _availableLinkRewards,
        uint256 _currentLinkAPY
    ) {
        uint256 totalATokens = IAToken(aLinkToken).balanceOf(address(this));
        uint256 availableRewards = totalATokens > totalLinkStaked ? totalATokens - totalLinkStaked : 0;
        
        // Calculate approximate APY based on AAVE reserve data
        (, , , , , uint256 liquidityRate, , , , , ,) = 
            IPoolDataProvider(AAVE_DATA_PROVIDER).getReserveData(LINK_TOKEN);
        uint256 currentAPY = liquidityRate / 1e23; // Convert from ray to percentage
        
        return (
            totalLinkStaked, 
            totalLinkRewardsPaid, 
            totalATokens, 
            availableRewards,
            currentAPY
        );
    }
    
    // Admin functions
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Emergency functions
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }
}