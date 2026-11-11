# LOVE20BSC Tools

独立工具合约集合：不依赖 LOVE20 协议合约、功能单一的通用工具。每个工具只做一件事，不持有协议状态，不参与治理。

迁移方式：每个合约先以固定旧提交建立原始快照，再按小步提交改造成 BSC 版本。首批成员 `BatchTransfer` 来自 `LOVE20TKM/batch-transfer`（旧代码基线 `5bc194c`）。

## 依赖

| 子模块 | 用途 |
| --- | --- |
| `lib/forge-std` | 测试与脚本 |

本仓**不声明任何协议子模块**：工具合约按定义不依赖 `core` / `action` / `group-chat` / `dex`，需要的标准接口（如 ERC20 的最小读法）在本仓 `src/interfaces/` 内自行声明，避免为一个函数引入整条依赖链。`remappings.txt` 因此只有 `@forge-std/` 一条。

`src/interfaces/` 是本仓自有 ABI 的唯一来源（开发规范 §4.1）：`IBatchTransfer.sol` 声明本合约的函数、事件与错误，`IERC20Minimal.sol` 只是「最小 ERC20 编码接口」——它仅声明 `BatchTransfer` 会编码的 `balanceOf` / `allowance` / `transferFrom` 三个 selector，不是 LOVE20 自有 ABI，也不代表本仓认领 ERC20 标准；放在同一目录只为让本仓所有 ABI 声明只有一个位置。

依赖版本固定在同一提交的 `.gitmodules` + `foundry.lock`；规则见 [合约开发规范](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/dev-standards.md) §3.2。

## 当前状态

- 仓库骨架与工具链已建立，编译基线为 Solidity `0.8.37`、Foundry `1.8.1`、`evm_version = "osaka"`，不使用 `via_ir`。
- `BatchTransfer` 已完成旧代码基线、重命名、BSC 实现、单元测试四个提交，26 个用例全通过（23 个迁移用例 + 3 个部署脚本 `_validateConfig` 用例），运行时字节码 3,474 字节（EIP-170 上限 24,576）。部署脚本、地址参数文件与部署回归测试均已落地，CI 的五个门禁步骤全部启用。部署入口见 [`script/deploy/README.md`](script/deploy/README.md)。
- 后续成员 `UniswapV2Zap` 尚未开始。

## 与旧仓的差异

`BatchTransfer` 迁移自 `LOVE20TKM/batch-transfer@5bc194c`。**这不是纯搬运**：`migration-standards.md` 第二节把「旧代码基线」只当作 diff 起点，第三、四步（BSC 实现、单元测试）才是真正的改造；该文件第三节也写明「不应只因"旧代码如此"就照搬」。因此本仓在迁移的同时按 `error-standards.md` 与 `event-standards.md` 整改了 ABI。

### ABI 变更清单

旧仓 ABI 的 `abi` 字段（排序键 JSON）sha256 为 `6f03a9bc333ff959cd37b30c0381a6c0d520d31b4e6182641c7d3ab218e87a9a`，本仓为 `7051f241837d43b661280934a73c7f2f7ea1df01c7f22cb43feb618000abad15`。**两者不同**，逐项如下。

**函数：5 个，全部未变**（选择器一致）。

**事件：2 个，全部改名**（topic0 随之改变）。

| 旧仓 | 本仓 |
| --- | --- |
| `NativeBatchTransfer(address,uint256,uint256)` | `NativeBatchTransferred(address,uint256,uint256)` |
| `ERC20BatchTransfer(address,address,uint256,uint256)` | `ERC20BatchTransferred(address,address,uint256,uint256)` |

依据：`dev-standards.md` §5.1 要求事件名用过去式。字段名 `token` 同时改为 `tokenAddress`（`event-standards.md` §6.4），只改字段名不改变类型序列，对 topic0 无额外影响。

**错误：13 个，其中 7 个未变、6 个改变。**

未变：`EmptyBatch()`、`ArrayLengthMismatch(uint256,uint256)`、`ZeroRecipient(uint256)`、`ZeroAmount(uint256)`、`NativeValueMismatch(uint256,uint256)`、`ERC20InsufficientBalance(address,address,uint256,uint256)`、`ERC20InsufficientAllowance(address,address,address,uint256,uint256)`。

改变：

| 旧仓 | 本仓 | 依据 |
| --- | --- | --- |
| `NativeTransferFailed(uint256,address,uint256,bytes)` | `NativeTransferFailed(uint256,address,uint256,bytes32,uint256)` | `error-standards.md` §4：只允许定长标量、地址、枚举、`bytes32`，禁止字符串与动态数组 |
| `ERC20BalanceQueryFailed(address,address,bytes)` | `ERC20BalanceQueryFailed(address,address,bytes32,uint256)` | 同上 |
| `ERC20AllowanceQueryFailed(address,address,address,bytes)` | `ERC20AllowanceQueryFailed(address,address,address,bytes32,uint256)` | 同上 |
| `ERC20TransferFailed(address,uint256,address,uint256,bytes)` | `ERC20TransferFailed(address,uint256,address,uint256,bytes32,uint256)` | 同上 |
| `ERC20InvalidReturn(address,uint256,address,uint256,bytes)` | `ERC20InvalidReturn(address,uint256,address,uint256,bytes32,uint256)` | 同上 |
| `InvalidToken(address)` | `TokenNotContract(address)` | `error-standards.md` §3：`Invalid*` 只用于值本身非法，不用于零值或不存在；依赖无代码用 `*NotContract` |

原 `bytes` 载荷改为 `bytes32` 哈希 + `uint256` 长度（`error-standards.md` 第七节给出的有界形态），排障时仍可按内容哈希核对，但 revert data 长度不再随外部返回数据膨胀。

### 逻辑语义未变的依据

ABI 变了，所以不能再用「ABI 一致」证明行为未变。现在的依据是：**23 个迁移测试用例原样保留、断言强度未降、全部通过**（另有 3 个部署脚本用例）。测试逐条覆盖了旧仓的每个入口、每条 revert 路径与每个边界，因此签名变更是改名与载荷形态变化，不是行为变化。

## 编译基线差异

本仓的编译基线是 Solidity `0.8.37`、`evm_version = "osaka"`、`cbor_metadata = false`。旧仓基线是 Solidity `0.8.17`，`foundry.toml` 未设置 `evm_version`，`cbor_metadata` 则本来就写了 `false`。

| 项目 | 旧仓 `batch-transfer@5bc194c` | 本仓 |
| --- | --- | --- |
| `solc_version` | `0.8.17` | `0.8.37` |
| `evm_version` | 未设置，Foundry 对 0.8.17 解析为 `london`（无 `PUSH0`） | `osaka`（启用 `PUSH0`） |
| `cbor_metadata` | `false`，但对 0.8.17 是空操作（见下） | `false`（真正剥离 metadata 尾） |
| runtime 字节码 | 3,678 字节（末尾含 12 字节 metadata 尾） | 3,474 字节（无 metadata 尾） |
| 去掉 metadata 尾后的 runtime | 3,666 字节 | 3,474 字节（本来就无尾） |

实测口径：旧仓 runtime 的末 12 字节是 `a164736f6c6343000811000a`，按 CBOR 解码为 `{"solc": "0.8.17"}` 的 compact 编码，结构是 `a1`（1 项 map）+ `64`（4 字节文本）+ `"solc"` + `43`（3 字节 byte string）+ `000811`（= 0.8.17）+ `000a`（其后 10 字节 metadata）；共 **12 字节**。3,678 − 12 = 3,666。本仓 runtime 末尾没有这段，直接就是 3,474。

两个总量相差 204 字节（3,678 − 3,474）；把 metadata 尾按长度扣掉后，剩下的 192 字节（3,666 → 3,474）才是代码生成本身的差异，来源有两处：

- **`evm_version`（116 字节）**：`osaka` 启用 `PUSH0`，`london` 不产出该指令。这一项可单独测：把本仓 `evm_version` 临时改回 `london` 重编译，runtime 为 3,590 字节，3,590 − 3,474 = 116。
- **编译器版本（76 字节）**：`0.8.17` 与 `0.8.37` 的代码生成不同，同样的源码编译结果本身就有出入。3,666 − 3,590 = 76。

116 + 76 = 192，因此这个分解是自洽的：204（总量差）= 12（metadata 尾）+ 116（evm_version）+ 76（编译器版本）。

**注意不要把这 12 字节当成"剥 metadata 的收益"**：这里的 12 是旧仓产物末尾那段的实际长度，不是"本仓剥离 metadata 让字节码少了 12 字节"。旧仓之所以留着这段，是因为 solc `0.8.17` 不支持 `appendCBOR` 设置（该选项 `0.8.18` 才加入），Foundry 传不下去，`cbor_metadata = false` 对它是空操作；而剥离 metadata 后 solc 会重新布局代码，差值未必正好等于尾段长度，所以本仓只陈述实测值，不推断"关掉 metadata 省了多少"。

注：旧仓 `evm_version` 未设置时，Foundry 对 `0.8.17` 解析为 `london` 而非 `paris`——`paris` 这个 EVM 版本要到 solc `0.8.18` 才支持，`0.8.17` 指定它会直接编译报错。`london` 与 `paris` 都不产出 `PUSH0`，所以"旧仓没有 `PUSH0`"这个结论不变。

上面这组字节数只用于说明**编译基线**带来的差异。由于本仓同时整改了 ABI（见上一节），两仓 runtime 字节码本来就不该一致——核对行为时以测试为准，不要直接比对字节码。

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

`foundry.toml` 的 `[lint]` 一节里，`exclude_lints` 目前保留 `calls-loop`、`reentrancy-events`、`unused-return` 三类，逐条理由写在该文件注释里、且都针对本合约（批量工具对一批地址逐个外部调用、无状态所以事件重排无法伪造可信状态、部分 tuple 返回值有意忽略），不是从其他仓照抄的治理合约语境。`arbitrary-send-eth` 与 `return-bomb` **不在**全局列表里：它们在原生币转发那一行用 `forge-lint: disable-next-line` 精确抑制。

这三类限制并非 Foundry 能力所限——实测在 Foundry `1.8.1` 下把它们改成行内抑制（`calls-loop` 与 `reentrancy-events` 用 `disable-next-item`，位置分别放在多行赋值语句与 `emit` 之前）后，`exclude_lints = []` 也能让 `forge lint` 零告警通过。当前选择全局禁用而非逐行抑制，是为避免 5 处分散的抑制注释；若日后要求收紧，改动方式是机械的，见 `foundry.toml` 注释。

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
