# LOVE20BSC Tools

只放**不依赖其他已部署合约、功能单一**的纯工具：每个工具只做一件事，不持有协议状态，不参与治理，不需要任何别的仓库先部署好。

判据是编译期事实（是否 `import` 其他仓库的接口 / 地址文件），不是人的判断。需要依赖协议已部署合约、或需要持续演进的便捷入口（组 LP、单币质押、报价聚合），属于 `periphery`，不进本仓。

当前只有一个工具：`BatchTransfer`，迁移自 `LOVE20TKM/batch-transfer`（旧代码基线 `5bc194c`）。

## 依赖

| 子模块 | 用途 |
| --- | --- |
| `lib/forge-std` | 测试与脚本 |

本仓**只声明 `lib/forge-std` 一个子模块**，也**不声明任何协议子模块**：工具合约按定义不依赖 `core` / `action` / `group-chat` / `dex`，需要的标准接口在本仓 `src/interfaces/` 内自行声明，避免为一个函数引入整条依赖链。`remappings.txt` 因此只有 `@forge-std/` 一条；`foundry.toml` 里 `auto_detect_remappings = false`，任何未声明的重映射都会在编译期失败。

`src/interfaces/` 是本仓自有 ABI 的唯一来源（开发规范 §4.1）：`IBatchTransfer.sol` 声明合约的函数、事件与错误，`IERC20Minimal.sol` 是最小外部调用面——只声明 `BatchTransfer` 会编码的三个 ERC20 selector，不是 LOVE20 自有 ABI，也不代表本仓认领 ERC20 标准；放在同一目录只为让本仓所有 ABI 声明只有一个位置。它不引入 OpenZeppelin 依赖。

依赖版本固定在同一提交的 `.gitmodules` + `foundry.lock`；规则见 [合约开发规范](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/dev-standards.md) §3.2。`test/deploy_scripts_test.py` 会断言 `.gitmodules`、`foundry.lock` 与 `remappings.txt` 三者之间没有声明了却不用的依赖。

## 当前状态

- 仓库骨架与工具链已建立，编译基线为 Solidity `0.8.37`、Foundry `1.8.1`、`evm_version = "osaka"`，不使用 `via_ir`。
- `BatchTransfer` 已完成旧代码基线、重命名、BSC 实现、单元测试四个提交，之后追加一个规范整改提交。30 个用例全通过（27 个合约用例 + 3 个部署脚本 `_validateConfig` 用例），运行时字节码 3,532 字节（EIP-170 上限 24,576）。部署脚本、地址参数文件与部署回归测试均已落地，CI 的五个门禁步骤全部启用。部署入口见 [`script/deploy/README.md`](script/deploy/README.md)。

## 与旧仓的差异

`BatchTransfer` 迁移自 `LOVE20TKM/batch-transfer@5bc194c`。**这不是纯搬运**：`migration-standards.md` 第二节把「旧代码基线」只当作 diff 起点，第三、四步（BSC 实现、单元测试）才是真正的改造；该文件第三节也写明「不应只因"旧代码如此"就照搬」。因此在迁移的同时按 `error-standards.md` 与 `event-standards.md` 整改了 ABI，并在评审后按使用方的反馈改了几处行为。

本节不登记 ABI 哈希：哈希每次改名都会变，钉在文档里只会变成过期数字（它已经过期过两次）。需要精确对账时现场比：

```sh
forge inspect BatchTransfer abi --json     # 本仓
git -C ../LOVE20TKM/batch-transfer show 5bc194c:out/BatchTransfer.sol/BatchTransfer.json   # 旧仓
```

### BatchTransfer 的变更

**函数：两个入口都新增了 `uint256 gasLimit`，并删除了常量 `NATIVE_TRANSFER_GAS_LIMIT()`。**

| 旧仓 | 本仓 | 原因 |
| --- | --- | --- |
| `batchTransferNative(address[],uint256[])` | `batchTransferNative(address[],uint256[],uint256)` | 每笔转发的 gas 预算从写死的常量改为调用方入参：常量对多签、带 hook 的收款合约过窄，它们需要远超 50,000 gas，而由调用方给值时付 gas 的一方也能自己权衡 |
| `batchTransferERC20(address,address[],uint256[])` | `batchTransferERC20(address,address[],uint256[],uint256)` | 同上，约束的是每笔 `transferFrom` |
| `NATIVE_TRANSFER_GAS_LIMIT()`（getter） | 删除 | 常量已不存在；`gasLimit == 0` 改由新错误 `ZeroGasLimit()` 拒绝 |

函数选择器因此全部改变，集成方必须按新签名调用。

**事件：2 个，全部改名**（topic0 随之改变）。

| 旧仓 | 本仓 |
| --- | --- |
| `NativeBatchTransfer(address,uint256,uint256)` | `NativeBatchTransferred(address,uint256,uint256)` |
| `ERC20BatchTransfer(address,address,uint256,uint256)` | `ERC20BatchTransferred(address,address,uint256,uint256)` |

依据：`dev-standards.md` §5.1 要求事件名用过去式。字段名 `token` 同时改为 `tokenAddress`（`event-standards.md` §6.4），只改字段名不改变类型序列，对 topic0 无额外影响。

**函数参数名：`token` → `tokenAddress`（2 个入口）。** 参数名不进 selector，但它是 ABI JSON 的 `name` 字段，属于集成方 API（`naming-standards.md` §十：`address` 类型的实体参数带 `Address` 后缀）。`batchTransferERC20` 与 `erc20Balances` 的入参同步改名——改的是参数名，不是函数名。

**错误：13 → 14 个。** 未变（选择器与旧仓相同）：`EmptyBatch()`、`ArrayLengthMismatch(uint256,uint256)`、`ZeroRecipient(uint256)`、`ZeroAmount(uint256)`、`NativeValueMismatch(uint256,uint256)`。新增 `ZeroGasLimit()`。其余 8 个改变：

| 旧仓 | 本仓 | 依据 |
| --- | --- | --- |
| `NativeTransferFailed(uint256,address,uint256,bytes)` | `NativeTransferFailed(uint256,address,uint256,bytes32,uint256)` | `error-standards.md` §4：只允许定长标量、地址、枚举、`bytes32`，禁止字符串与动态数组 |
| `ERC20BalanceQueryFailed(address,address,bytes)` | `ERC20BalanceQueryFailed(address,address,bytes32,uint256)` | 同上 |
| `ERC20AllowanceQueryFailed(address,address,address,bytes)` | `ERC20AllowanceQueryFailed(address,address,address,bytes32,uint256)` | 同上 |
| `ERC20TransferFailed(address,uint256,address,uint256,bytes)` | `ERC20TransferFailed(address,uint256,address,uint256,bytes32,uint256)` | 同上 |
| `ERC20InvalidReturn(address,uint256,address,uint256,bytes)` | `ERC20InvalidReturn(address,uint256,address,uint256,bytes32,uint256)` | 同上 |
| `InvalidToken(address)` | `TokenNotContract(address)` | `error-standards.md` §3：`Invalid*` 只用于值本身非法，不用于零值或不存在；依赖无代码用 `*NotContract` |
| `ERC20InsufficientBalance(address,address,uint256,uint256)`（参数 `balance, required`） | `ERC20InsufficientBalance(address,address,uint256,uint256)`（参数 `required, available`） | `error-standards.md` §4：额度类载荷顺序为 `required + available`；选择器不变，只有 ABI JSON 的参数名变 |
| `ERC20InsufficientAllowance(address,address,address,uint256,uint256)`（参数 `allowanceAmount, required`） | `ERC20InsufficientAllowance(address,address,address,uint256,uint256)`（参数 `required, available`） | 同上 |

这两个名字与 OpenZeppelin `IERC20Errors` 的标准错误**同名但选择器不同**（本合约 `0xac083e30` / `0x9cb4340e`，OZ 标准 `0xe450d38c` / `0xfb8f41b2`）：本合约是它们的产生者而不是透传者，本地声明合规；链下按 selector 识别即可，不要按错误名识别。

原 `bytes` 载荷改为 `bytes32` 哈希 + `uint256` 长度（`error-standards.md` 第七节给出的有界形态），排障时仍可按内容哈希核对，但 revert data 长度不再随外部返回数据膨胀。

### 逻辑语义未变的依据

ABI 变了，所以不能再用「ABI 一致」证明行为未变。现在的依据是**迁移时的 23 个用例逐条保留、断言强度未降、全部通过**，加上整改与评审后新增的用例（合计 27 个合约用例 + 3 个部署脚本用例），另有 24 项部署脚本回归。

按变更性质分三类：

- **纯格式**（不影响 ABI 语义）：`emit` 改具名参数形式；多参数 `error` 声明拆行；`IERC20Minimal` 从实现文件抽到 `src/interfaces/`。
- **签名变更**（改变 ABI，不改变行为）：错误载荷与控制流不变的重命名、事件改名、字段与参数改名。
- **行为变更**（本轮评审后新增，明确记录）：`gasLimit` 从常量变入参。这一项有对应测试，且已在上表列明。

**断言强度为什么没降**：原来断言 revert data 里的完整 `bytes`，现在断言同一段数据的 `keccak256` 与长度——内容仍被锁住（哈希碰撞在这些固定短输入上不是现实风险），且**新增**了原来没有的长度断言。事件侧 `expectEmit` 的 topic 与 data 比对保持不变。

## 编译基线

本仓的编译基线是 Solidity `0.8.37`、`evm_version = "osaka"`、`cbor_metadata = false`。旧仓 `batch-transfer@5bc194c` 是 Solidity `0.8.17`，`foundry.toml` 未设 `evm_version`。

三点与本仓不同，都不改变逻辑：

- **`evm_version`**：旧仓未设，Foundry 对 `0.8.17` 解析为 `london` 而非 `paris`（`paris` 要到 solc `0.8.18` 才支持，指定即报错）。`london` 不产出 `PUSH0`，`osaka` 产出，因此字节码不同。
- **编译器版本**：`0.8.17` 与 `0.8.37` 的代码生成本身就有差异。
- **metadata 尾**：旧仓 `foundry.toml` 也写了 `cbor_metadata = false`，但对 `0.8.17` 是**空操作**——`appendCBOR` 是 solc `0.8.18` 才加入的设置，Foundry 传不下去，所以旧仓 runtime 末尾仍有 12 字节的 `a164736f6c6343000811000a`（CBOR 编码的 `{"solc":"0.8.17"}`）。本仓的 `false` 真正剥离了这段。

**本节的数字只用于说明编译基线，不能用来判断行为是否一致。** 本仓的 ABI 与旧仓不同（见上一节），源码也不同，runtime 字节码本来就不该相等；行为是否未变的依据是迁移测试逐条保留并通过（见上一节）。需要具体数值时现场比：

```sh
forge build --sizes                              # 本仓各合约 runtime / initcode
forge inspect BatchTransfer deployedBytecode     # 本仓 runtime 字节码
git -C ../LOVE20TKM/batch-transfer show 5bc194c:out/BatchTransfer.sol/BatchTransfer.json
```

**目标链的指令集**：`evm_version = "osaka"` 让合约用上 `PUSH0`（Shanghai）与 `MCOPY`（Cancun）。BSC 主网（chain 56）已分别于 **2024-01-23** 与 **2024-06-20** 激活 Shanghai 与 Cancun，并于 **2026-04-28** 激活 Osaka；Chapel 测试网（97）更早（2023-12-19 / 2024-04-17 / 2026-03-24）。依据是 BSC 客户端自带的链配置 `bnb-chain/bsc/params/config.go` 中的 `BSCChainConfig` / `ChapelChainConfig`。实测：把链跑在 `paris` 上，本合约连部署都会失败（`EVM error NotActivated`），所以这个依赖是硬的；BSC 三个分叉均已就绪。

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

### `[lint]` 配置

`foundry.toml` 的 `[lint]` 一节按 `forge lint` 实测结果配置，理由逐条写在文件注释里、且只针对 `BatchTransfer`：

- `ignore = ["test/**/*.sol"]` —— 测试 mock 故意做真实合约不该做的事（持有原生币不转出、无事件改 allowance、截断类型、忽略返回值），实测清空后报 43 条告警，全部落在 test 目录。
- `exclude_lints = ["calls-loop", "reentrancy-events"]` —— 批量工具对一批地址逐个外部调用就是它的定义行为；事件在函数末尾一次性发出，无状态合约重入无法伪造可信状态。实测这两类在 `src/BatchTransfer.sol` 上命中 3 + 2 条。
- `arbitrary-send-eth` / `return-bomb` / `require-revert-in-loop` **不在**全局列表里：它们在源码里用 `forge-lint: disable-next-line` 逐行精确抑制（原生币转发 1 处、保留完整返回数据 2 处、逐笔失败带下标 6 处）。全局禁用会连未来新增的无关调用一起放过。

这三类全局限制并非 Foundry 能力所限——实测在 Foundry `1.8.1` 下把它们改成行内抑制（`calls-loop` 与 `reentrancy-events` 用 `disable-next-item`，位置分别放在多行赋值语句与 `emit` 之前）后，`exclude_lints = []` 也能让 `forge lint` 零告警通过。当前选择全局禁用而非逐行抑制，是为避免 5 处分散的抑制注释；若日后要求收紧，改动方式是机械的。

## 部署

（先起本地链并配好 `script/network/<network>/.account`）

```sh
./script/deploy/one_click_deploy_batch_transfer.sh anvil31337_dev   # 一键：部署 → 校验 → 验证
./script/deploy/11_deploy_batch_transfer.sh anvil31337_dev          # 分步：仅部署
./script/deploy/21_check_batch_transfer.sh anvil31337_dev           # 分步：仅校验
./script/deploy/31_verify_batch_transfer.sh anvil31337_dev          # 分步：仅开源验证
```

本仓**不设全仓统一的 `one_click_deploy.sh`**：工具彼此独立，一个部署失败不该阻塞另一个；每个工具一个入口（`one_click_deploy_<tool>.sh`），按需执行。目录与新增网络的约定见 [`script/deploy/README.md`](script/deploy/README.md)。

## 端到端检查

```sh
script/e2e/anvil_e2e.sh          # 起链 → 部署本仓工具 → 实调 → 还原
```

在一个一次性 anvil 链上从空链开始，跑 `one_click_deploy_batch_transfer.sh`，然后真的转账（原生币与 ERC20 两条路径），最后核对合约零残留与两个自定义错误的 selector。它验证的是 `script/deploy/` 这条路径本身，包括单元测试覆盖不到的字节码与真实 ERC20 行为；退出时无论成败都还原地址文件，工作树不会被弄脏。前置条件与取舍见 [`script/e2e/README.md`](script/e2e/README.md)。

## 事件设计：为什么是汇总而非逐笔

`event-standards.md` 有一条「不得用一条汇总事件替代 N 条事实」。**这条规则不适用于本合约**，理由如下，记在这里以免以后被当成疏漏整改：

- 该规则的语境是「批量操作改变协议状态」，要求每条状态迁移都能从事件重建（`event-standards.md` §3.3、§3.4）。`BatchTransfer` **无状态**，不改变任何协议对象，只搬运资产。
- 资产变动本身已被完整记录：ERC20 一侧每笔都有代币合约的 `Transfer` 事件，原生币一侧每笔都是可从交易回执追到的内部调用。本合约再逐笔发一遍是**同一事实由多条日志重复表达**，违反 `event-standards.md` §3.1 的反向要求。
- 本合约的事件只补充 ERC20 `Transfer` 给不出的信息：**这批是谁发起的、总额多少、涉及几个收款方**。它是补充，不是替代。

代价也不小：本仓实测 200 笔原生币批次，汇总事件相对不发事件多 **1,708 gas**，逐笔事件多 **354,203 gas**——逐笔比汇总多 **352,495 gas**，约 **1,762 gas/笔**。（测量方式：同一份源码编译出三个变体，`batchTransferNative` 分别不发事件、发一条汇总、在循环里逐笔发，用 `gasleft()` 差值比较；三个变体的外部调用与转账完全相同。）

## 合约

### BatchTransfer

**做什么**。一个无状态的批量转账与批量查询工具，四个入口：

- `batchTransferNative(address[] recipients, uint256[] amounts, uint256 gasLimit)` —— 按 `amounts` 逐笔转原生币，要求 `msg.value` 等于 `amounts` 之和；每笔转发请求 `gasLimit` gas（实际是 `min(gasLimit, 剩余 gas 的 63/64)`；带 `value` 的调用另有 2,300 gas stipend）。`gasLimit` 由调用方决定而不是写死：常量对多签、带 hook 的收款合约过窄（它们需要远超 50,000），而由调用方给值时付 gas 的一方也能自己权衡批量大小。EIP-150 仍会把实际转发量压到剩余 gas 的 63/64；带 `value` 的调用另有 2,300 gas stipend。`gasLimit == 0` 被拒绝（`ZeroGasLimit`）。
- `batchTransferERC20(address tokenAddress, address[] recipients, uint256[] amounts, uint256 gasLimit)` —— 先校验 `tokenAddress` 有代码，再一次性核对发送方余额与对本合约的授权额度，通过后才逐笔 `transferFrom`，每笔 `transferFrom` 受 `gasLimit` 约束。
- `nativeBalances(address[] accounts)` / `erc20Balances(address tokenAddress, address[] accounts)` —— 批量读余额，同样先校验 `tokenAddress` 有代码。

批量要么全成、要么全回滚：任何一笔失败都会 revert 整笔交易，并带上失败元素的下标（`NativeTransferFailed`、`ERC20TransferFailed`、`ERC20InvalidReturn` 等都带 `index`）。零收款地址与零金额被拒绝，空批次与数组长度不一致被拒绝。ERC20 一侧同时接受标准布尔返回与无返回值的旧式代币：返回 0 字节视为成功（兼容不给返回值的旧币），返回 1～31 字节视为失败，返回 ≥32 字节时只认解码结果为 `1`（源码 `_isSuccessfulERC20Return`）。

**构造函数参数**：无。合约不接收任何构造参数，也没有 `init` 或后续配置入口。

**承诺**：

- **无 owner** —— 没有 owner、admin、operator 或任何特权地址；部署后不存在只有某个地址能调的入口。
- **无升级** —— 不是代理，没有实现槽、没有 `upgradeTo`；部署即终态。
- **无托管** —— 合约**自己不接收任何资产**：原生币在同一笔交易内转发完毕（`msg.value` 必须精确等于总额），ERC20 走 `transferFrom` 从发送方直达收款方。合约也不持有授权之外的能力：`allowance` 由发送方在每次调用前自行设置。

  但「合约地址上永远不会有余额」是个过强的说法，准确说法是「本合约没有收取资产的功能」：任何人都可以用 `selfdestruct` 强制向它转入原生币，任何 ERC20 也可以把余额记到它名下。区别在于**这些资产没有提取入口**——合约没有 `receive`、没有 `sweep`、没有任何转出余额的路径，所以它们会永久留在该地址。这不是安全问题（转入者自己损失），但不要在文档或集成侧假设该地址的余额恒为零。

因此本合约没有「跑路」路径可言：任何调用者能做的事，都只是把自己名下的资产按自己给的清单转出去。

**地址文件**：部署后地址写入 `script/network/<network>/addresses.batch-transfer.params`，键名 `BATCH_TRANSFER_ADDRESS`。该文件由部署脚本写入，`21_check_batch_transfer.sh` 会断言键集合恰好等于期望合约集合，并把部署字节码与本地构建产物逐字节比对。构造参数文件 `script/network/<network>/batch-transfer.params` 存在但只含注释——本合约无构造参数，保留该文件是为了让每个模块在 `script/network/<network>/` 下保持同一形状。

## 已知限制

写在这里是为了让集成方按正确的方式使用，而不是靠读源码自己发现。

- **只支持标准 ERC20。** fee-on-transfer（转账扣费）与 rebasing（余额自动缩放）代币不支持：合约按 `amounts` 逐笔 `transferFrom`，不做到账量校验。标准 ERC20 下花费恒不超过授权量。
- **`gasLimit` 是调用方的责任。** 给得太低会让整批回滚（有意如此：一笔失败即整批回滚），给得太高则失去「单个收款方吞掉预算」的保护。EIP-150 仍会把实际转发量压到剩余 gas 的 63/64。
- **批量大小没有上限。** 这是调用方付 gas 的设计，不是遗漏；但 batch 越大，单笔交易越可能触及区块 gas 上限。
- **强制转入的资产无法取回。** 合约没有 `receive`/`sweep`。用 `selfdestruct` 打进的原生币、或被 ERC20 记到合约地址名下的余额，会永久留在那里。转入者自负。
