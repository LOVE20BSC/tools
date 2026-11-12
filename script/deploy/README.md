# BatchTransfer 部署指南

`tools` 是多工具仓，每个工具合约自带一套部署脚本，**不共享**编号：`NN_*_<tool>.sh`。当前有两个工具：

| 工具 | 编号 | 步骤脚本 | 入口 |
| --- | --- | --- | --- |
| `BatchTransfer` | `11` / `21` / `31` | `11_deploy_batch_transfer.sh` / `21_check_batch_transfer.sh` / `31_verify_batch_transfer.sh` | `one_click_deploy_batch_transfer.sh` |
| `UniswapV2Zap` | `12` / `22` / `32` | `12_deploy_uniswap_v2_zap.sh` / `22_check_uniswap_v2_zap.sh` / `32_verify_uniswap_v2_zap.sh` | `one_click_deploy_uniswap_v2_zap.sh` |

编号的第二位是模块序号：`1x` 部署、`2x` 校验、`3x` 验证同属模块 `x`（与 `dex` 的 `11_weth` / `12_uniswapv2` 同一约定）。新增工具取下一个未占用的序号。

## 目录结构

```
script/
├── deploy/
│   ├── one_click_deploy_batch_transfer.sh  # BatchTransfer 一键入口（纯编排，不载入任何环境文件）
│   ├── 11_deploy_batch_transfer.sh         # BatchTransfer 部署（自载入部署输入，原子写入地址）
│   ├── 21_check_batch_transfer.sh          # BatchTransfer 校验（自载入校验文件，只读可重复）
│   ├── 31_verify_batch_transfer.sh         # BatchTransfer 开源验证（自载入网络与地址文件）
│   ├── DeployBatchTransfer.s.sol           # Foundry 部署脚本（部署 + 部署期校验）
│   ├── one_click_deploy_uniswap_v2_zap.sh  # UniswapV2Zap 一键入口（纯编排）
│   ├── 12_deploy_uniswap_v2_zap.sh         # UniswapV2Zap 部署
│   ├── 22_check_uniswap_v2_zap.sh          # UniswapV2Zap 校验
│   ├── 32_verify_uniswap_v2_zap.sh         # UniswapV2Zap 开源验证
│   ├── DeployUniswapV2Zap.s.sol            # Foundry 部署脚本（部署 + 部署期校验）
│   ├── params.sh                           # 参数载入器（与 core/action/group-chat/dex 逐字节相同）
│   └── README.md
└── network/
    ├── verifier.params                     # 开源验证端点与跳过链（所有网络共用一份）
    └── anvil31337_dev/                     # 本地 anvil · dev
        ├── .account                        # 账户信息（敏感，已 gitignore）
        ├── network.params                  # 网络参数：CHAIN_ID、RPC_URL、ETHERSCAN_API_KEY
        ├── batch-transfer.params           # BatchTransfer 参数（无构造参数，文件只含注释）
        ├── addresses.batch-transfer.params # BatchTransfer 地址（键名 BATCH_TRANSFER_ADDRESS）
        ├── uniswap-v2-zap.params           # UniswapV2Zap 参数（无构造参数，文件只含注释）
        ├── addresses.uniswap-v2-zap.params # UniswapV2Zap 地址（键名 UNISWAP_V2_ZAP_ADDRESS）
        └── addresses.uniswapv2.params      # 跨库依赖：从 dex 逐字节复制的 Router/Factory 地址
```

## 每个脚本的职责

| 脚本 | 职责 |
| --- | --- |
| `one_click_deploy_batch_transfer.sh` | 纯编排：解析一次 keystore 密码 → 备份旧地址文件 → 依次跑 `11` / `21` / `31` → 校验失败时回滚地址文件并退出非零。不 source 任何配置文件，也不重复各步骤的校验。 |
| `11_deploy_batch_transfer.sh` | 自载入 `network.params` / `batch-transfer.params` / `.account`，核对链 ID，用 `--password-file`（权限 600 的临时文件）调 `forge script` 广播；从部署日志取 `BATCH_TRANSFER_ADDRESS=`，核对本次运行刷新过 `broadcast/DeployBatchTransfer.s.sol/<chain-id>/run-latest.json`，最后**原子替换**地址文件（同目录临时文件 + `mv`）。 |
| `21_check_batch_transfer.sh` | 独立、只读、可重复：断言地址文件键集合恰好是 `BATCH_TRANSFER_ADDRESS`，核对链 ID，`cast code` 确认有代码，回读 `NATIVE_TRANSFER_GAS_LIMIT()` 必须为 `50000`。地址为空/零地址/格式非法时在逐项链上调用之前就失败。 |
| `31_verify_batch_transfer.sh` | 自载入 `network.params` / `verifier.params` / 地址文件，链 ID 列在 `VERIFY_SKIP_CHAIN_IDS` 时跳过并返回 0，否则用 `ETHERSCAN_VERIFIER_URL` + `ETHERSCAN_API_KEY` 提交 `forge verify-contract`。BatchTransfer 无构造参数，不传 `--constructor-args`。 |
| `DeployBatchTransfer.s.sol` | 部署与部署期校验：`_loadConfig` 只读 `CHAIN_ID`（合约无构造参数），`_validateConfig` 在 `startBroadcast()` 前核对 `block.chainid`，`_validateDeployment` 在 `stopBroadcast()` 后确认有代码且 `NATIVE_TRANSFER_GAS_LIMIT()` 为 50000，最后打印 `BATCH_TRANSFER_ADDRESS=<addr>` 供 `11` 提取。 |
| `one_click_deploy_uniswap_v2_zap.sh` | 纯编排：解析一次 keystore 密码 → 备份旧地址文件 → 依次跑 `12` / `22` / `32` → 校验失败时回滚地址文件并退出非零。不 source 任何配置文件，也不重复各步骤的校验。**不部署 Router**：那是 `dex` 的模块。 |
| `12_deploy_uniswap_v2_zap.sh` | 自载入 `network.params` / `uniswap-v2-zap.params` / `addresses.uniswapv2.params`（跨库依赖）/ `.account`，先断言依赖文件键集合恰为 `FACTORY_ADDRESS` `ROUTER_ADDRESS` 且 Router 非零，再核对链 ID，用 `--password-file` 调 `forge script` 广播；从部署日志取 `UNISWAP_V2_ZAP_ADDRESS=`，核对本次运行刷新过 broadcast 产物，最后**原子替换**地址文件。 |
| `22_check_uniswap_v2_zap.sh` | 独立、只读、可重复：断言两份地址文件的键集合，核对链 ID 与 `cast code`，回读 `ROUTER()` 并与依赖文件对账；`FACTORY()` / `WRAPPED_NATIVE_TOKEN()` 不是拿同一个文件自证，而是**从链上 Router 现算**后再比对——dex 重部署后只换了地址文件却忘了重部署 zap 的情况在这里暴露。 |
| `32_verify_uniswap_v2_zap.sh` | 自载入 `network.params` / `verifier.params` / 两份地址文件；链 ID 在 `VERIFY_SKIP_CHAIN_IDS` 里时跳过，否则用 `cast abi-encode "constructor(address)"<router>` 生成 `--constructor-args` 再提交验证——Zap 只有一个构造参数，不传参数就无法复现部署字节码。 |
| `DeployUniswapV2Zap.s.sol` | `_loadConfig` 读 `CHAIN_ID` 与 `ROUTER_ADDRESS`，并从 Router 派生 `factory()` / `WETH()`（`dev-standards` §5.4：能派生的依赖不重复入参）；`_validateConfig` 在 `startBroadcast()` 前核对链 ID、Router/Factory/WETH 三个地址都有代码；`_validateDeployment` 在 `stopBroadcast()` 后逐项回读三个 getter，最后打印 `UNISWAP_V2_ZAP_ADDRESS=<addr>`。 |

三个步骤脚本统一 `<step>.sh <network>` 一种调用形态，各自载入自己需要的文件，**没有任何文件互相 source**，因此任一一步都可以脱离入口单独执行。

`DeployBatchTransfer.s.sol` 用 `console2.log("BATCH_TRANSFER_ADDRESS=", addr)` 输出地址而不用 `vm.writeFile`：本仓 `foundry.toml` 没有 `fs_permissions` 条目（与 `forge build --deny warnings` / `forge lint` 共用同一份配置），而 §6.3 允许 `.s.sol` 输出 `KEY=VALUE`、由 `11` 原子替换最终文件。

## 一键部署

```bash
cd tools
./script/deploy/one_click_deploy_batch_transfer.sh anvil31337_dev
```

依次调用：

1. `11_deploy_batch_transfer.sh` —— 自载入部署输入并广播部署，原子写入地址
2. `21_check_batch_transfer.sh` —— 自载入校验文件，校验部署结果
3. `31_verify_batch_transfer.sh` —— 自载入地址文件做开源验证；默认执行，只有 `verifier.params` 的 `VERIFY_SKIP_CHAIN_IDS` 列出的链才跳过

链 ID 不一致、部署失败或校验失败都会让入口返回非零，并回滚到上一次已保存的地址（校验失败不覆盖旧地址）。网络名必填，缺参直接报错。

## 分步部署

### BatchTransfer

```bash
# 部署（自载入 network.params / batch-transfer.params / .account）
./script/deploy/11_deploy_batch_transfer.sh anvil31337_dev

# 校验部署结果（自载入 network.params / batch-transfer.params / addresses.batch-transfer.params）
./script/deploy/21_check_batch_transfer.sh anvil31337_dev

# 合约开源验证
./script/deploy/31_verify_batch_transfer.sh anvil31337_dev
```

`21_check_batch_transfer.sh` 在地址文件缺失、地址为空或为非法格式时提示先跑一键部署，不会静默通过。

### UniswapV2Zap

**前置**：先跑完 `dex` 的 WETH 与 UniswapV2 模块，把 `dex/script/network/<network>/addresses.uniswapv2.params` **逐字节复制**到本仓同名网络目录。本仓不部署 Router，缺这份文件时 `12` 与 `22` 都在链上调用之前失败。

```bash
cp ../dex/script/network/anvil31337_dev/addresses.uniswapv2.params \
   script/network/anvil31337_dev/addresses.uniswapv2.params

# 部署（自载入 network.params / uniswap-v2-zap.params / addresses.uniswapv2.params / .account）
./script/deploy/12_deploy_uniswap_v2_zap.sh anvil31337_dev

# 校验部署结果（自载入两份地址文件与 network.params）
./script/deploy/22_check_uniswap_v2_zap.sh anvil31337_dev

# 合约开源验证（自动生成 --constructor-args）
./script/deploy/32_verify_uniswap_v2_zap.sh anvil31337_dev
```

`22_check_uniswap_v2_zap.sh` 在 `UNISWAP_V2_ZAP_ADDRESS=` 为空哨兵时提示先跑一键部署；`addresses.uniswapv2.params` 缺失、键集合不对或 Router 为零地址，同样在链上调用之前失败。

## 部署前准备

### 1. 配置账户

创建 `script/network/<network>/.account`（已 gitignore，且为必需文件）：

```bash
KEYSTORE_ACCOUNT=anvil_account
ACCOUNT_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
KEYSTORE_PASSWORD=anvil
```

本地链与公共网络统一走 keystore 签名，不提供 `--unlocked` 回退。`KEYSTORE_PASSWORD` 非空时部署全程无交互；留空或未配时由 macOS `osascript` 弹窗读取一次。非 macOS 环境没有 `osascript`，必须填写该项，脚本会在缺失时明确报错。密码不进进程参数：`11_deploy_batch_transfer.sh` 写入权限 600 的临时文件并用 `--password-file` 交给 forge，广播结束后删除。

`one_click_deploy_batch_transfer.sh` 入口会**先重置** `KEYSTORE_PASSWORD` 再读 `.account`，因此 `KEYSTORE_PASSWORD=xxx ./script/deploy/one_click_deploy_batch_transfer.sh <net>` 不生效（有意为之，避免复用上次运行的残留密码）；非交互场景请把密码写进 `.account`。

### 2. 配置网络参数

`script/network/<network>/network.params`：

```bash
CHAIN_ID=31337
RPC_URL=http://127.0.0.1:8545

# 开源验证凭据：为空时 31_verify_batch_transfer.sh 直接失败，而不是静默跳过
ETHERSCAN_API_KEY=
```

### 3. 配置本模块参数

`script/network/<network>/batch-transfer.params`：**BatchTransfer 没有构造参数**，该文件只含注释。保留它的原因有两个：每个模块在 `script/network/<network>/` 下保持同一形状；将来若新增参数，不需要新建文件，只要把键显式写进这个文件（键必须显式写出，不靠默认值兜底）。

`script/network/<network>/uniswap-v2-zap.params`：**UniswapV2Zap 的构造参数也不在这里**。它唯一一个构造参数 `router` 来自跨库依赖文件 `addresses.uniswapv2.params`，`factory` 与 `wrappedNativeToken` 由 Router 反查——所以本模块的参数文件同样只含注释，保留原因同上。

#### 跨库依赖地址（UniswapV2Zap → dex）

按 `dev-standards` §6.2，本仓不把 Router 地址抄进自己的配置文件，而是把生产方的文件**原样复制**进网络目录：

```bash
cp ../dex/script/network/<network>/addresses.uniswapv2.params \
   script/network/<network>/addresses.uniswapv2.params
```

- 复制件必须与 `dex` 里的同名文件**逐字节相同**；`test/deploy_scripts_test.py` 直接比对两份文件，改一个字节就失败。
- 不要在复制件里加键、改键名或补注释——`12`/`22`/`32` 都会断言它的键集合恰为 `FACTORY_ADDRESS` `ROUTER_ADDRESS`。
- `dex` 重新部署后重抄这一个文件即可；若要换 Router，还必须重新部署 Zap 并重跑 `22`，因为 `router` 是 immutable。

### 4. 新增网络

新增一个网络只需要新建目录并放齐三个文件，**不改任何脚本**：

```bash
mkdir -p script/network/bsc97_dev
cp script/network/anvil31337_dev/{network.params,batch-transfer.params} script/network/bsc97_dev/
printf 'BATCH_TRANSFER_ADDRESS=\n' > script/network/bsc97_dev/addresses.batch-transfer.params
# 再创建 bsc97_dev/.account（已被 .gitignore）
```

- 目录命名 `<链名><链id>_<部署类型>`，部署类型三选一：`dev`（anvil 与测试网）、`public_test`、`public`（仅主网）。
- 地址文件先写成空哨兵 `BATCH_TRANSFER_ADDRESS=`，由 `11_deploy_batch_transfer.sh` 部署成功后覆盖。空值在 `21` / `31` 里是显式失败，不是"未配置就跳过"。
- 新链若没有区块浏览器，把链 ID 加进 `script/network/verifier.params` 的 `VERIFY_SKIP_CHAIN_IDS`；`56` / `97` 不得出现在该名单，`test/deploy_scripts_test.py` 会拒绝。

## 新增工具的约定

**`tools` 每加一个工具合约，就要加一套 `NN_*_<tool>.sh`**：

| 新增文件 | 说明 |
| --- | --- |
| `script/deploy/1x_deploy_<tool>.sh` | 部署该工具，写 `script/network/<net>/addresses.<tool>.params` |
| `script/deploy/2x_check_<tool>.sh` | 校验该工具，断言自己那份地址文件的键集合 |
| `script/deploy/3x_verify_<tool>.sh` | 开源验证（无浏览器的链靠 `VERIFY_SKIP_CHAIN_IDS` 跳过；有构造参数时必须传 `--constructor-args`） |
| `script/deploy/Deploy<Tool>.s.sol` | Foundry 部署脚本，广播前静态校验、广播后回读校验 |
| `script/deploy/one_click_deploy_<tool>.sh` | 该工具的一键入口 |
| `script/network/<net>/<tool>.params` | 该工具的构造参数（无参数也要保留文件并显式写注释说明） |
| `script/network/<net>/addresses.<tool>.params` | 该工具已部署地址，键名 `<TOOL>_ADDRESS`（UPPER_SNAKE_CASE，以 `_ADDRESS` 结尾） |

约束：

- **不设覆盖全仓的 `one_click_deploy.sh`**：`tools` 里的工具彼此独立，一个工具部署失败不该阻塞另一个；每个工具一个入口，按需执行。
- **工具之间不互相调用入口脚本**。工具 A 需要工具 B 的已部署地址时，把 `B/script/network/<net>/addresses.<b>.params` 复制到本仓对应网络目录，并在 `A` 的步骤里按依赖顺序 `source`（先被依赖方，再本库）。`UniswapV2Zap` 依赖 `dex` 的 `addresses.uniswapv2.params` 就是这条规则的实例。
- **跨库复制件不要与本模块的地址文件合并**，也不要给它配一份 `<dep>.params`：`test/deploy_scripts_test.py` 用"是否有同名 `<module>.params`"区分本仓模块与跨库复制件，并单独校验复制件的字节一致性。
- **各工具的部署输入互不要求存在**：`11_deploy_a.sh` 不得因为 `b.params` 缺失或变动而失败。
- `test/deploy_scripts_test.py` 会按 `script/network/<net>/` 目录逐个检查必需文件、键名与地址格式，新增工具时同步扩展它的期望集合。

## 校验内容（21_check_batch_transfer.sh）

只读链上状态，不写任何文件：

- 地址文件键集合恰好是 `BATCH_TRANSFER_ADDRESS`（多键、缺键、改名都在链上调用之前失败）
- 地址是合法的非零 20 字节地址（`0x` + 40 位十六进制）
- `cast chain-id` 与 `network.params` 的 `CHAIN_ID` 一致
- `cast code` 非空（合约确实部署在该地址）
- `NATIVE_TRANSFER_GAS_LIMIT()` 等于 `50000`

部署后若改过 `src/BatchTransfer.sol` 里的这个常量，校验会失败——这是预期结果（链上代码与工作区源码不符），不是部署缺陷。

## 校验内容（22_check_uniswap_v2_zap.sh）

只读链上状态，不写任何文件：

- `addresses.uniswapv2.params` 键集合恰好是 `FACTORY_ADDRESS` `ROUTER_ADDRESS`
- `addresses.uniswap-v2-zap.params` 键集合恰好是 `UNISWAP_V2_ZAP_ADDRESS`
- 两份文件的地址都是合法的非零 20 字节地址
- `cast chain-id` 与 `network.params` 的 `CHAIN_ID` 一致
- `cast code` 非空
- `ROUTER()` 等于依赖文件里的 `ROUTER_ADDRESS`
- `FACTORY()` 等于**链上 Router 的 `factory()`**，且同时等于依赖文件里的 `FACTORY_ADDRESS`
- `WRAPPED_NATIVE_TOKEN()` 等于**链上 Router 的 `WETH()`**

`FACTORY()` / `WRAPPED_NATIVE_TOKEN()` 的期望值来自链上 Router 而不是同一个配置文件：拿文件里的值与文件里的值比对是自证，发现不了"dex 换了 Factory、复制件已更新、但 Zap 还是旧 Router"这类错配。

## 本地回归

```bash
git submodule update --init --recursive
forge build --force --deny warnings
forge test
python3 test/deploy_scripts_test.py      # 部署脚本回归：不联网、不广播
```

端到端验证需要先起本地链（`anvil`）并配好 `.account`。按依赖顺序：先跑 `dex` 的 `one_click_deploy.sh anvil31337_dev`（WETH + UniswapV2，必须在同一个干净的 anvil 上，否则地址对不上），把 `addresses.uniswapv2.params` 复制过来，再跑本仓的 `one_click_deploy_uniswap_v2_zap.sh anvil31337_dev` 与 `one_click_deploy_batch_transfer.sh anvil31337_dev`，确认两个 `2x` 校验全部通过、工作区无残留改动（部署写回的地址文件要还原成空哨兵）。
