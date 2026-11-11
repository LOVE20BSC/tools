// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IUniswapV2Zap,
    ZapNativeQuote,
    ZapQuote,
    ZapTokenParams
} from "./interfaces/IUniswapV2Zap.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IWrappedNative} from "./interfaces/IWrappedNative.sol";

contract UniswapV2Zap is ReentrancyGuard, IUniswapV2Zap {
    using SafeERC20 for IERC20;

    uint256 private constant UNISWAP_V2_MINIMUM_LIQUIDITY = 1000;
    uint256 private constant UNISWAP_V2_MAX_RESERVE = type(uint112).max;

    IUniswapV2Router02 public immutable override ROUTER;
    address public immutable override FACTORY;
    address public immutable override WRAPPED_NATIVE_TOKEN;

    constructor(address routerAddress) {
        if (routerAddress == address(0)) revert ZeroRouter();

        ROUTER = IUniswapV2Router02(routerAddress);
        FACTORY = IUniswapV2Router02(routerAddress).factory();
        WRAPPED_NATIVE_TOKEN = IUniswapV2Router02(routerAddress).WETH();

        if (FACTORY == address(0)) revert ZeroFactory();
        if (WRAPPED_NATIVE_TOKEN == address(0)) revert ZeroWrappedNativeToken();
    }

    receive() external payable override {
        if (msg.sender != WRAPPED_NATIVE_TOKEN) revert NativeTokenNotAccepted();
    }

    function zapToken(ZapTokenParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        _checkPair(params.tokenA, params.tokenB);
        if (params.to == address(0)) revert ZeroRecipientAddress();
        if (params.amountAIn == 0 && params.amountBIn == 0) revert ZeroInputAmounts();

        uint256 balanceABefore = IERC20(params.tokenA).balanceOf(address(this));
        uint256 balanceBBefore = IERC20(params.tokenB).balanceOf(address(this));

        if (params.amountAIn > 0) {
            IERC20(params.tokenA).safeTransferFrom(msg.sender, address(this), params.amountAIn);
        }
        if (params.amountBIn > 0) {
            IERC20(params.tokenB).safeTransferFrom(msg.sender, address(this), params.amountBIn);
        }

        ZapTokenParams memory zapParams = params;
        (amountA, amountB, liquidity) = _zapPair(zapParams);

        _refundTokenExcess(params.tokenA, msg.sender, balanceABefore);
        _refundTokenExcess(params.tokenB, msg.sender, balanceBBefore);

        emit TokenZapped({
            sender: msg.sender,
            tokenA: params.tokenA,
            tokenB: params.tokenB,
            to: params.to,
            amountA: amountA,
            amountB: amountB,
            liquidity: liquidity
        });
    }

    function zapNativeToken(
        address tokenAddress,
        uint256 amountTokenIn,
        uint256 amountTokenMin,
        uint256 amountNativeMin,
        uint256 liquidityMin,
        address to,
        uint256 deadline
    ) external payable override nonReentrant returns (uint256 amountToken, uint256 amountNative, uint256 liquidity) {
        if (tokenAddress == address(0)) revert ZeroToken();
        if (tokenAddress == WRAPPED_NATIVE_TOKEN) revert WrappedNativeTokenNotAccepted();
        if (to == address(0)) revert ZeroRecipientAddress();
        if (msg.value == 0 && amountTokenIn == 0) revert ZeroInputAmounts();

        uint256 tokenBalanceBefore = IERC20(tokenAddress).balanceOf(address(this));
        uint256 wrappedNativeBalanceBefore = IERC20(WRAPPED_NATIVE_TOKEN).balanceOf(address(this));

        if (amountTokenIn > 0) {
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amountTokenIn);
        }
        if (msg.value > 0) {
            IWrappedNative(WRAPPED_NATIVE_TOKEN).deposit{value: msg.value}();
        }

        (amountToken, amountNative, liquidity) = _zapNativePair(
            tokenAddress, amountTokenIn, msg.value, amountTokenMin, amountNativeMin, liquidityMin, to, deadline
        );

        _refundTokenExcess(tokenAddress, msg.sender, tokenBalanceBefore);
        _refundWrappedNativeExcessAsNative(msg.sender, wrappedNativeBalanceBefore);

        emit NativeTokenZapped({
            sender: msg.sender,
            tokenAddress: tokenAddress,
            to: to,
            amountToken: amountToken,
            amountNative: amountNative,
            liquidity: liquidity
        });
    }

    function quoteZapToken(address tokenA, address tokenB, uint256 amountAIn, uint256 amountBIn)
        external
        view
        override
        returns (ZapQuote memory quote)
    {
        _checkPair(tokenA, tokenB);
        if (amountAIn == 0 && amountBIn == 0) revert ZeroInputAmounts();
        return _quoteZapPair(tokenA, tokenB, amountAIn, amountBIn);
    }

    function quoteZapNativeToken(address tokenAddress, uint256 amountTokenIn, uint256 amountNativeIn)
        external
        view
        override
        returns (ZapNativeQuote memory quote)
    {
        if (tokenAddress == address(0)) revert ZeroToken();
        if (tokenAddress == WRAPPED_NATIVE_TOKEN) revert WrappedNativeTokenNotAccepted();
        if (amountTokenIn == 0 && amountNativeIn == 0) revert ZeroInputAmounts();
        return _quoteZapNativePair(tokenAddress, amountTokenIn, amountNativeIn);
    }

    function _zapPair(ZapTokenParams memory params)
        internal
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        (uint256 reserveA, uint256 reserveB, bool hasLiquidity,) = _reserves(params.tokenA, params.tokenB);

        if (!hasLiquidity) {
            if (params.amountAIn == 0 || params.amountBIn == 0) revert PairMissingOrEmpty();
        } else if (params.amountAIn * reserveB >= reserveA * params.amountBIn) {
            (params.amountAIn, params.amountBIn) = _swapExcess(
                params.tokenA, params.tokenB, reserveA, reserveB, params.amountAIn, params.amountBIn, params.deadline
            );
        } else {
            (params.amountBIn, params.amountAIn) = _swapExcess(
                params.tokenB, params.tokenA, reserveB, reserveA, params.amountBIn, params.amountAIn, params.deadline
            );
        }

        _approveToken(params.tokenA, params.amountAIn);
        _approveToken(params.tokenB, params.amountBIn);

        (amountA, amountB, liquidity) = ROUTER.addLiquidity(
            params.tokenA,
            params.tokenB,
            params.amountAIn,
            params.amountBIn,
            params.amountAMin,
            params.amountBMin,
            params.to,
            params.deadline
        );

        if (liquidity < params.liquidityMin) revert SlippageExceeded(liquidity, params.liquidityMin);

        _approveToken(params.tokenA, 0);
        _approveToken(params.tokenB, 0);
    }

    function _zapNativePair(
        address tokenAddress,
        uint256 amountTokenIn,
        uint256 amountNativeIn,
        uint256 amountTokenMin,
        uint256 amountNativeMin,
        uint256 liquidityMin,
        address to,
        uint256 deadline
    ) internal returns (uint256 amountToken, uint256 amountNative, uint256 liquidity) {
        (amountNative, amountToken, liquidity) = _zapPair(
            ZapTokenParams({
                tokenA: WRAPPED_NATIVE_TOKEN,
                tokenB: tokenAddress,
                amountAIn: amountNativeIn,
                amountBIn: amountTokenIn,
                amountAMin: amountNativeMin,
                amountBMin: amountTokenMin,
                liquidityMin: liquidityMin,
                to: to,
                deadline: deadline
            })
        );
    }

    function _quoteZapPair(address tokenA, address tokenB, uint256 amountAIn, uint256 amountBIn)
        internal
        view
        returns (ZapQuote memory quote)
    {
        (uint256 reserveA, uint256 reserveB, bool hasLiquidity, address pairAddress) = _reserves(tokenA, tokenB);
        if (amountAIn > UNISWAP_V2_MAX_RESERVE) revert AmountExceeded(amountAIn, UNISWAP_V2_MAX_RESERVE);
        if (amountBIn > UNISWAP_V2_MAX_RESERVE) revert AmountExceeded(amountBIn, UNISWAP_V2_MAX_RESERVE);
        quote.hasLiquidity = hasLiquidity;

        if (!hasLiquidity) {
            if (amountAIn == 0 || amountBIn == 0) revert PairMissingOrEmpty();
            if (amountAIn * amountBIn < (UNISWAP_V2_MINIMUM_LIQUIDITY + 1) * (UNISWAP_V2_MINIMUM_LIQUIDITY + 1)) {
                revert InsufficientInitialLiquidity();
            }
            quote.amountAUsed = amountAIn;
            quote.amountBUsed = amountBIn;
            quote.liquidity = Math.sqrt(amountAIn * amountBIn) - UNISWAP_V2_MINIMUM_LIQUIDITY;
            quote.reserveAAfter = amountAIn;
            quote.reserveBAfter = amountBIn;
            return quote;
        }

        uint256 amountAAfterSwap = amountAIn;
        uint256 amountBAfterSwap = amountBIn;
        uint256 reserveAAfterSwap = reserveA;
        uint256 reserveBAfterSwap = reserveB;

        if (amountAIn * reserveB >= reserveA * amountBIn) {
            quote.amountToSwap = _calcAmountToSwap(reserveA, reserveB, amountAIn, amountBIn);
            if (quote.amountToSwap > 0) {
                quote.willSwap = true;
                quote.swapTokenIn = tokenA;
                quote.swapTokenOut = tokenB;
                quote.amountOutFromSwap = _getAmountOut(quote.amountToSwap, reserveA, reserveB);
                if (quote.amountOutFromSwap == 0) revert SwapOutputZero();
                amountAAfterSwap = amountAIn - quote.amountToSwap;
                amountBAfterSwap = amountBIn + quote.amountOutFromSwap;
                reserveAAfterSwap = reserveA + quote.amountToSwap;
                reserveBAfterSwap = reserveB - quote.amountOutFromSwap;
            }
        } else {
            quote.amountToSwap = _calcAmountToSwap(reserveB, reserveA, amountBIn, amountAIn);
            if (quote.amountToSwap > 0) {
                quote.willSwap = true;
                quote.swapTokenIn = tokenB;
                quote.swapTokenOut = tokenA;
                quote.amountOutFromSwap = _getAmountOut(quote.amountToSwap, reserveB, reserveA);
                if (quote.amountOutFromSwap == 0) revert SwapOutputZero();
                amountBAfterSwap = amountBIn - quote.amountToSwap;
                amountAAfterSwap = amountAIn + quote.amountOutFromSwap;
                reserveBAfterSwap = reserveB + quote.amountToSwap;
                reserveAAfterSwap = reserveA - quote.amountOutFromSwap;
            }
        }

        (quote.amountAUsed, quote.amountBUsed) =
            _quoteLiquidityAmounts(reserveAAfterSwap, reserveBAfterSwap, amountAAfterSwap, amountBAfterSwap);
        if (quote.amountAUsed == 0 || quote.amountBUsed == 0) revert OptimalAmountZero();
        uint256 totalSupply =
            _quoteTotalSupplyAfterFeeMint(IUniswapV2Pair(pairAddress), reserveAAfterSwap, reserveBAfterSwap);
        quote.liquidity = _quoteLiquidityMinted(
            reserveAAfterSwap, reserveBAfterSwap, totalSupply, quote.amountAUsed, quote.amountBUsed
        );
        if (quote.liquidity == 0) revert LiquidityMintedZero();
        quote.reserveAAfter = reserveAAfterSwap + quote.amountAUsed;
        quote.reserveBAfter = reserveBAfterSwap + quote.amountBUsed;
    }

    function _quoteZapNativePair(address tokenAddress, uint256 amountTokenIn, uint256 amountNativeIn)
        internal
        view
        returns (ZapNativeQuote memory quote)
    {
        ZapQuote memory pairQuote = _quoteZapPair(WRAPPED_NATIVE_TOKEN, tokenAddress, amountNativeIn, amountTokenIn);
        quote.hasLiquidity = pairQuote.hasLiquidity;
        quote.willSwap = pairQuote.willSwap;
        quote.swapTokenIn = pairQuote.swapTokenIn;
        quote.swapTokenOut = pairQuote.swapTokenOut;
        quote.amountToSwap = pairQuote.amountToSwap;
        quote.amountOutFromSwap = pairQuote.amountOutFromSwap;
        quote.amountTokenUsed = pairQuote.amountBUsed;
        quote.amountNativeUsed = pairQuote.amountAUsed;
        quote.liquidity = pairQuote.liquidity;
        quote.reserveTokenAfter = pairQuote.reserveBAfter;
        quote.reserveNativeAfter = pairQuote.reserveAAfter;
    }

    function _swapExcess(
        address tokenIn,
        address tokenOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint256 amountOutAlready,
        uint256 deadline
    ) internal returns (uint256 amountInAfterSwap, uint256 amountOutAfterSwap) {
        uint256 amountToSwap = _calcAmountToSwap(reserveIn, reserveOut, amountIn, amountOutAlready);
        amountInAfterSwap = amountIn;
        amountOutAfterSwap = amountOutAlready;

        if (amountToSwap == 0) {
            return (amountInAfterSwap, amountOutAfterSwap);
        }

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        _approveToken(tokenIn, amountToSwap);
        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(amountToSwap, 1, path, address(this), deadline);

        amountInAfterSwap = amountIn - amountToSwap;
        amountOutAfterSwap = amountOutAlready + amounts[1];
    }

    function _calcAmountToSwap(uint256 reserveIn, uint256 reserveOut, uint256 amountIn, uint256 amountOutAlready)
        internal
        pure
        returns (uint256 amountToSwap)
    {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountIn > UNISWAP_V2_MAX_RESERVE) revert AmountExceeded(amountIn, UNISWAP_V2_MAX_RESERVE);
        if (amountOutAlready > UNISWAP_V2_MAX_RESERVE) {
            revert AmountExceeded(amountOutAlready, UNISWAP_V2_MAX_RESERVE);
        }
        // No guard for `amountIn * reserveOut < reserveIn * amountOutAlready`: every caller picks the
        // swap direction with exactly that comparison before entering here, so the subtraction below
        // cannot underflow. `_quoteZapPair` calls this only from its
        // `amountAIn * reserveB >= reserveA * amountBIn` branch (swapping the operands in the else
        // branch), and `_swapExcess` is reached from the same comparison in `_zapPair`. Were the
        // invariant ever violated, the subtraction panics instead of returning a bogus quote.
        uint256 imbalance = amountIn * reserveOut - reserveIn * amountOutAlready;
        return (
            Math.sqrt(
                reserveIn * reserveIn * 3_988_009
                    + Math.mulDiv(reserveIn * 3_988_000, imbalance, reserveOut + amountOutAlready)
            ) - reserveIn * 1_997
        ) / 1_994;
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function _quoteLiquidityAmounts(uint256 reserveA, uint256 reserveB, uint256 amountADesired, uint256 amountBDesired)
        internal
        pure
        returns (uint256 amountA, uint256 amountB)
    {
        uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
        if (amountBOptimal <= amountBDesired) {
            return (amountADesired, amountBOptimal);
        }

        uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
        return (amountAOptimal, amountBDesired);
    }

    function _quoteLiquidityMinted(
        uint256 reserveA,
        uint256 reserveB,
        uint256 totalSupply,
        uint256 amountA,
        uint256 amountB
    ) internal pure returns (uint256 liquidity) {
        if (totalSupply == 0) {
            return Math.sqrt(amountA * amountB) - UNISWAP_V2_MINIMUM_LIQUIDITY;
        }

        liquidity = Math.min((amountA * totalSupply) / reserveA, (amountB * totalSupply) / reserveB);
    }

    function _quoteTotalSupplyAfterFeeMint(IUniswapV2Pair pair, uint256 reserveA, uint256 reserveB)
        internal
        view
        returns (uint256 totalSupply)
    {
        totalSupply = pair.totalSupply();

        if (IUniswapV2Factory(FACTORY).feeTo() == address(0)) {
            return totalSupply;
        }

        uint256 kLast = pair.kLast();
        if (kLast == 0) {
            return totalSupply;
        }

        uint256 rootK = Math.sqrt(reserveA * reserveB);
        uint256 rootKLast = Math.sqrt(kLast);
        if (rootK <= rootKLast) {
            return totalSupply;
        }

        return totalSupply + (totalSupply * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
    }

    function _reserves(address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB, bool hasLiquidity, address pairAddress)
    {
        pairAddress = IUniswapV2Factory(FACTORY).getPair(tokenA, tokenB);
        if (pairAddress == address(0)) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, false, pairAddress);
        }

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairAddress).getReserves();
        if (reserve0 == 0 && reserve1 == 0) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, false, pairAddress);
        }

        address token0 = IUniswapV2Pair(pairAddress).token0();
        (reserveA, reserveB) = tokenA == token0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        hasLiquidity = true;
    }

    function _checkPair(address tokenA, address tokenB) internal pure {
        if (tokenA == address(0)) revert ZeroTokenA();
        if (tokenB == address(0)) revert ZeroTokenB();
        if (tokenA == tokenB) revert IdenticalTokens();
    }

    function _approveToken(address tokenAddress, uint256 amount) internal {
        IERC20(tokenAddress).forceApprove(address(ROUTER), amount);
    }

    function _refundTokenExcess(address tokenAddress, address to, uint256 balanceBefore) internal {
        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
        if (balance > balanceBefore) {
            IERC20(tokenAddress).safeTransfer(to, balance - balanceBefore);
        }
    }

    function _refundWrappedNativeExcessAsNative(address to, uint256 balanceBefore) internal {
        uint256 balance = IERC20(WRAPPED_NATIVE_TOKEN).balanceOf(address(this));
        if (balance > balanceBefore) {
            uint256 refund = balance - balanceBefore;
            IWrappedNative(WRAPPED_NATIVE_TOKEN).withdraw(refund);
            _transferNative(to, refund);
        }
    }

    function _transferNative(address to, uint256 amount) internal {
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (bool success,) = to.call{value: amount}("");
        if (!success) revert NativeRefundFailed();
    }
}
