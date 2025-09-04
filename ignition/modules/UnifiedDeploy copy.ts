import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import YDTokenModule from "./YDToken.js";

const UnifiedLocalDeployModule = buildModule("UnifiedLocalDeployModule", (m) => {
  const initialOwner = m.getParameter("initialOwner", "0xE88b9063227f1B0B40FD0104cdE9d0893dD8A8c7");
  
  // Sepolia testnet contract addresses
  const usdtAddress = m.getParameter("usdtAddress", "0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0");
  const wethAddress = m.getParameter("wethAddress", "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14");
  const uniswapV3RouterAddress = m.getParameter("uniswapV3RouterAddress", "0x0227628f3F023bb0B980b67D528571c95c6DaC1c");
  const uniswapV3QuoterAddress = m.getParameter("uniswapV3QuoterAddress", "0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3");
  const aavePoolProviderAddress = m.getParameter("aavePoolProviderAddress", "0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A");
  const aaveDataProviderAddress = m.getParameter("aaveDataProviderAddress", "0x3e9708d80f7B3e43118013075F7e95CE3AB31F31");

  // Deploy YD Token first
  const { ydToken } = m.useModule(YDTokenModule);

  // 🚀 Deploy SharedReservePool with 0.1 ETH
  const sharedReservePool = m.contract("SharedReservePool", [ydToken, initialOwner], {
    value: 100000000000000000n // 0.1 ETH in wei
  });

  // Mint tokens for SharedReservePool after deployment
  m.call(ydToken, "mint", [sharedReservePool, 2000000000000000000000000n]); // 2,000,000 * 10^18
  
  // Initialize token reserves in SharedReservePool
  m.call(sharedReservePool, "initializeTokenReserve", []);

  // Deploy CourseManager (now uses shared reserve pool)
  const courseManager = m.contract("CourseManager", [
    ydToken, 
    sharedReservePool, 
    initialOwner
  ]);

  // Deploy StakingSystem (now uses shared reserve pool)
  const stakingSystem = m.contract("StakingSystem", [
    ydToken,
    usdtAddress,
    wethAddress,
    uniswapV3RouterAddress,
    uniswapV3QuoterAddress,
    aavePoolProviderAddress,
    aaveDataProviderAddress,
    sharedReservePool,
    initialOwner
  ]);

  // 🔑 Authorize both contracts to use the shared reserve pool
  m.call(sharedReservePool, "authorizeContracts", [
    [courseManager, stakingSystem], 
    true
  ]);

  return {
    sharedReservePool,
    courseManager,
    stakingSystem
  };
});

export default UnifiedLocalDeployModule;