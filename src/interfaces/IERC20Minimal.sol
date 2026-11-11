// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

/// @notice 最小 ERC20 编码接口：只声明 BatchTransfer 会编码的 selector，不是 LOVE20 自有 ABI。
/// @dev 放在 src/interfaces/ 只是为了本仓所有 ABI 声明只有一个位置（dev-standards §4.1）；
/// 它不引入 OpenZeppelin 依赖，也不代表本仓认领 ERC20 标准。
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
