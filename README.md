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
- `BatchTransfer` 已完成旧代码基线、改基线、单元测试三个提交，23 个用例全通过，运行时字节码 3,474 字节（EIP-170 上限 24,576）。部署脚本、地址参数文件与部署回归测试均已落地，CI 的五个门禁步骤全部启用。部署入口见 [`script/deploy/README.md`](script/deploy/README.md)。
- 后续成员 `UniswapV2Zap` 尚未开始。

## 编译基线差异

本仓的编译基线是 Solidity `0.8.37`、`evm_version = "osaka"`、`cbor_metadata = false`。`BatchTransfer` 迁移自 `LOVE20TKM/batch-transfer@5bc194c`，旧仓基线是 Solidity `0.8.17`，`foundry.toml` 未设置 `evm_version`，`cbor_metadata` 则本来就写了 `false`。

| 项目 | 旧仓 `batch-transfer@5bc194c` | 本仓 |
| --- | --- | --- |
| `solc_version` | `0.8.17` | `0.8.37` |
| `evm_version` | 未设置，Foundry 对 0.8.17 解析为 `london`（无 `PUSH0`） | `osaka`（启用 `PUSH0`） |
| `cbor_metadata` | `false`，但对 0.8.17 是空操作（见下） | `false`（真正剥离 metadata 尾） |
| ABI（排序键 JSON）sha256 | `6f03a9bc333ff959cd37b30c0381a6c0d520d31b4e6182641c7d3ab218e87a9a` | 同一值 |
| runtime 字节码 | 3,678 字节 | 3,474 字节 |

所以同一个合约源码在两仓编译出来：**ABI 逐字节相同**，**运行时字节码不同**（3,678 → 3,474，少 204 字节）。差异有三处来源，都不是逻辑变更：

- **`evm_version`（约 116 字节）**：`osaka` 启用 `PUSH0`，`london` 不产出该指令。字节码开头 `61004a` 与 `610049` + `5f` 的差别即由此而来。
- **编译器版本（约 75 字节）**：`0.8.17` 与 `0.8.37` 的代码生成不同，同样的源码编译结果本身就有出入。
- **metadata（13 字节）**：本仓 `cbor_metadata = false` 真正剥离了 solc 写在字节码末尾的 metadata。旧仓虽然也写了 `cbor_metadata = false`，但 solc `0.8.17` 不支持 `appendCBOR` 设置（该选项 `0.8.18` 才加入），Foundry 传不下去，所以旧仓产物末尾仍有 `...fea164736f6c6343000811000a`。

注：旧仓 `evm_version` 未设置时，Foundry 对 `0.8.17` 解析为 `london` 而非 `paris`——`paris` 这个 EVM 版本要到 solc `0.8.18` 才支持，`0.8.17` 指定它会直接编译报错。`london` 与 `paris` 都不产出 `PUSH0`，所以"旧仓没有 `PUSH0`"这个结论不变。

结论：迁移前后**没有逻辑变更**，依据是 ABI 完全一致、23 个测试原样全过。这一节的作用是让未来的审计者与集成方知道：这份字节码差异是预期的编译基线差异，不是篡改——核对时以 ABI 与测试为准，不要直接比对字节码。

## 构建与测试

```sh
git submodule update --init --recursive
forge build --force --deny warnings
forge build --sizes
forge lint
forge test
python3 test/deploy_scripts_test.py
```

部署脚本的回归测试 `test/deploy_scripts_test.py` 不联网、不广播：它在临时工程根里放假的 `cast` / `forge` / `osascript`，覆盖参数文件载入、地址文件键集合与原子替换、keystore 密码经 600 临时文件传递、校验失败回滚等路径。

部署（先起本地链并配好 `script/network/<network>/.account`）：

```sh
./script/deploy/one_click_deploy_batch_transfer.sh anvil31337_dev   # 一键：部署 → 校验 → 验证
./script/deploy/11_deploy_batch_transfer.sh anvil31337_dev          # 分步：仅部署
./script/deploy/21_check_batch_transfer.sh anvil31337_dev           # 分步：仅校验
./script/deploy/31_verify_batch_transfer.sh anvil31337_dev          # 分步：仅开源验证
```

目录与新增网络的约定见 [`script/deploy/README.md`](script/deploy/README.md)。

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
