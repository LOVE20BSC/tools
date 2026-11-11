# LOVE20BSC Tools

独立工具合约集合：不依赖 LOVE20 协议合约、功能单一的通用工具。每个工具只做一件事，不持有协议状态，不参与治理。

迁移方式：每个合约先以固定旧提交建立原始快照，再按小步提交改造成 BSC 版本。首批成员 `BatchTransfer` 来自 `LOVE20TKM/batch-transfer`（旧代码基线 `5bc194c`）。

## 依赖

| 子模块 | 用途 |
| --- | --- |
| `lib/forge-std` | 测试与脚本 |

本仓**不声明任何协议子模块**：工具合约按定义不依赖 `core` / `action` / `group-chat` / `dex`，需要的标准接口（如 ERC20 的最小读法）在实现文件内联，避免为一个函数引入整条依赖链。`remappings.txt` 因此只有 `@forge-std/` 一条。

依赖版本固定在同一提交的 `.gitmodules` + `foundry.lock`；规则见 [合约开发规范](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/dev-standards.md) §3.2。

## 当前状态

- 仓库骨架与工具链已建立，编译基线为 Solidity `0.8.37`、Foundry `1.8.1`、`evm_version = "osaka"`，不使用 `via_ir`。
- `BatchTransfer` 已完成旧代码基线、改基线、单元测试三个提交，23 个用例全通过，运行时字节码 3,474 字节（EIP-170 上限 24,576）。部署脚本与部署回归测试属阶段 3，尚未落地，因此 CI 的第 5 步（`test/deploy_scripts_test.py`）暂时注释掉。
- 后续成员 `UniswapV2Zap` 尚未开始。

## 构建与测试

```sh
git submodule update --init --recursive
forge build --force --deny warnings
forge build --sizes
forge lint
forge test
```

## 合约

### BatchTransfer

**做什么**。一个无状态的批量转账与批量查询工具，四个入口：

- `batchTransferNative(address[] recipients, uint256[] amounts)` —— 按 `amounts` 逐笔转原生币，要求 `msg.value` 等于 `amounts` 之和；每笔固定转发 `NATIVE_TRANSFER_GAS_LIMIT`（50,000）gas，避免单个收款方吞掉整笔预算。
- `batchTransferERC20(address token, address[] recipients, uint256[] amounts)` —— 先校验 `token` 有代码，再一次性核对发送方余额与对本合约的授权额度，通过后才逐笔 `transferFrom`。
- `nativeBalances(address[] accounts)` / `erc20Balances(address token, address[] accounts)` —— 批量读余额，同样先校验 `token` 有代码。

批量要么全成、要么全回滚：任何一笔失败都会 revert 整笔交易，并带上失败元素的下标（`NativeTransferFailed`、`ERC20TransferFailed`、`ERC20InvalidReturn` 等都带 `index`）。零收款地址与零金额被拒绝，空批次与数组长度不一致被拒绝。ERC20 一侧同时接受标准布尔返回与无返回值的旧式代币，返回数据短于 32 字节视为失败。

**构造函数参数**：无。合约不接收任何构造参数，也没有 `init` 或后续配置入口。

**承诺**：

- **无 owner** —— 没有 owner、admin、operator 或任何特权地址；部署后不存在只有某个地址能调的入口。
- **无升级** —— 不是代理，没有实现槽、没有 `upgradeTo`；部署即终态。
- **无托管** —— 合约不保存任何余额。原生币在同一笔交易内转发完毕（`msg.value` 必须精确等于总额），ERC20 走 `transferFrom` 从发送方直达收款方，合约地址本身不留余额。合约也不持有授权之外的能力：`allowance` 由发送方在每次调用前自行设置，合约不能主动提取。

因此本合约没有"跑路"路径可言：任何调用者能做的事，都只是把自己名下的资产按自己给的清单转出去。

**地址文件**：部署后地址写入 `script/network/<network>/addresses.batch-transfer.params`，键名 `BATCH_TRANSFER_ADDRESS`。该文件由部署脚本写入，`21_check_batch_transfer.sh` 会断言键集合恰好等于期望合约集合。构造参数文件 `script/network/<network>/batch-transfer.params` 存在但只含注释——本合约无构造参数，保留该文件是为了让每个模块在 `script/network/<network>/` 下保持同一形状。
