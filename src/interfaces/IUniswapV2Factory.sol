// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

// 最小外部调用面：只声明 UniswapV2Zap 实际调用的成员，不复制上游完整接口。
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    function feeTo() external view returns (address);
}
