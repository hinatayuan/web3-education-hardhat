import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  
  console.log("部署者地址:", deployer.address);
  console.log("ETH余额:", ethers.formatEther(await deployer.provider.getBalance(deployer.address)), "ETH");
  
  // YD Token合约地址
  const ydTokenAddress = "0x4Bb8eC7934053dEcFE988346B703FB48Db711aa8";
  
  // 连接到YD Token合约
  const YDToken = await ethers.getContractFactory("YDToken");
  const ydToken = YDToken.attach(ydTokenAddress);
  
  // 检查部署者的YD代币余额
  const balance = await ydToken.balanceOf(deployer.address);
  console.log("YD代币余额:", ethers.formatEther(balance), "YD");
  
  // 检查代币总供应量
  const totalSupply = await ydToken.totalSupply();
  console.log("YD代币总供应量:", ethers.formatEther(totalSupply), "YD");
  
  // 检查CourseManager合约的代币余额
  const courseManagerAddress = "0x2D58753d73DEF62263aE81C2D35817C42494cEF2";
  const courseManagerBalance = await ydToken.balanceOf(courseManagerAddress);
  console.log("CourseManager合约的YD代币余额:", ethers.formatEther(courseManagerBalance), "YD");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});