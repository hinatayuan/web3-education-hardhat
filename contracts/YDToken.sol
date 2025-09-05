// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title YDToken - 易登平台代币
 * @dev 这是一个标准的ERC20代币合约，用作易登教育平台的主要代币
 * 具备铸造和销毁功能，用于课程购买、质押奖励等场景
 */
contract YDToken is ERC20, Ownable {
    // 初始供应量：10,000个YD代币
    uint256 public constant INITIAL_SUPPLY = 10_000 * 10**18;
    
    /**
     * @dev 构造函数
     * @param initialOwner 合约初始所有者地址
     */
    constructor(address initialOwner) 
        ERC20("YiDeng Platform Token", "YD") 
        Ownable(initialOwner)
    {
        // 向初始所有者铸造初始供应量的代币
        _mint(initialOwner, INITIAL_SUPPLY);
    }
    
    /**
     * @dev 铸造代币功能 - 仅合约所有者可调用
     * @param to 接收新铸造代币的地址
     * @param amount 要铸造的代币数量
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
    
    /**
     * @dev 销毁代币功能 - 任何人都可以销毁自己的代币
     * @param amount 要销毁的代币数量
     */
    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }
}