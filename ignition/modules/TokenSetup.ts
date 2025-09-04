import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import UnifiedLocalDeployModule from "./UnifiedDeploy.js";

const TokenSetupModule = buildModule("TokenSetupModule", (m) => {
  // 先部署所有合约
  const { ydToken, courseManager } = m.useModule(UnifiedLocalDeployModule);

  // deployer (YDToken的owner) mint代币给CourseManager合约
  const tokenReserveAmount = 1000000n * 10n**18n; // 100万 YD tokens (DEFAULT_TOKEN_RESERVE)
  m.call(ydToken, "mint", [courseManager, tokenReserveAmount], {
    gasLimit: 200000
  });
  
  // 然后调用CourseManager设置token储备数量
  m.call(courseManager, "setTokenReserve", [tokenReserveAmount], {
    gasLimit: 100000
  });

  return {
    ydToken,
    courseManager,
    tokenReserveAmount
  };
});

export default TokenSetupModule;