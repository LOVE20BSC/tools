# BatchTransfer 部署指南

`tools` 是多工具仓，每个工具合约自带一套部署脚本，**不共享**编号：`NN_*_<tool>.sh`。当前只有一个工具 `BatchTransfer`，因此本目录下是 `11_deploy_batch_transfer.sh` / `21_check_batch_transfer.sh` / `31_verify_batch_transfer.sh` 与入口 `one_click_deploy_batch_transfer.sh`。

## 目录结构

```
script/
├── deploy/
│   ├── one_click_deploy_batch_transfer.sh  # 一键部署入口（纯编排，不载入任何环境文件）
│   ├── 11_deploy_batch_transfer.sh         # 合约部署（自载入部署输入，原子写入地址）
│   ├── 21_check_batch_transfer.sh          # 部署正确性校验（自载入校验文件，只读可重复）
│   ├── 31_verify_batch_transfer.sh         # 合约开源验证（自载入网络与地址文件）
│   ├── DeployBatchTransfer.s.sol           # Foundry 部署脚本（部署 + 部署期校验）
│   ├── params.sh                           # 参数载入器（与 core/action/group-chat/dex 逐字节相同）
│   └── README.md
└── network/
    ├── verifier.params                     # 开源验证端点与跳过链（所有网络共用一份）
    └── anvil31337_dev/                     # 本地 anvil · dev
        ├── .account                        # 账户信息（敏感，已 gitignore）
        ├── network.params                  # 网络参数：CHAIN_ID、RPC_URL、ETHERSCAN_API_KEY
        ├── batch-transfer.params           # 本模块参数（BatchTransfer 无构造参数，文件只含注释）
        └── addresses.batch-transfer.params # 已部署地址（部署成功后自动写入，键名 BATCH_TRANSFER_ADDRESS）
```

## 每个脚本的职责

| 脚本 | 职责 |
| --- | --- |
| `one_click_deploy_batch_transfer.sh` | 纯编排：解析一次 keystore 密码 → 备份旧地址文件 → 依次跑 `11` / `21` / `31` → 校验失败时回滚地址文件并退出非零。不 source 任何配置文件，也不重复各步骤的校验。 |
| `11_deploy_batch_transfer.sh` | 自载入 `network.params` / `batch-transfer.params` / `.account`，核对链 ID，用 `--password-file`（权限 600 的临时文件）调 `forge script` 广播；从部署日志取 `BATCH_TRANSFER_ADDRESS=`，核对本次运行刷新过 `broadcast/DeployBatchTransfer.s.sol/<chain-id>/run-latest.json`，最后**原子替换**地址文件（同目录临时文件 + `mv`）。 |
| `21_check_batch_transfer.sh` | 独立、只读、可重复：断言地址文件键集合恰好是 `BATCH_TRANSFER_ADDRESS`，核对链 ID，`cast code` 确认有代码，回读 `NATIVE_TRANSFER_GAS_LIMIT()` 必须为 `50000`。地址为空/零地址/格式非法时在逐项链上调用之前就失败。 |
| `31_verify_batch_transfer.sh` | 自载入 `network.params` / `verifier.params` / 地址文件，链 ID 列在 `VERIFY_SKIP_CHAIN_IDS` 时跳过并返回 0，否则用 `ETHERSCAN_VERIFIER_URL` + `ETHERSCAN_API_KEY` 提交 `forge verify-contract`。BatchTransfer 无构造参数，不传 `--constructor-args`。 |
| `DeployBatchTransfer.s.sol` | 部署与部署期校验：`_loadConfig` 只读 `CHAIN_ID`（合约无构造参数），`_validateConfig` 在 `startBroadcast()` 前核对 `block.chainid`，`_validateDeployment` 在 `stopBroadcast()` 后确认有代码且 `NATIVE_TRANSFER_GAS_LIMIT()` 为 50000，最后打印 `BATCH_TRANSFER_ADDRESS=<addr>` 供 `11` 提取。 |

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

```bash
# 部署（自载入 network.params / batch-transfer.params / .account）
./script/deploy/11_deploy_batch_transfer.sh anvil31337_dev

# 校验部署结果（自载入 network.params / batch-transfer.params / addresses.batch-transfer.params）
./script/deploy/21_check_batch_transfer.sh anvil31337_dev

# 合约开源验证
./script/deploy/31_verify_batch_transfer.sh anvil31337_dev
```

`21_check_batch_transfer.sh` 在地址文件缺失、地址为空或为非法格式时提示先跑一键部署，不会静默通过。

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
| `script/deploy/11_deploy_<tool>.sh` | 部署该工具，写 `script/network/<net>/addresses.<tool>.params` |
| `script/deploy/21_check_<tool>.sh` | 校验该工具，断言自己那份地址文件的键集合 |
| `script/deploy/31_verify_<tool>.sh` | 开源验证（无浏览器的链靠 `VERIFY_SKIP_CHAIN_IDS` 跳过） |
| `script/deploy/Deploy<Tool>.s.sol` | Foundry 部署脚本，广播前静态校验、广播后回读校验 |
| `script/deploy/one_click_deploy_<tool>.sh` | 该工具的一键入口 |
| `script/network/<net>/<tool>.params` | 该工具的构造参数（无参数也要保留文件并显式写注释说明） |
| `script/network/<net>/addresses.<tool>.params` | 该工具已部署地址，键名 `<TOOL>_ADDRESS`（UPPER_SNAKE_CASE，以 `_ADDRESS` 结尾） |

约束：

- **不设覆盖全仓的 `one_click_deploy.sh`**：`tools` 里的工具彼此独立，一个工具部署失败不该阻塞另一个；每个工具一个入口，按需执行。
- **工具之间不互相调用入口脚本**。工具 A 需要工具 B 的已部署地址时，把 `B/script/network/<net>/addresses.<b>.params` 复制到本仓对应网络目录，并在 `A` 的步骤里按依赖顺序 `source`（先被依赖方，再本库）。
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

## 本地回归

```bash
git submodule update --init --recursive
forge build --force --deny warnings
forge test
python3 test/deploy_scripts_test.py      # 部署脚本回归：不联网、不广播
```

端到端验证需要先起本地链（`anvil`）并配好 `.account`，再跑 `./script/deploy/one_click_deploy_batch_transfer.sh anvil31337_dev`，确认 `21_check_batch_transfer.sh` 全部通过、工作区无残留改动。
