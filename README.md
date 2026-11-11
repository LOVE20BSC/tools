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
- `BatchTransfer` 处于旧代码基线：实现与测试原样取自 `LOVE20TKM/batch-transfer@5bc194c`，尚未改造到本仓基线。

## 构建与测试

```sh
git submodule update --init --recursive
forge build
forge test
```
