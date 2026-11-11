// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

// 最小外部调用面：只声明 UniswapV2Zap 实际调用的成员，不复制上游完整接口。
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function totalSupply() external view returns (uint256);

    function kLast() external view returns (uint256);
}
