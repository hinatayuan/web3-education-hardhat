# 升级版合约部署指南

## 新增功能

### 1. 代码复用优化
- 创建了 `ExchangeLib` 共享库，统一管理ETH<->YD代币的兑换逻辑
- 两个合约共享储备池，提高资金利用效率

### 2. AAVE aToken 集成
- 精确计算收益通过 aToken 余额跟踪
- 支持实时APY显示
- 更准确的奖励分发机制

### 3. Uniswap V3 升级
- 支持多个手续费等级 (0.05%, 0.3%, 1%)
- 更优的滑点控制
- 精确的价格引用

### 4. 增强的储备管理
- 自动添加ETH储备功能
- 更好的流动性管理

## 本地测试部署

### 1. 启动本地链
```bash
npx hardhat node
```

### 2. 部署所有合约（包括Mock合约）
```bash
npx hardhat ignition deploy ignition/modules/LocalTestDeploy.ts --network localhost
```

### 3. 为合约添加初始储备
部署脚本会自动为每个合约添加 1 ETH 储备，但你可以手动添加更多：

```bash
# 通过合约调用添加ETH储备
# CourseManagerV2.addETHReserve() - 发送ETH
# StakingSystemV2.addETHReserve() - 发送ETH
```

## 合约地址更新

部署完成后，需要更新前端配置文件中的地址：

1. `CourseManagerV2` 地址
2. `StakingSystemV2` 地址
3. Mock token 地址 (用于测试)

## 主要改进

### CourseManagerV2
- 使用 `ExchangeLib` 进行代币兑换
- 共享储备池管理
- 自动添加储备功能
- 改进的手续费管理

### StakingSystemV2
- AAVE aToken 精确收益计算
- Uniswap V3 集成
- 多层次的滑点保护
- 实时APY显示
- 精确的奖励追踪

### Mock 合约 (仅用于本地测试)
- MockUSDT: 模拟USDT代币
- MockWETH: 模拟WETH代币
- MockAavePool: 模拟AAVE借贷池
- MockUniswapV3Router: 模拟Uniswap V3路由器
- MockAToken: 模拟aUSDT代币

## 测试流程

1. **部署合约**
   ```bash
   npx hardhat ignition deploy ignition/modules/LocalTestDeploy.ts --network localhost
   ```

2. **验证储备**
   - 检查每个合约都有 1 ETH 储备
   - 检查YD代币储备是否充足

3. **测试ETH<->YD兑换**
   - 通过 CourseManagerV2 购买/出售YD代币
   - 验证汇率计算正确

4. **测试质押功能**
   - 质押YD代币到 StakingSystemV2
   - 验证USDT兑换和AAVE供应
   - 测试奖励计算

5. **测试课程购买**
   - 创建测试课程
   - 用YD代币购买课程
   - 验证手续费分配

## 生产环境部署

对于主网或测试网部署，需要：

1. 更新 `StakingSystemV2Module.ts` 中的真实合约地址：
   - USDT合约地址
   - WETH合约地址  
   - Uniswap V3 Router地址
   - AAVE Pool Provider地址
   - AAVE Data Provider地址

2. 设置正确的网络参数：
   ```bash
   npx hardhat ignition deploy ignition/modules/StakingSystemV2.ts --network sepolia --parameters '{"isLocalhost": false, ...}'
   ```

3. 验证合约：
   ```bash
   npx hardhat verify --network sepolia <contract-address> <constructor-args>
   ```

## 安全注意事项

1. **权限管理**: 只有owner可以添加储备和提取费用
2. **滑点保护**: 所有DEX交换都有滑点保护
3. **重入保护**: 所有关键函数都有重入保护
4. **暂停机制**: StakingSystemV2支持紧急暂停
5. **储备监控**: 储备不足时会阻止交换

## 升级路径

从旧版本升级：
1. 部署新版本合约
2. 将储备从旧合约迁移到新合约
3. 更新前端配置
4. 通知用户新合约地址