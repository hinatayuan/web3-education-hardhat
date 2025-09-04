// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ExchangeLib
 * @dev Shared library for ETH <-> YD token exchanges across contracts
 */
library ExchangeLib {
    using SafeERC20 for IERC20;
    
    // Exchange configuration
    uint256 public constant EXCHANGE_RATE = 4000; // 1 ETH = 4000 YD tokens
    
    // Events
    event TokensPurchased(address indexed buyer, uint256 ethAmount, uint256 tokenAmount);
    event TokensSold(address indexed seller, uint256 tokenAmount, uint256 ethAmount);
    
    // Storage struct for exchange reserves
    struct ExchangeStorage {
        uint256 ethReserve;
        uint256 tokenReserve;
    }
    
    /**
     * @dev Buy YD tokens with ETH
     * @param storage_ Exchange storage reference
     * @param ydToken YD token contract address
     * @param ethAmount Amount of ETH to spend
     * @param recipient Address to receive tokens
     * @return tokenAmount Amount of tokens purchased
     */
    function buyTokens(
        ExchangeStorage storage storage_,
        address ydToken,
        uint256 ethAmount,
        address recipient
    ) internal returns (uint256 tokenAmount) {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        require(storage_.tokenReserve > 0, "Token reserve not initialized");
        
        tokenAmount = ethAmount * EXCHANGE_RATE;
        
        // 确保 YD 金额是完整的 token 单位
        require(tokenAmount % 1e18 == 0, "Token amount must be divisible by 1e18");
        require(storage_.tokenReserve >= tokenAmount, "Insufficient token reserve");
        
        // Update reserves
        storage_.ethReserve += ethAmount;
        storage_.tokenReserve -= tokenAmount;
        
        // Transfer tokens to recipient
        IERC20(ydToken).safeTransfer(recipient, tokenAmount);
        
        emit TokensPurchased(recipient, ethAmount, tokenAmount);
    }
    
    /**
     * @dev Sell YD tokens for ETH
     * @param storage_ Exchange storage reference
     * @param ydToken YD token contract address
     * @param tokenAmount Amount of tokens to sell
     * @param seller Address selling the tokens
     * @return ethAmount Amount of ETH received
     */
    function sellTokens(
        ExchangeStorage storage storage_,
        address ydToken,
        uint256 tokenAmount,
        address seller
    ) internal returns (uint256 ethAmount) {
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(tokenAmount % EXCHANGE_RATE == 0, "Token amount must be divisible by exchange rate");
        
        ethAmount = tokenAmount / EXCHANGE_RATE;
        require(storage_.ethReserve >= ethAmount, "Insufficient ETH reserve");
        
        // Transfer tokens from seller
        IERC20(ydToken).safeTransferFrom(seller, address(this), tokenAmount);
        
        // Update reserves
        storage_.ethReserve -= ethAmount;
        storage_.tokenReserve += tokenAmount;
        
        // Transfer ETH to seller
        payable(seller).transfer(ethAmount);
        
        emit TokensSold(seller, tokenAmount, ethAmount);
    }
    
    /**
     * @dev Convert YD tokens to ETH (internal exchange, no transfers)
     * @param storage_ Exchange storage reference
     * @param ydAmount Amount of YD tokens to convert
     * @return ethAmount Equivalent ETH amount
     */
    function convertYDToETH(
        ExchangeStorage storage storage_,
        uint256 ydAmount
    ) internal returns (uint256 ethAmount) {
        require(ydAmount > 0, "YD amount must be greater than 0");
        require(storage_.ethReserve > 0, "ETH reserve not initialized");
        
        // 确保 YD 金额能被汇率整除，避免精度损失
        require(ydAmount % EXCHANGE_RATE == 0, "YD amount must be divisible by exchange rate");
        
        ethAmount = ydAmount / EXCHANGE_RATE;
        require(ethAmount > 0, "YD amount too small");
        require(storage_.ethReserve >= ethAmount, "Insufficient ETH reserve");
        
        // Update reserves (YD tokens stay in contract, ETH reserve reduced)
        storage_.ethReserve -= ethAmount;
        storage_.tokenReserve += ydAmount;
        
        return ethAmount;
    }
    
    /**
     * @dev Convert ETH to YD tokens (internal exchange, no transfers)
     * @param storage_ Exchange storage reference
     * @param ethAmount Amount of ETH to convert
     * @return ydAmount Equivalent YD token amount
     */
    function convertETHToYD(
        ExchangeStorage storage storage_,
        uint256 ethAmount
    ) internal returns (uint256 ydAmount) {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        require(storage_.tokenReserve > 0, "Token reserve not initialized");
        
        ydAmount = ethAmount * EXCHANGE_RATE;
        
        // 确保生成的 YD 金额是完整的 token 单位
        require(ydAmount % 1e18 == 0, "Generated token amount must be divisible by 1e18");
        require(storage_.tokenReserve >= ydAmount, "Insufficient token reserve");
        
        // Update reserves (ETH added, tokens reduced)
        storage_.ethReserve += ethAmount;
        storage_.tokenReserve -= ydAmount;
        
        return ydAmount;
    }
    
    /**
     * @dev Add ETH to reserve
     * @param storage_ Exchange storage reference
     * @param amount Amount of ETH to add
     */
    function addETHReserve(
        ExchangeStorage storage storage_,
        uint256 amount
    ) internal {
        require(amount > 0, "Amount must be greater than 0");
        storage_.ethReserve += amount;
    }
    
    /**
     * @dev Add tokens to reserve
     * @param storage_ Exchange storage reference
     * @param ydToken YD token contract address
     * @param amount Amount of tokens to add
     * @param from Address to transfer tokens from
     */
    function addTokenReserve(
        ExchangeStorage storage storage_,
        address ydToken,
        uint256 amount,
        address from
    ) internal {
        require(amount > 0, "Amount must be greater than 0");
        IERC20(ydToken).safeTransferFrom(from, address(this), amount);
        storage_.tokenReserve += amount;
    }
    
    /**
     * @dev Get exchange reserves
     * @param storage_ Exchange storage reference
     * @return ethReserve Current ETH reserve
     * @return tokenReserve Current token reserve
     */
    function getReserves(ExchangeStorage storage storage_) 
        internal 
        view 
        returns (uint256 ethReserve, uint256 tokenReserve) 
    {
        return (storage_.ethReserve, storage_.tokenReserve);
    }
    
    /**
     * @dev Calculate token amount for given ETH
     * @param ethAmount Amount of ETH
     * @return tokenAmount Equivalent token amount
     */
    function calculateTokensForETH(uint256 ethAmount) 
        internal 
        pure 
        returns (uint256 tokenAmount) 
    {
        return ethAmount * EXCHANGE_RATE;
    }
    
    /**
     * @dev Calculate ETH amount for given tokens
     * @param tokenAmount Amount of tokens
     * @return ethAmount Equivalent ETH amount
     */
    function calculateETHForTokens(uint256 tokenAmount) 
        internal 
        pure 
        returns (uint256 ethAmount) 
    {
        return tokenAmount / EXCHANGE_RATE;
    }
}