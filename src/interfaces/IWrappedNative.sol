// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

// 最小外部调用面：只声明 UniswapV2Zap 实际调用的成员，不复制 WETH9 完整接口。
interface IWrappedNative {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}
