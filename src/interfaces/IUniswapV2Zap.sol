// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IUniswapV2Router02} from "./IUniswapV2Router02.sol";

struct ZapTokenParams {
    address tokenA;
    address tokenB;
    uint256 amountAIn;
    uint256 amountBIn;
    uint256 amountAMin;
    uint256 amountBMin;
    uint256 liquidityMin;
    address to;
    uint256 deadline;
}

struct ZapQuote {
    bool hasLiquidity;
    bool willSwap;
    address swapTokenIn;
    address swapTokenOut;
    uint256 amountToSwap;
    uint256 amountOutFromSwap;
    uint256 amountAUsed;
    uint256 amountBUsed;
    uint256 liquidity;
    uint256 reserveAAfter;
    uint256 reserveBAfter;
}

struct ZapNativeQuote {
    bool hasLiquidity;
    bool willSwap;
    address swapTokenIn;
    address swapTokenOut;
    uint256 amountToSwap;
    uint256 amountOutFromSwap;
    uint256 amountTokenUsed;
    uint256 amountNativeUsed;
    uint256 liquidity;
    uint256 reserveTokenAfter;
    uint256 reserveNativeAfter;
}

interface IUniswapV2ZapEvents {
    event TokenZapped(
        address indexed sender,
        address indexed tokenA,
        address indexed tokenB,
        address to,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );
    event NativeTokenZapped(
        address indexed sender,
        address indexed tokenAddress,
        address indexed to,
        uint256 amountToken,
        uint256 amountNative,
        uint256 liquidity
    );
}

interface IUniswapV2ZapErrors {
    error ZeroRouter();
    error ZeroFactory();
    error ZeroWrappedNativeToken();
    error NativeTokenNotAccepted();
    error ZeroTokenA();
    error ZeroTokenB();
    error ZeroToken();
    error IdenticalTokens();
    error WrappedNativeToken();
    error ZeroTo();
    error ZeroAmount();
    error PairMissingOrEmpty();
    error InsufficientLiquidity();
    error InvalidRatio();
    error InsufficientLiquidityMinted();
    error AmountTooLarge();
    error NativeTransferFailed();
}

interface IUniswapV2Zap is IUniswapV2ZapEvents, IUniswapV2ZapErrors {
    receive() external payable;

    function router() external view returns (IUniswapV2Router02);

    function factory() external view returns (address);

    function wrappedNativeToken() external view returns (address);

    function zapToken(ZapTokenParams calldata params)
        external
        returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function zapNativeToken(
        address tokenAddress,
        uint256 amountTokenIn,
        uint256 amountTokenMin,
        uint256 amountNativeMin,
        uint256 liquidityMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountNative, uint256 liquidity);

    function quoteZapToken(address tokenA, address tokenB, uint256 amountAIn, uint256 amountBIn)
        external
        view
        returns (ZapQuote memory quote);

    function quoteZapNativeToken(address tokenAddress, uint256 amountTokenIn, uint256 amountNativeIn)
        external
        view
        returns (ZapNativeQuote memory quote);
}
