import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { parseEther } from "ethers";
import YDTokenModule from "./YDToken";

const NetworkDeployModule = buildModule("NetworkDeployModule", (m) => {
  // Configuration parameters for different networks
  const initialOwner = m.getParameter("initialOwner", process.env.DEPLOYER_ADDRESS);
  
  // Network-specific addresses (to be configured for each deployment)
  const usdtTokenAddress = m.getParameter("usdtTokenAddress", process.env.USDT_TOKEN_ADDRESS);
  const wethTokenAddress = m.getParameter("wethTokenAddress", process.env.WETH_TOKEN_ADDRESS);
  const uniswapV3RouterAddress = m.getParameter("uniswapV3RouterAddress", process.env.UNISWAP_V3_ROUTER_ADDRESS);
  const uniswapV3QuoterAddress = m.getParameter("uniswapV3QuoterAddress", process.env.UNISWAP_V3_QUOTER_ADDRESS);
  const aavePoolProviderAddress = m.getParameter("aavePoolProviderAddress", process.env.AAVE_POOL_PROVIDER_ADDRESS);
  const aaveDataProviderAddress = m.getParameter("aaveDataProviderAddress", process.env.AAVE_DATA_PROVIDER_ADDRESS);
  
  // Initial ETH reserves for both contracts
  const courseManagerETHReserve = m.getParameter("courseManagerETHReserve", parseEther("1.0")); // 1 ETH
  const stakingSystemETHReserve = m.getParameter("stakingSystemETHReserve", parseEther("1.0")); // 1 ETH
  
  // Deploy YD Token first
  const { ydToken } = m.useModule(YDTokenModule);
  
  // Deploy CourseManager with ETH reserve
  const courseManager = m.contract("CourseManager", [ydToken, initialOwner]);
  
  // Add initial token and ETH reserves to CourseManager
  const mintCourseManagerReserve = m.call(courseManager, "mintTokenReserve", [1000000000000000000000000n]); // 1M tokens
  const addCourseManagerETHReserve = m.call(courseManager, "addETHReserve", [], {
    value: courseManagerETHReserve
  });
  
  // Deploy StakingSystem with network addresses and ETH reserve
  const stakingSystem = m.contract("StakingSystem", [
    ydToken,
    usdtTokenAddress,
    wethTokenAddress,
    uniswapV3RouterAddress,
    uniswapV3QuoterAddress,
    aavePoolProviderAddress,
    aaveDataProviderAddress,
    initialOwner
  ], {
    value: stakingSystemETHReserve
  });

  return {
    ydToken,
    courseManager,
    stakingSystem
  };
});

export default NetworkDeployModule;