import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import YDTokenModule from "./YDToken.ts";

const UnifiedLocalDeployModule = buildModule("UnifiedLocalDeployModule", (m) => {
  const deployer = m.getAccount(0);
  
  // Sepolia testnet contract addresses
  const usdtAddress = m.getParameter("usdtAddress", "0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0");
  const linkAddress = m.getParameter("linkAddress", "0xf8Fb3713D459D7C1018BD0A49D19b4C44290EBE5");
  const aavePoolProviderAddress = m.getParameter("aavePoolProviderAddress", "0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A");
  const aaveDataProviderAddress = m.getParameter("aaveDataProviderAddress", "0x3e9708d80f7B3e43118013075F7e95CE3AB31F31");

  // Deploy YD Token first 
  const { ydToken } = m.useModule(YDTokenModule);

  // Deploy CourseManager with 0.05 ETH reserve
  const courseManager = m.contract("CourseManager", [
    ydToken, 
    deployer
  ], {
    value: 50000000000000000n, // 0.05 ETH in wei
    gasLimit: 3000000 // 明确指定Gas限制
  });

  // Deploy StakingSystem with USDT and LINK support
  const stakingSystem = m.contract("StakingSystem", [
    usdtAddress,
    linkAddress,
    aavePoolProviderAddress,
    aaveDataProviderAddress,
    deployer
  ]);

  return {
    ydToken,
    courseManager,
    stakingSystem
  };
});

export default UnifiedLocalDeployModule;