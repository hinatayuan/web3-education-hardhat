# Hardhat 控制台部署命令

在控制台中逐步执行以下命令：

## 1. 检查环境和账户
```javascript
// 获取部署账户
const [deployer] = await ethers.getSigners();
console.log("Deployer address:", deployer.address);
console.log("Deployer balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");
```

## 2. 验证已部署的YD Token
```javascript
// 连接到已部署的YD Token
const ydTokenAddress = "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853";
const ydToken = await ethers.getContractAt("YDToken", ydTokenAddress);
console.log("YD Token name:", await ydToken.name());
console.log("YD Token symbol:", await ydToken.symbol());
console.log("YD Token total supply:", ethers.formatEther(await ydToken.totalSupply()));
```

## 3. 部署 CourseManagerV2
```javascript
// 获取合约工厂
const CourseManagerV2 = await ethers.getContractFactory("CourseManagerV2");

// 部署合约（带1ETH储备）
console.log("Deploying CourseManagerV2...");
const courseManagerV2 = await CourseManagerV2.deploy(
  ydTokenAddress,
  deployer.address,
  { 
    value: ethers.parseEther("1.0"),
    gasLimit: 6000000
  }
);

// 等待部署完成
await courseManagerV2.waitForDeployment();
const courseManagerV2Address = await courseManagerV2.getAddress();
console.log("CourseManagerV2 deployed to:", courseManagerV2Address);
```

## 4. 设置 CourseManagerV2 储备
```javascript
// 给CourseManagerV2添加YD代币储备
console.log("Adding YD token reserve to CourseManagerV2...");
await ydToken.mint(courseManagerV2Address, ethers.parseEther("1000000"));
console.log("Added 1M YD tokens to CourseManagerV2");

// 检查储备
const reserves = await courseManagerV2.getExchangeReserves();
console.log("ETH Reserve:", ethers.formatEther(reserves[0]), "ETH");
console.log("YD Token Reserve:", ethers.formatEther(reserves[1]), "YD");
```

## 5. 部署 StakingSystemV2（使用Mock地址）
```javascript
// Mock合约地址
const mockAddresses = {
  usdt: "0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6",
  weth: "0x610178dA211FEF7D417bC0e6FeD39F05609AD788", 
  router: "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0",
  quoter: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
  poolProvider: "0x0B306BF915C4d645ff596e518fAf3F9669b97016",
  dataProvider: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
};

// 获取合约工厂
const StakingSystemV2 = await ethers.getContractFactory("StakingSystemV2");

// 部署合约
console.log("Deploying StakingSystemV2...");
const stakingSystemV2 = await StakingSystemV2.deploy(
  ydTokenAddress,
  mockAddresses.usdt,
  mockAddresses.weth,
  mockAddresses.router,
  mockAddresses.quoter,
  mockAddresses.poolProvider,
  mockAddresses.dataProvider,
  deployer.address,
  { 
    value: ethers.parseEther("1.0"),
    gasLimit: 8000000
  }
);

await stakingSystemV2.waitForDeployment();
const stakingSystemV2Address = await stakingSystemV2.getAddress();
console.log("StakingSystemV2 deployed to:", stakingSystemV2Address);
```

## 6. 设置 StakingSystemV2 储备
```javascript
// 给StakingSystemV2添加YD代币储备
console.log("Adding YD token reserve to StakingSystemV2...");
await ydToken.mint(stakingSystemV2Address, ethers.parseEther("1000000"));
console.log("Added 1M YD tokens to StakingSystemV2");

// 检查系统状态
const systemStats = await stakingSystemV2.getSystemStats();
console.log("Total Staked:", ethers.formatEther(systemStats[0]), "USDT");
console.log("ETH Reserve:", ethers.formatEther(systemStats[4]), "ETH");
console.log("YD Balance:", ethers.formatEther(systemStats[5]), "YD");
```

## 7. 最终确认
```javascript
console.log("\n=== 部署完成 ===");
console.log("YD Token:", ydTokenAddress);
console.log("CourseManagerV2:", courseManagerV2Address);
console.log("StakingSystemV2:", stakingSystemV2Address);
console.log("\n所有合约都有1ETH储备用于测试");
```

## 如果遇到错误
如果某个步骤失败，你可以单独重试该步骤，或者询问具体的错误信息。

## 退出控制台
完成后输入：
```javascript
.exit
```