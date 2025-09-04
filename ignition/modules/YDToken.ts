import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("YDTokenModule", (m) => {
  const deployer = m.getAccount(0);
  
  const ydToken = m.contract("YDToken", [deployer]);

  return { ydToken };
});