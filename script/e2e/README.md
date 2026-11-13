# 端到端检查（anvil）

`anvil_e2e.sh` 在一个一次性的 anvil 链上把 `BatchTransfer` 真正部署一遍并实际调用，用来验证 `script/deploy/` 这条路径本身可用——不是绕过它直接写一份「测试用」的部署逻辑。

```sh
script/e2e/anvil_e2e.sh          # 跑完自动停链并还原地址文件
script/e2e/anvil_e2e.sh --keep   # 保留链与部署结果，便于排查
```

## 它检查什么

| 阶段 | 检查 |
| --- | --- |
| 前置条件 | 工具链、`.account` 与 keystore、端口空闲 |
| 链 | 从空链出发（block 0），`network.params` 的 `RPC_URL` 指向本次端口 |
| 部署路径 | 跑 `one_click_deploy_batch_transfer.sh`，含 `21_check` 的字节码比对与 `31_verify` 的跳过逻辑 |
| 原生币批量 | `batchTransferNative` 真的转账，逐笔核对收款方余额，并断言合约自身余额为 0 |
| ERC20 批量 | `batchTransferERC20` 走真实的 `transferFrom`，核对收款方余额与合约零残留 |
| 自定义错误 | `ZeroGasLimit` 的 selector 与 `NativeValueMismatch` 的载荷 |

## 前置条件

1. **Foundry 1.8.1+**，`anvil`、`cast`、`forge`、`python3` 在 `PATH` 上。
2. **本仓已构建**。ERC20 用的是本仓测试 mock 的构建产物（`out/BatchTransferMocks.sol/MockERC20.json`），跑一次 `forge build` 即可：

   ```sh
   forge build
   ```

   `tools` 不依赖其他仓库，这一步不需要 dex 或任何兄弟目录的产物。

3. **keystore 与 `.account`**。部署脚本一律用 keystore 签名，不读私钥。

   ```sh
   # 一次性：把 anvil 的第一个默认账户导入 keystore（密码自定，下面用 anvil）
   cast wallet import anvil_account --interactive   # 私钥见 anvil 启动输出

   # 然后写 script/network/anvil31337_dev/.account（该文件被 .gitignore 忽略）
   cat > script/network/anvil31337_dev/.account <<'EOF'
   KEYSTORE_ACCOUNT=anvil_account
   ACCOUNT_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
   KEYSTORE_PASSWORD=anvil
   EOF
   chmod 600 script/network/anvil31337_dev/.account
   ```

   `ACCOUNT_ADDRESS` 必须与 keystore 里的地址一致，否则脚本在部署前就失败。

## 设计取舍

**跑在仓内，跑完还原。** 脚本直接使用 `script/network/anvil31337_dev/` 下的地址文件，因此会改写它们；退出时（无论成功、失败还是被中断）从临时备份还原，所以工作树不会被脏。`broadcast/` 与 `cache/` 会写入，两者都在 `.gitignore` 内。

**测试用代币由脚本自己部署，用 anvil 的公开默认私钥。** 那把私钥是 `anvil` 启动时打印的本地测试账户，只用于部署一个普通 ERC20 夹具，使这一步不依赖操作者的 keystore；`BatchTransfer` 本身仍然走 keystore 这条生产路径。

**不检查的**：源码验证（31337 在 `verifier.params` 的跳过名单里）、非 anvil 网络、以及 `forge test` 已经覆盖的单元行为。本脚本补的是单元测试覆盖不到的那一段：脚本链、真实字节码、真实 ERC20 调用、真实 gas。

## 常见失败

| 现象 | 原因 |
| --- | --- |
| `something is already listening on ...` | 端口被占用；停掉现有链，或用 `E2E_PORT=8546`（脚本会把 `network.params` 的 `RPC_URL` 一并指过去，跑完还原） |
| `missing build artifact` | 没构建；先跑 `forge build` |
| `KEYSTORE_PASSWORD empty` | `.account` 里没写密码，脚本刻意不弹窗，以便非交互运行 |
| `NativeValueMismatch(` 没出现在输出里 | 合约的 revert 载荷变了；检查 `src/interfaces/IBatchTransfer.sol` 里的错误声明 |
