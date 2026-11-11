# 端到端检查（anvil）

`anvil_e2e.sh` 在一个一次性的 anvil 链上把本仓的每个工具真正部署一遍并实际调用，用来验证 `script/deploy/` 这条路径本身可用——不是绕过它直接写一份「测试用」的部署逻辑。

```sh
script/e2e/anvil_e2e.sh          # 跑完自动停链并还原地址文件
script/e2e/anvil_e2e.sh --keep   # 保留链与部署结果，便于排查
```

## 它检查什么

| 阶段 | 检查 |
| --- | --- |
| 前置条件 | 工具链、`.account` 与 keystore、`dex` 构建产物、端口空闲 |
| 链与依赖 | 从空链出发；部署 WETH9 / Factory / Router02；`router.factory()` 与 `router.WETH()` 回读一致 |
| 部署路径 | 跑 `one_click_deploy_batch_transfer.sh` 与 `one_click_deploy_uniswap_v2_zap.sh`，含各自的 `2x` 校验步骤与 `ROUTER()` / `FACTORY()` / `WRAPPED_NATIVE_TOKEN()` 回读 |
| BatchTransfer | `batchTransferNative` 真的转账，逐笔核对收款方余额 |
| UniswapV2Zap | `zapToken` 建对并铸 LP；`zapNativeToken` 走原生币入口；两次调用后 Zap **零残留**（token / WETH / LP 都为 0） |
| 自定义错误 | `ZeroInputAmounts` 的 selector 与 `AmountExceeded` 的载荷 |

`zap` 的零残留是「不托管用户资产」这条承诺的可执行形式，比读代码更可靠。

## 前置条件

1. **Foundry 1.8.1+**，`anvil`、`cast`、`forge` 在 `PATH` 上。
2. **`dex` 已构建**。Uniswap V2 的字节码来自兄弟目录的构建产物：

   ```sh
   git -C ../dex submodule update --init --recursive
   make -C ../dex build
   ```

   默认找 `../dex`，可用 `LOVE20_DEX_DIR=/path/to/dex` 指定。

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

**跑在仓内，跑完还原。** 脚本直接使用 `script/network/anvil31337_dev/` 下的地址文件，因此会改写它们；退出时（无论成功、失败还是被中断）从临时备份还原，所以工作树不会被弄脏。`broadcast/` 与 `cache/` 会写入，两者都在 `.gitignore` 内。

**Uniswap 由脚本自己部署，用 anvil 的公开默认私钥。** 那把私钥是 `anvil` 启动时打印的本地测试账户，只用于部署依赖栈，使这一步不依赖操作者的 keystore；两个工具本身仍然走 keystore 这条生产路径。地址文件按 `dev-standards` §6.2 的方式生成——它是 `dex` 的 `addresses.uniswapv2.params` 的复制件，不是在本仓手工合并出来的。

**不检查的**：源码验证（31337 在 `verifier.params` 的跳过名单里）、非 anvil 网络、以及 `forge test` 已经覆盖的单元行为。本脚本补的是单元测试覆盖不到的那一段：脚本链、真实字节码、真实 Router、真实 gas。

## 常见失败

| 现象 | 原因 |
| --- | --- |
| `something is already listening on ...` | 端口被占用；停掉现有链或用 `E2E_PORT=8546` |
| `missing dex artifact` | `dex` 没构建；跑 `make -C ../dex build` |
| `KEYSTORE_PASSWORD empty` | `.account` 里没写密码，脚本刻意不弹窗，以便非交互运行 |
| `INSUFFICIENT_B_AMOUNT`（`zapNativeToken`） | 给的币对比例与池子不符，Router 自身的滑点检查拦下了；检查测试参数 |
