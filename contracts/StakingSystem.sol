// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

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
    
    // Token addresses
    address public immutable USDT_TOKEN;
    address public immutable LINK_TOKEN;
    
    // AAVE addresses
    address public immutable AAVE_POOL_PROVIDER;
    address public immutable AAVE_DATA_PROVIDER;
    
    address public aavePool;
    address public aUsdtToken; // AAVE aUSDT token for yield tracking
    address public aLinkToken; // AAVE aLINK token for yield tracking
    
    
    // User staking info with precise yield tracking
    struct UserInfo {
        uint256 stakedAmount;           // Original USDT amount staked
        uint256 aTokenBalance;          // aUSDT tokens received from AAVE
        uint256 lastStakeTime;          // Last stake timestamp
        uint256 totalRewardsClaimed;    // Total rewards claimed by user
    }
    
    // User LINK staking info
    struct UserLinkInfo {
        uint256 stakedAmount;           // Original LINK amount staked
        uint256 aTokenBalance;          // aLINK tokens received from AAVE
        uint256 lastStakeTime;          // Last stake timestamp
        uint256 totalRewardsClaimed;    // Total rewards claimed by user
    }
    
    mapping(address => UserInfo) public userInfo;
    mapping(address => UserLinkInfo) public userLinkInfo;
    
    // System statistics
    uint256 public totalStaked;
    uint256 public totalRewardsPaid;
    uint256 public totalLinkStaked;
    uint256 public totalLinkRewardsPaid;
    
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
     * @dev Stake USDT directly into AAVE
     * @param usdtAmount Amount of USDT to stake
     */
    function stake(uint256 usdtAmount) 
        external 
        nonReentrant 
        whenNotPaused 
        validAmount(usdtAmount) 
    {
        // Transfer USDT from user
        IERC20(USDT_TOKEN).safeTransferFrom(msg.sender, address(this), usdtAmount);
        
        // Supply USDT to AAVE and get aTokens
        uint256 aTokenBalanceBefore = IAToken(aUsdtToken).balanceOf(address(this));
        IPool(aavePool).supply(USDT_TOKEN, usdtAmount, address(this), 0);
        uint256 aTokenBalanceAfter = IAToken(aUsdtToken).balanceOf(address(this));
        uint256 aTokensReceived = aTokenBalanceAfter - aTokenBalanceBefore;
        
        // Update user info
        UserInfo storage user = userInfo[msg.sender];
        user.stakedAmount += usdtAmount;
        user.aTokenBalance += aTokensReceived;
        user.lastStakeTime = block.timestamp;
        
        // Update system stats
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