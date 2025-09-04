// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./SharedReservePool.sol";

// Uniswap V3 interfaces
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
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

// AAVE V3 interfaces with aToken support
interface IPool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
    
    function withdraw(
        address asset,
        uint256 amount,
        address to
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

contract StakingSystem is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // Shared reserve pool for YD <-> ETH swaps
    SharedReservePool public immutable sharedReservePool;
    
    // Token addresses
    address public immutable YD_TOKEN;
    address public immutable USDT_TOKEN;
    address public immutable WETH_TOKEN;
    
    // DEX and AAVE addresses
    address public immutable UNISWAP_V3_ROUTER;
    address public immutable UNISWAP_V3_QUOTER;
    address public immutable AAVE_POOL_PROVIDER;
    address public immutable AAVE_DATA_PROVIDER;
    
    address public aavePool;
    address public aUsdtToken; // AAVE aUSDT token for yield tracking
    
    // Uniswap V3 pool fee tiers
    uint24 public constant POOL_FEE_LOW = 500;      // 0.05%
    uint24 public constant POOL_FEE_MEDIUM = 3000;  // 0.3%
    uint24 public constant POOL_FEE_HIGH = 10000;   // 1%
    
    uint24 public poolFee = POOL_FEE_MEDIUM; // Default to 0.3%
    
    // User staking info with precise yield tracking and timelock
    struct UserInfo {
        uint256 stakedAmount;           // Original USDT amount staked
        uint256 aTokenBalance;          // aUSDT tokens received from AAVE
        uint256 lastStakeTime;          // Last stake timestamp
        uint256 totalRewardsClaimed;    // Total rewards claimed by user
        uint256 lastRewardIndex;        // Last reward index for calculations
        uint256 lockEndTime;            // Timelock expiry timestamp
        bool hasTimelock;               // Whether user has timelock enabled
    }
    
    mapping(address => UserInfo) public userInfo;
    
    // System statistics
    uint256 public totalStaked;
    uint256 public totalRewardsPaid;
    uint256 public rewardIndex; // Global reward index for yield calculations
    
    // Configuration - 提高滑点容忍度到 5%
    uint256 public slippageTolerance = 500; // 5% in basis points (从 3% 提高到 5%)
    uint256 public constant MAX_SLIPPAGE = 1000; // 10% max
    
    // Timelock configuration
    uint256 public constant TIMELOCK_DURATION = 30 days; // 30天锁定期
    uint256 public timelockBonusRate = 1200; // 12% bonus for timelock (120 basis points)
    bool public timelockEnabled = true; // 管理员可以开启/关闭时间锁功能
    
    // Events
    event Staked(address indexed user, uint256 ydAmount, uint256 usdtAmount, uint256 aTokenAmount);
    event Withdrawn(address indexed user, uint256 usdtAmount, uint256 aTokenBurned);
    event RewardsClaimed(address indexed user, uint256 rewardAmount);
    event SlippageToleranceUpdated(uint256 newTolerance);
    event PoolFeeUpdated(uint24 newFee);
    event ETHReserveAdded(uint256 amount);
    event YDTokensWithdrawn(address indexed owner, uint256 amount);
    event RewardIndexUpdated(uint256 newIndex);
    event TimelockStaked(address indexed user, uint256 amount, uint256 lockEndTime);
    event TimelockExpired(address indexed user, uint256 unlockedAmount);
    event TimelockBonusRateUpdated(uint256 newRate);
    event TimelockToggled(bool enabled);
    
    modifier validAmount(uint256 amount) {
        require(amount > 0, "Amount must be greater than 0");
        _;
    }
    
    modifier timelockExpired(address user) {
        if (userInfo[user].hasTimelock) {
            require(block.timestamp >= userInfo[user].lockEndTime, "Funds are still locked");
        }
        _;
    }
    
    constructor(
        address _ydToken,
        address _usdtToken,
        address _wethToken,
        address _uniswapV3Router,
        address _uniswapV3Quoter,
        address _aavePoolProvider,
        address _aaveDataProvider,
        address _sharedReservePool,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_sharedReservePool != address(0), "Invalid shared reserve pool address");
        require(_ydToken != address(0), "Invalid YD token address");
        require(_usdtToken != address(0), "Invalid USDT token address");
        require(_wethToken != address(0), "Invalid WETH token address");
        require(_uniswapV3Router != address(0), "Invalid Uniswap V3 router address");
        require(_uniswapV3Quoter != address(0), "Invalid Uniswap V3 quoter address");
        require(_aavePoolProvider != address(0), "Invalid AAVE pool provider address");
        require(_aaveDataProvider != address(0), "Invalid AAVE data provider address");
        
        YD_TOKEN = _ydToken;
        USDT_TOKEN = _usdtToken;
        WETH_TOKEN = _wethToken;
        UNISWAP_V3_ROUTER = _uniswapV3Router;
        UNISWAP_V3_QUOTER = _uniswapV3Quoter;
        AAVE_POOL_PROVIDER = _aavePoolProvider;
        AAVE_DATA_PROVIDER = _aaveDataProvider;
        sharedReservePool = SharedReservePool(payable(_sharedReservePool));
        
        // Get AAVE pool and aToken addresses
        aavePool = IPoolAddressesProvider(_aavePoolProvider).getPool();
        (aUsdtToken,,) = IPoolDataProvider(_aaveDataProvider).getReserveTokensAddresses(_usdtToken);
        
        // Approve tokens for Uniswap V3 and AAVE
        IERC20(_usdtToken).forceApprove(_uniswapV3Router, type(uint256).max);
        IERC20(_usdtToken).forceApprove(aavePool, type(uint256).max);
        
        // Initialize reward index
        rewardIndex = 1e18; // Starting index
        
        // Note: Exchange reserves are handled by SharedReservePool
        // No need to initialize reserves here
    }
    
    /**
     * @dev Stake YD tokens with optional timelock - converts YD -> ETH -> USDT -> AAVE
     * @param ydAmount Amount of YD tokens to stake
     * @param enableTimelock Whether to enable timelock for bonus rewards
     */
    function stake(uint256 ydAmount, bool enableTimelock) 
        external 
        nonReentrant 
        whenNotPaused 
        validAmount(ydAmount) 
    {
        // Transfer YD tokens from user
        IERC20(YD_TOKEN).safeTransferFrom(msg.sender, address(this), ydAmount);
        
        // Step 1: Convert YD -> ETH using shared reserve pool
        // First approve and transfer YD tokens to this contract
        // Then use shared pool to convert YD to ETH
        uint256 ethAmount = sharedReservePool.convertYDToETH(ydAmount);
        
        // Step 2: Swap ETH -> USDT using Uniswap V3
        uint256 usdtAmount = _swapETHToUSDTV3(ethAmount);
        
        // Step 3: Supply USDT to AAVE and get aTokens
        uint256 aTokenBalanceBefore = IAToken(aUsdtToken).balanceOf(address(this));
        IPool(aavePool).supply(USDT_TOKEN, usdtAmount, address(this), 0);
        uint256 aTokenBalanceAfter = IAToken(aUsdtToken).balanceOf(address(this));
        uint256 aTokensReceived = aTokenBalanceAfter - aTokenBalanceBefore;
        
        // Update user info with precise tracking and timelock
        UserInfo storage user = userInfo[msg.sender];
        user.stakedAmount += usdtAmount;
        user.aTokenBalance += aTokensReceived;
        user.lastStakeTime = block.timestamp;
        user.lastRewardIndex = rewardIndex;
        
        // Set timelock if enabled
        if (enableTimelock && timelockEnabled) {
            user.hasTimelock = true;
            user.lockEndTime = block.timestamp + TIMELOCK_DURATION;
            emit TimelockStaked(msg.sender, usdtAmount, user.lockEndTime);
        }
        
        // Update system stats
        totalStaked += usdtAmount;
        
        emit Staked(msg.sender, ydAmount, usdtAmount, aTokensReceived);
    }
    
    /**
     * @dev Withdraw staked USDT from AAVE with precise aToken tracking
     * @param usdtAmount Amount of USDT to withdraw
     */
    function withdraw(uint256 usdtAmount) 
        external 
        nonReentrant 
        validAmount(usdtAmount)
        timelockExpired(msg.sender)
    {
        UserInfo storage user = userInfo[msg.sender];
        require(user.stakedAmount >= usdtAmount, "Insufficient staked amount");
        
        // Check if timelock has expired for bonus emission
        if (user.hasTimelock && block.timestamp >= user.lockEndTime) {
            emit TimelockExpired(msg.sender, user.stakedAmount);
        }
        
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
        
        // Reset timelock if fully withdrawn
        if (user.stakedAmount == 0) {
            user.hasTimelock = false;
            user.lockEndTime = 0;
        }
        
        // Transfer USDT to user
        IERC20(USDT_TOKEN).safeTransfer(msg.sender, withdrawnAmount);
        
        emit Withdrawn(msg.sender, withdrawnAmount, aTokensToBurn);
    }
    
    /**
     * @dev Claim AAVE rewards with precise yield calculation using aToken balance
     * 提取者需要从 AAVE 中提取 USDT 收益
     */
    function claimRewards() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.aTokenBalance > 0, "No staked amount");
        
        // Calculate user's unclaimed rewards based on aToken balance growth
        uint256 userRewards = _calculateUserRewards(msg.sender);
        require(userRewards > 0, "No rewards available");
        
        // Calculate how much aToken to withdraw from AAVE for rewards
        uint256 totalATokenBalance = IAToken(aUsdtToken).balanceOf(address(this));
        uint256 userATokenShare = (user.aTokenBalance * 1e18) / totalATokenBalance;
        uint256 aTokensToWithdraw = (userRewards * userATokenShare) / 1e18;
        
        // Withdraw rewards from AAVE
        uint256 withdrawnAmount = IPool(aavePool).withdraw(
            USDT_TOKEN,
            aTokensToWithdraw,
            address(this)
        );
        
        // Ensure we got at least the expected rewards
        require(withdrawnAmount >= userRewards, "Insufficient withdrawal from AAVE");
        
        // Update user's reward tracking
        user.totalRewardsClaimed += userRewards;
        user.lastRewardIndex = rewardIndex;
        totalRewardsPaid += userRewards;
        
        // Transfer rewards to user
        IERC20(USDT_TOKEN).safeTransfer(msg.sender, userRewards);
        
        emit RewardsClaimed(msg.sender, userRewards);
    }
    
    /**
     * @dev Internal function to swap ETH to USDT using Uniswap V3
     */
    function _swapETHToUSDTV3(uint256 ethAmount) internal returns (uint256) {
        ISwapRouter router = ISwapRouter(UNISWAP_V3_ROUTER);
        
        // Get quote for expected output
        uint256 expectedUsdt = IQuoter(UNISWAP_V3_QUOTER).quoteExactInputSingle(
            WETH_TOKEN,
            USDT_TOKEN,
            poolFee,
            ethAmount,
            0
        );
        
        uint256 minUsdt = expectedUsdt * (10000 - slippageTolerance) / 10000;
        
        // Execute swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_TOKEN,
            tokenOut: USDT_TOKEN,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountIn: ethAmount,
            amountOutMinimum: minUsdt,
            sqrtPriceLimitX96: 0
        });
        
        return router.exactInputSingle{value: ethAmount}(params);
    }
    
    /**
     * @dev Update global reward index based on aToken yield - 简化版本
     */
    function _updateRewardIndex() internal pure {
        // 简化版本：不再更新全局 rewardIndex，直接基于 aToken 余额计算
        // 这样可以减少 gas 消耗并提高精度
        return;
    }
    
    /**
     * @dev Calculate user's unclaimed rewards - 简化版本，基于 aUSDT 余额 + 时间锁奖励
     */
    function _calculateUserRewards(address userAddr) internal view returns (uint256) {
        UserInfo storage user = userInfo[userAddr];
        if (user.aTokenBalance == 0 || user.stakedAmount == 0) return 0;
        
        // 简化计算：直接基于用户的 aToken 余额增长
        uint256 contractATokenBalance = IAToken(aUsdtToken).balanceOf(address(this));
        
        if (contractATokenBalance == 0 || totalStaked == 0) return 0;
        
        // 用户的当前价值 = (用户 aToken 数量 / 总 aToken 数量) * 总 USDT 价值
        uint256 userCurrentValue = (user.aTokenBalance * contractATokenBalance) / 
            IAToken(aUsdtToken).balanceOf(address(this));
        
        // 基础收益 = 当前价值 - 原始质押金额 - 已领取收益
        uint256 baseRewards = 0;
        if (userCurrentValue > user.stakedAmount + user.totalRewardsClaimed) {
            baseRewards = userCurrentValue - user.stakedAmount - user.totalRewardsClaimed;
        }
        
        // 如果有时间锁且已到期，添加奖励
        if (user.hasTimelock && block.timestamp >= user.lockEndTime) {
            uint256 timelockBonus = (baseRewards * timelockBonusRate) / 10000;
            return baseRewards + timelockBonus;
        }
        
        return baseRewards;
    }
    
    /**
     * @dev Get user's staking information with precise yield data
     */
    function getUserInfo(address user) external view returns (
        uint256 stakedAmount,
        uint256 aTokenBalance,
        uint256 lastStakeTime,
        uint256 totalRewardsClaimed,
        uint256 availableRewards,
        uint256 currentValue,
        bool hasTimelock,
        uint256 lockEndTime,
        bool isUnlocked
    ) {
        UserInfo memory info = userInfo[user];
        uint256 available = _calculateUserRewards(user);
        
        // Calculate current value of user's position
        uint256 currentVal = info.aTokenBalance > 0 ? 
            IAToken(aUsdtToken).balanceOf(address(this)) * info.stakedAmount / totalStaked : 0;
        
        return (
            info.stakedAmount,
            info.aTokenBalance,
            info.lastStakeTime,
            info.totalRewardsClaimed,
            available,
            currentVal,
            info.hasTimelock,
            info.lockEndTime,
            !info.hasTimelock || block.timestamp >= info.lockEndTime
        );
    }
    
    /**
     * @dev Get system statistics with detailed AAVE data
     */
    function getSystemStats() external view returns (
        uint256 _totalStaked,
        uint256 _totalRewardsPaid,
        uint256 _totalATokens,
        uint256 _availableRewards,
        uint256 _ethReserve,
        uint256 _ydBalance,
        uint256 _currentAPY
    ) {
        uint256 totalATokens = IAToken(aUsdtToken).balanceOf(address(this));
        uint256 availableRewards = totalATokens > totalStaked ? totalATokens - totalStaked : 0;
        uint256 ydBalance = IERC20(YD_TOKEN).balanceOf(address(this));
        
        // Calculate approximate APY based on AAVE reserve data
        (, , , , , uint256 liquidityRate, , , , , ,) = 
            IPoolDataProvider(AAVE_DATA_PROVIDER).getReserveData(USDT_TOKEN);
        uint256 currentAPY = liquidityRate / 1e23; // Convert from ray to percentage
        
        return (
            totalStaked, 
            totalRewardsPaid, 
            totalATokens, 
            availableRewards, 
            0, // ETH reserve is in shared pool
            ydBalance,
            currentAPY
        );
    }
    
    // Admin functions
    function setSlippageTolerance(uint256 _slippageTolerance) external onlyOwner {
        require(_slippageTolerance <= MAX_SLIPPAGE, "Slippage too high");
        slippageTolerance = _slippageTolerance;
        emit SlippageToleranceUpdated(_slippageTolerance);
    }
    
    function setPoolFee(uint24 _poolFee) external onlyOwner {
        require(
            _poolFee == POOL_FEE_LOW || 
            _poolFee == POOL_FEE_MEDIUM || 
            _poolFee == POOL_FEE_HIGH, 
            "Invalid pool fee"
        );
        poolFee = _poolFee;
        emit PoolFeeUpdated(_poolFee);
    }
    
    // Timelock management functions
    function setTimelockBonusRate(uint256 _bonusRate) external onlyOwner {
        require(_bonusRate <= 5000, "Bonus rate too high (max 50%)");
        timelockBonusRate = _bonusRate;
        emit TimelockBonusRateUpdated(_bonusRate);
    }
    
    function toggleTimelock(bool _enabled) external onlyOwner {
        timelockEnabled = _enabled;
        emit TimelockToggled(_enabled);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Add ETH to shared reserve pool
    function addETHReserveToPool() external payable onlyOwner {
        require(msg.value > 0, "Must send ETH");
        sharedReservePool.addETHReserve{value: msg.value}();
        emit ETHReserveAdded(msg.value);
    }
    
    // Add YD tokens to shared reserve pool
    function addYDTokenReserveToPool(uint256 amount) external onlyOwner {
        IERC20(YD_TOKEN).transferFrom(msg.sender, address(this), amount);
        IERC20(YD_TOKEN).approve(address(sharedReservePool), amount);
        sharedReservePool.addTokenReserve(amount);
    }
    
    // Emergency functions
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
    
    // Receive ETH - simple implementation since using shared reserve
    receive() external payable {
        // Just accept ETH, owner can manually add to shared reserve pool if needed
    }
}