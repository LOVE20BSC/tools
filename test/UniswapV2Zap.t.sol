// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV2Zap} from "../src/UniswapV2Zap.sol";
import {
    IUniswapV2ZapErrors,
    IUniswapV2ZapEvents,
    ZapNativeQuote,
    ZapQuote,
    ZapTokenParams
} from "../src/interfaces/IUniswapV2Zap.sol";
import {
    MockERC20,
    MockUniswapV2Factory,
    MockUniswapV2Pair,
    MockUniswapV2Router02,
    MockWrappedNative
} from "./mocks/ZapMocks.sol";

contract UniswapV2ZapTest is Test, IUniswapV2ZapEvents {
    UniswapV2Zap internal zap;
    MockUniswapV2Router02 internal router;
    MockUniswapV2Factory internal factory;
    MockWrappedNative internal weth;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockUniswapV2Pair internal pairAB;
    MockUniswapV2Pair internal pairNativeA;

    address internal user = address(0x1234);
    address internal recipient = address(0x5678);

    uint256 internal constant SEED_LIQUIDITY = 1_000 ether;
    uint256 internal constant NATIVE_SEED_LIQUIDITY = 100 ether;
    uint256 internal constant USER_NATIVE_BALANCE = 200 ether;

    /// @dev `cast sig` of the no-argument ratio-mismatch error that `_calcAmountToSwap` used to
    /// declare and guard on. The declaration is deleted (`error-standards` §8: no unreachable
    /// errors), so the selector is frozen here as a literal: a test that asserted on the removed
    /// declaration would not compile, and a test that dropped it entirely would lose the proof that
    /// the deleted error really was unreachable. See the README's ABI-diff table for the derivation.
    bytes4 internal constant RETIRED_RATIO_ERROR_SELECTOR = 0x648564d3;

    receive() external payable {}

    function setUp() public {
        weth = new MockWrappedNative();
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router02(address(factory), address(weth));
        zap = new UniswapV2Zap(address(router));

        tokenA = new MockERC20();
        tokenB = new MockERC20();

        vm.deal(address(this), 10_000 ether);

        // tokenA/tokenB at 1000:1000 and weth/tokenA at 100:1000, both minted through the router so
        // every seeded pool carries a real totalSupply (sqrt(k), MINIMUM_LIQUIDITY locked).
        pairAB = _seedPair(address(tokenA), address(tokenB), SEED_LIQUIDITY, SEED_LIQUIDITY);
        pairNativeA = _seedNativePair(address(tokenA), NATIVE_SEED_LIQUIDITY, SEED_LIQUIDITY);

        vm.deal(user, USER_NATIVE_BALANCE);
    }

    // ----------------------------------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------------------------------

    function testConstructorBindsRouterFactoryAndWrappedNative() public view {
        assertEq(address(zap.router()), address(router));
        assertEq(zap.factory(), address(factory));
        assertEq(zap.wrappedNativeToken(), address(weth));
    }

    function testConstructorRevertsForZeroRouter() public {
        vm.expectRevert(IUniswapV2ZapErrors.ZeroRouter.selector);
        new UniswapV2Zap(address(0));
    }

    function testConstructorRevertsForZeroFactory() public {
        router.setFactory(address(0));

        vm.expectRevert(IUniswapV2ZapErrors.ZeroFactory.selector);
        new UniswapV2Zap(address(router));
    }

    function testConstructorRevertsForZeroWrappedNative() public {
        router.setWeth(address(0));

        vm.expectRevert(IUniswapV2ZapErrors.ZeroWrappedNativeToken.selector);
        new UniswapV2Zap(address(router));
    }

    function testConstructorDerivesFactoryAndWrappedNativeFromRouter() public {
        MockUniswapV2Router02 otherRouter = new MockUniswapV2Router02(address(0xFACADE), address(0xBEEF));
        UniswapV2Zap otherZap = new UniswapV2Zap(address(otherRouter));

        assertEq(otherZap.factory(), address(0xFACADE));
        assertEq(otherZap.wrappedNativeToken(), address(0xBEEF));
    }

    // ----------------------------------------------------------------------------------------
    // receive
    // ----------------------------------------------------------------------------------------

    function testReceiveRejectsNonWrappedNative() public {
        vm.expectRevert(IUniswapV2ZapErrors.NativeTokenNotAccepted.selector);
        _sendNativeToZap(address(zap), 1 ether);

        assertEq(address(zap).balance, 0);
    }

    function testReceiveAcceptsWrappedNative() public {
        // The wrapped-native contract is the only accepted sender: every native refund is routed
        // through it, so this is the one path that must stay open.
        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (bool success,) = address(zap).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(zap).balance, 1 ether);
    }

    // ----------------------------------------------------------------------------------------
    // Parameter validation
    // ----------------------------------------------------------------------------------------

    function testZapTokenParamValidationReverts() public {
        ZapTokenParams memory params = _params(address(tokenA), address(tokenB), 1, 0);

        params.tokenA = address(0);
        vm.expectRevert(IUniswapV2ZapErrors.ZeroTokenA.selector);
        zap.zapToken(params);

        params.tokenA = address(tokenA);
        params.tokenB = address(0);
        vm.expectRevert(IUniswapV2ZapErrors.ZeroTokenB.selector);
        zap.zapToken(params);

        params.tokenB = address(tokenA);
        vm.expectRevert(IUniswapV2ZapErrors.IdenticalTokens.selector);
        zap.zapToken(params);

        params.tokenB = address(tokenB);
        params.to = address(0);
        vm.expectRevert(IUniswapV2ZapErrors.ZeroRecipientAddress.selector);
        zap.zapToken(params);

        params.to = recipient;
        params.amountAIn = 0;
        params.amountBIn = 0;
        vm.expectRevert(IUniswapV2ZapErrors.ZeroAmount.selector);
        zap.zapToken(params);
    }

    function testZapNativeTokenParamValidationReverts() public {
        vm.expectRevert(IUniswapV2ZapErrors.ZeroToken.selector);
        zap.zapNativeToken(address(0), 0, 1, 1, 1, recipient, block.timestamp + 1);

        vm.expectRevert(IUniswapV2ZapErrors.WrappedNativeTokenNotAccepted.selector);
        zap.zapNativeToken(address(weth), 0, 1, 1, 1, recipient, block.timestamp + 1);

        vm.expectRevert(IUniswapV2ZapErrors.ZeroRecipientAddress.selector);
        zap.zapNativeToken{value: 1}(address(tokenA), 0, 1, 1, 1, address(0), block.timestamp + 1);

        vm.expectRevert(IUniswapV2ZapErrors.ZeroAmount.selector);
        zap.zapNativeToken(address(tokenA), 0, 1, 1, 1, recipient, block.timestamp + 1);
    }

    function testQuoteParamValidationReverts() public {
        vm.expectRevert(IUniswapV2ZapErrors.ZeroTokenA.selector);
        zap.quoteZapToken(address(0), address(tokenB), 1, 0);

        vm.expectRevert(IUniswapV2ZapErrors.ZeroTokenB.selector);
        zap.quoteZapToken(address(tokenA), address(0), 1, 0);

        vm.expectRevert(IUniswapV2ZapErrors.IdenticalTokens.selector);
        zap.quoteZapToken(address(tokenA), address(tokenA), 1, 0);

        vm.expectRevert(IUniswapV2ZapErrors.ZeroAmount.selector);
        zap.quoteZapToken(address(tokenA), address(tokenB), 0, 0);

        vm.expectRevert(IUniswapV2ZapErrors.ZeroToken.selector);
        zap.quoteZapNativeToken(address(0), 1, 0);

        vm.expectRevert(IUniswapV2ZapErrors.WrappedNativeTokenNotAccepted.selector);
        zap.quoteZapNativeToken(address(weth), 1, 0);

        vm.expectRevert(IUniswapV2ZapErrors.ZeroAmount.selector);
        zap.quoteZapNativeToken(address(tokenA), 0, 0);
    }

    // ----------------------------------------------------------------------------------------
    // zapToken: single-sided, balanced and unbalanced inputs
    // ----------------------------------------------------------------------------------------

    function testZapSingleTokenA() public {
        uint256 liquidityBefore = pairAB.balanceOf(recipient);
        ZapQuote memory quote = zap.quoteZapToken(address(tokenA), address(tokenB), 100 ether, 0);
        _fundUserTokenA(100 ether);

        vm.prank(user);
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            zap.zapToken(_params(address(tokenA), address(tokenB), 100 ether, 0));

        assertGt(amountA, 0, "amountA");
        assertGt(amountB, 0, "amountB");
        assertGt(liquidity, 0, "liquidity");
        assertGt(pairAB.balanceOf(recipient), liquidityBefore, "recipient LP");
        _assertNoTokenDust(address(tokenA), address(tokenB));
        assertEq(
            tokenA.balanceOf(user),
            100 ether - quote.amountAUsed - quote.amountToSwap,
            "only wei-level dust stays with the caller"
        );
        assertEq(tokenB.balanceOf(user), 0, "no tokenB kept");
    }

    function testZapSingleTokenB() public {
        uint256 liquidityBefore = pairAB.balanceOf(recipient);
        ZapQuote memory quote = zap.quoteZapToken(address(tokenA), address(tokenB), 0, 100 ether);
        _fundUserTokenB(100 ether);

        vm.prank(user);
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            zap.zapToken(_params(address(tokenA), address(tokenB), 0, 100 ether));

        assertGt(amountA, 0, "amountA");
        assertGt(amountB, 0, "amountB");
        assertGt(liquidity, 0, "liquidity");
        assertGt(pairAB.balanceOf(recipient), liquidityBefore, "recipient LP");
        _assertNoTokenDust(address(tokenA), address(tokenB));
        assertEq(
            tokenB.balanceOf(user),
            100 ether - quote.amountBUsed - quote.amountToSwap,
            "only wei-level dust stays with the caller"
        );
        assertEq(tokenA.balanceOf(user), 0, "no tokenA kept");
    }

    function testZapUnbalancedTokenPair() public {
        uint256 liquidityBefore = pairAB.balanceOf(recipient);
        _fundUser(200 ether, 10 ether);

        vm.prank(user);
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            zap.zapToken(_params(address(tokenA), address(tokenB), 200 ether, 10 ether));

        assertGt(amountA, 0, "amountA");
        assertGt(amountB, 0, "amountB");
        assertGt(liquidity, 0, "liquidity");
        assertGt(pairAB.balanceOf(recipient), liquidityBefore, "recipient LP");
        _assertNoTokenDust(address(tokenA), address(tokenB));
    }

    // ----------------------------------------------------------------------------------------
    // zapNativeToken: single-sided, balanced and unbalanced inputs
    // ----------------------------------------------------------------------------------------

    function testZapNativeToken() public {
        uint256 liquidityBefore = pairNativeA.balanceOf(recipient);

        vm.prank(user);
        (uint256 amountToken, uint256 amountNative, uint256 liquidity) =
            zap.zapNativeToken{value: 10 ether}(address(tokenA), 0, 1, 1, 1, recipient, block.timestamp + 1);

        assertGt(amountToken, 0, "amountToken");
        assertGt(amountNative, 0, "amountNative");
        assertGt(liquidity, 0, "liquidity");
        assertGt(pairNativeA.balanceOf(recipient), liquidityBefore, "recipient LP");
        // The zap returns the unused wrapped-native as native, so the spend can be off by wei dust.
        assertLe(user.balance, USER_NATIVE_BALANCE - 10 ether + 1, "native spent");
        _assertNoNativeDust();
    }

    function testZapNativeTokenSingleSidedToken() public {
        _fundUserTokenA(100 ether);

        vm.prank(user);
        (uint256 amountToken, uint256 amountNative, uint256 liquidity) =
            zap.zapNativeToken(address(tokenA), 100 ether, 1, 1, 1, recipient, block.timestamp + 1);

        assertGt(amountToken, 0, "amountToken");
        assertGt(amountNative, 0, "amountNative");
        assertGt(liquidity, 0, "liquidity");
        assertEq(user.balance, USER_NATIVE_BALANCE, "no native spent");
        _assertNoNativeDust();
    }

    function testZapNativeTokenUnbalancedInputs() public {
        _fundUserTokenA(200 ether);

        vm.prank(user);
        (,, uint256 liquidity) =
            zap.zapNativeToken{value: 5 ether}(address(tokenA), 200 ether, 1, 1, 1, recipient, block.timestamp + 1);

        assertGt(liquidity, 0, "liquidity");
        _assertNoNativeDust();
    }

    // ----------------------------------------------------------------------------------------
    // Fuzz: the quote must predict the execution exactly
    // ----------------------------------------------------------------------------------------

    function testFuzzQuoteZapTokenMatchesActualForRandomPools(
        uint256 reserveASeed,
        uint256 reserveBSeed,
        uint256 amountASeed,
        uint256 amountBSeed,
        uint8 mode
    ) public {
        MockERC20 tokenX = new MockERC20();
        MockERC20 tokenY = new MockERC20();
        uint256 reserveA = bound(reserveASeed, 1_000 ether, 1_000_000 ether);
        uint256 reserveB = bound(reserveBSeed, 1_000 ether, 1_000_000 ether);
        _seedPair(address(tokenX), address(tokenY), reserveA, reserveB);

        uint256 amountAIn = mode % 3 == 1 ? 0 : bound(amountASeed, 1 ether, reserveA / 2);
        uint256 amountBIn = mode % 3 == 0 ? 0 : bound(amountBSeed, 1 ether, reserveB / 2);

        ZapQuote memory quote = zap.quoteZapToken(address(tokenX), address(tokenY), amountAIn, amountBIn);
        tokenX.mint(user, amountAIn);
        tokenY.mint(user, amountBIn);
        vm.startPrank(user);
        tokenX.approve(address(zap), amountAIn);
        tokenY.approve(address(zap), amountBIn);
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            zap.zapToken(_params(address(tokenX), address(tokenY), amountAIn, amountBIn));
        vm.stopPrank();

        (uint256 reserveAAfter, uint256 reserveBAfter) = _reserves(address(tokenX), address(tokenY));
        assertEq(amountA, quote.amountAUsed, "amount A used");
        assertEq(amountB, quote.amountBUsed, "amount B used");
        assertEq(liquidity, quote.liquidity, "liquidity");
        assertEq(reserveAAfter, quote.reserveAAfter, "reserve A after");
        assertEq(reserveBAfter, quote.reserveBAfter, "reserve B after");
        _assertUserTokenBalancesMatchQuote(tokenX, tokenY, amountAIn, amountBIn, quote);
        _assertNoTokenDust(address(tokenX), address(tokenY));
    }

    function testFuzzQuoteZapNativeTokenMatchesActual(uint256 amountTokenSeed, uint256 amountNativeSeed, uint8 mode)
        public
    {
        uint256 amountTokenIn = mode % 2 == 0 ? 0 : bound(amountTokenSeed, 1 ether, 100 ether);
        uint256 amountNativeIn = mode % 2 == 0 ? bound(amountNativeSeed, 1 ether, 20 ether) : 0;

        ZapNativeQuote memory quote = zap.quoteZapNativeToken(address(tokenA), amountTokenIn, amountNativeIn);

        tokenA.mint(user, amountTokenIn);
        vm.startPrank(user);
        tokenA.approve(address(zap), amountTokenIn);
        (uint256 amountToken, uint256 amountNative, uint256 liquidity) = zap.zapNativeToken{value: amountNativeIn}(
            address(tokenA), amountTokenIn, 1, 1, 1, recipient, block.timestamp + 1
        );
        vm.stopPrank();

        (uint256 reserveNativeAfter, uint256 reserveTokenAfter) = _reserves(address(weth), address(tokenA));
        assertEq(amountToken, quote.amountTokenUsed, "token used");
        assertEq(amountNative, quote.amountNativeUsed, "native used");
        assertEq(liquidity, quote.liquidity, "liquidity");
        assertEq(reserveTokenAfter, quote.reserveTokenAfter, "reserve token after");
        assertEq(reserveNativeAfter, quote.reserveNativeAfter, "reserve native after");
        assertEq(
            tokenA.balanceOf(user),
            amountTokenIn + (quote.swapTokenOut == address(tokenA) ? quote.amountOutFromSwap : 0) - amountToken
                - (quote.swapTokenIn == address(tokenA) ? quote.amountToSwap : 0),
            "user token refund"
        );
        assertEq(
            user.balance,
            USER_NATIVE_BALANCE + (quote.swapTokenOut == address(weth) ? quote.amountOutFromSwap : 0) - amountNative
                - (quote.swapTokenIn == address(weth) ? quote.amountToSwap : 0),
            "user native refund"
        );
        _assertNoNativeDust();
    }

    // ----------------------------------------------------------------------------------------
    // Slippage: a bounded price move passes, a larger one is rejected
    // ----------------------------------------------------------------------------------------

    function testZapTokenAllowsPriceMoveWithinSlippage() public {
        ZapQuote memory quote = zap.quoteZapToken(address(tokenA), address(tokenB), 100 ether, 0);

        _moveTokenPairPriceWithAIn(1 ether);
        _fundUserTokenA(100 ether);

        ZapTokenParams memory params = _params(address(tokenA), address(tokenB), 100 ether, 0);
        params.amountAMin = _minAfterSlippage(quote.amountAUsed, 500);
        params.amountBMin = _minAfterSlippage(quote.amountBUsed, 500);
        params.liquidityMin = _minAfterSlippage(quote.liquidity, 500);

        vm.prank(user);
        (uint256 amountA, uint256 amountB, uint256 liquidity) = zap.zapToken(params);

        assertGe(amountA, params.amountAMin, "amount A slippage");
        assertGe(amountB, params.amountBMin, "amount B slippage");
        assertGe(liquidity, params.liquidityMin, "liquidity slippage");
        _assertNoTokenDust(address(tokenA), address(tokenB));
    }

    function testZapTokenRevertsWhenPriceMoveExceedsSlippage() public {
        ZapQuote memory quote = zap.quoteZapToken(address(tokenA), address(tokenB), 100 ether, 0);

        _moveTokenPairPriceWithAIn(500 ether);
        _fundUserTokenA(100 ether);

        ZapTokenParams memory params = _params(address(tokenA), address(tokenB), 100 ether, 0);
        params.amountAMin = _minAfterSlippage(quote.amountAUsed, 100);
        params.amountBMin = _minAfterSlippage(quote.amountBUsed, 100);
        params.liquidityMin = _minAfterSlippage(quote.liquidity, 100);

        vm.expectRevert();
        vm.prank(user);
        zap.zapToken(params);
    }

    function testZapNativeTokenAllowsPriceMoveWithinSlippage() public {
        ZapNativeQuote memory quote = zap.quoteZapNativeToken(address(tokenA), 0, 10 ether);
        uint256 amountTokenMin = _minAfterSlippage(quote.amountTokenUsed, 500);
        uint256 amountNativeMin = _minAfterSlippage(quote.amountNativeUsed, 500);
        uint256 liquidityMin = _minAfterSlippage(quote.liquidity, 500);

        _moveNativePairPriceWithNativeIn(0.1 ether);

        vm.prank(user);
        (uint256 amountToken, uint256 amountNative, uint256 liquidity) = zap.zapNativeToken{value: 10 ether}(
            address(tokenA), 0, amountTokenMin, amountNativeMin, liquidityMin, recipient, block.timestamp + 1
        );

        assertGe(amountToken, amountTokenMin, "token slippage");
        assertGe(amountNative, amountNativeMin, "native slippage");
        assertGe(liquidity, liquidityMin, "liquidity slippage");
        _assertNoNativeDust();
    }

    function testZapNativeTokenRevertsWhenPriceMoveExceedsSlippage() public {
        ZapNativeQuote memory quote = zap.quoteZapNativeToken(address(tokenA), 0, 10 ether);

        _moveNativePairPriceWithNativeIn(50 ether);

        vm.expectRevert();
        vm.prank(user);
        zap.zapNativeToken{value: 10 ether}(
            address(tokenA),
            0,
            _minAfterSlippage(quote.amountTokenUsed, 100),
            _minAfterSlippage(quote.amountNativeUsed, 100),
            _minAfterSlippage(quote.liquidity, 100),
            recipient,
            block.timestamp + 1
        );
    }

    // ----------------------------------------------------------------------------------------
    // Quote shape and values
    // ----------------------------------------------------------------------------------------

    function testQuoteZapTokenMatchesZapResult() public {
        ZapQuote memory quote = _assertQuoteMatchesZapResult(100 ether, 0);

        assertTrue(quote.hasLiquidity, "has liquidity");
        assertTrue(quote.willSwap, "will swap");
        assertEq(quote.swapTokenIn, address(tokenA), "swap token in");
        assertEq(quote.swapTokenOut, address(tokenB), "swap token out");
        assertGt(quote.amountToSwap, 0, "amount to swap");
        assertGt(quote.amountOutFromSwap, 0, "amount out from swap");
    }

    function testQuoteZapTokenMatchesZapResultWhenSwappingTokenB() public {
        ZapQuote memory quote = _assertQuoteMatchesZapResult(0, 100 ether);

        assertTrue(quote.hasLiquidity, "has liquidity");
        assertTrue(quote.willSwap, "will swap");
        assertEq(quote.swapTokenIn, address(tokenB), "swap token in");
        assertEq(quote.swapTokenOut, address(tokenA), "swap token out");
        assertGt(quote.amountToSwap, 0, "amount to swap");
        assertGt(quote.amountOutFromSwap, 0, "amount out from swap");
    }

    function testQuoteZapTokenUsesAllInputsWhenAlreadyBalanced() public {
        ZapQuote memory quote = _assertQuoteMatchesZapResult(10 ether, 10 ether);

        assertTrue(quote.hasLiquidity, "has liquidity");
        assertFalse(quote.willSwap, "will swap");
        assertEq(quote.amountToSwap, 0, "amount to swap");
        assertEq(quote.amountOutFromSwap, 0, "amount out from swap");
        assertEq(quote.amountAUsed, 10 ether, "amount A used");
        assertEq(quote.amountBUsed, 10 ether, "amount B used");
    }

    function testQuoteZapTokenNewPairMinimumMintableLiquidity() public {
        MockERC20 tokenC = new MockERC20();
        MockERC20 tokenD = new MockERC20();
        _registerPair(address(tokenC), address(tokenD));

        ZapQuote memory quote = zap.quoteZapToken(address(tokenC), address(tokenD), 1_001, 1_001);

        assertFalse(quote.hasLiquidity, "has liquidity");
        assertFalse(quote.willSwap, "will swap");
        assertEq(quote.amountAUsed, 1_001, "amount A used");
        assertEq(quote.amountBUsed, 1_001, "amount B used");
        assertEq(quote.liquidity, 1, "liquidity");
        assertEq(quote.reserveAAfter, 1_001, "reserve A after");
        assertEq(quote.reserveBAfter, 1_001, "reserve B after");

        _fundUserTokens(tokenC, tokenD, 1_001, 1_001);
        vm.prank(user);
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            zap.zapToken(_params(address(tokenC), address(tokenD), 1_001, 1_001));

        assertEq(amountA, quote.amountAUsed, "amount A used after zap");
        assertEq(amountB, quote.amountBUsed, "amount B used after zap");
        assertEq(liquidity, 1, "minimum LP minted");
    }

    function testQuoteZapTokenUsesCallerTokenOrder() public view {
        ZapQuote memory quote = zap.quoteZapToken(address(tokenB), address(tokenA), 100 ether, 0);

        assertTrue(quote.hasLiquidity, "has liquidity");
        assertTrue(quote.willSwap, "will swap");
        assertEq(quote.swapTokenIn, address(tokenB), "swap token in");
        assertEq(quote.swapTokenOut, address(tokenA), "swap token out");
        assertGt(quote.reserveAAfter, 0, "reserve A after");
        assertGt(quote.reserveBAfter, 0, "reserve B after");
    }

    function testQuoteZapNativeTokenUsesWrappedNativeAsTokenA() public view {
        ZapNativeQuote memory quote = zap.quoteZapNativeToken(address(tokenA), 0, 10 ether);

        assertTrue(quote.hasLiquidity, "has liquidity");
        assertTrue(quote.willSwap, "will swap");
        assertEq(quote.swapTokenIn, address(weth), "swap token in");
        assertEq(quote.swapTokenOut, address(tokenA), "swap token out");
        assertGt(quote.amountNativeUsed, 0, "native used");
        assertGt(quote.amountTokenUsed, 0, "token used");
    }

    function testQuoteZapNativeTokenLiquidityMatchesZapResult() public {
        ZapNativeQuote memory quote = zap.quoteZapNativeToken(address(tokenA), 0, 10 ether);

        vm.prank(user);
        (uint256 amountToken, uint256 amountNative, uint256 liquidity) =
            zap.zapNativeToken{value: 10 ether}(address(tokenA), 0, 1, 1, 1, recipient, block.timestamp + 1);

        assertEq(amountToken, quote.amountTokenUsed, "token used");
        assertEq(amountNative, quote.amountNativeUsed, "native used");
        assertEq(liquidity, quote.liquidity, "liquidity");
    }

    // ----------------------------------------------------------------------------------------
    // Protocol fee (feeTo / kLast) branch of the total-supply projection
    // ----------------------------------------------------------------------------------------

    function testQuoteZapTokenLiquidityMatchesZapResultWhenFeeOn() public {
        factory.setFeeTo(address(0xfee));
        _fundUser(10 ether, 10 ether);
        vm.prank(user);
        zap.zapToken(_params(address(tokenA), address(tokenB), 10 ether, 10 ether));

        // Grow sqrt(k) without moving the baseline: this is the state in which the pair mints the
        // protocol fee on its next liquidity event.
        tokenA.mint(address(pairAB), 100 ether);
        pairAB.addToReserve(address(tokenA), 100 ether);
        assertGt(pairAB.pendingFeeLiquidity(address(0xfee)), 0, "pending protocol fee");

        ZapQuote memory quote = zap.quoteZapToken(address(tokenA), address(tokenB), 10 ether, 0);
        _fundUserTokenA(10 ether);

        vm.prank(user);
        (,, uint256 liquidity) = zap.zapToken(_params(address(tokenA), address(tokenB), 10 ether, 0));

        assertEq(liquidity, quote.liquidity, "liquidity");
    }

    function testQuoteZapTokenFeeOnWithoutGrowthDoesNotMintProtocolFee() public {
        factory.setFeeTo(address(0xfee));

        // feeTo set, kLast still zero: no liquidity event since feeTo was turned on.
        assertEq(pairAB.kLast(), 0, "kLast");
        ZapQuote memory zeroKLastQuote = zap.quoteZapToken(address(tokenA), address(tokenB), 10 ether, 10 ether);
        assertEq(zeroKLastQuote.liquidity, 10 ether, "zero kLast liquidity");

        // kLast set but sqrt(k) has not grown: no protocol fee either.
        _fundUser(10 ether, 10 ether);
        vm.prank(user);
        zap.zapToken(_params(address(tokenA), address(tokenB), 10 ether, 10 ether));
        assertEq(pairAB.pendingFeeLiquidity(address(0xfee)), 0, "no pending fee");

        ZapQuote memory noGrowthQuote = zap.quoteZapToken(address(tokenA), address(tokenB), 10 ether, 10 ether);
        assertEq(noGrowthQuote.liquidity, 10 ether, "no growth liquidity");
    }

    function testQuoteZapTokenFeeOnGrowthInflatesTheProjectedSupply() public {
        factory.setFeeTo(address(0xfee));
        _fundUser(10 ether, 10 ether);
        vm.prank(user);
        zap.zapToken(_params(address(tokenA), address(tokenB), 10 ether, 10 ether));

        tokenA.mint(address(pairAB), 100 ether);
        pairAB.addToReserve(address(tokenA), 100 ether);

        ZapQuote memory withFee = zap.quoteZapToken(address(tokenA), address(tokenB), 10 ether, 0);

        factory.setFeeTo(address(0));
        ZapQuote memory withoutFee = zap.quoteZapToken(address(tokenA), address(tokenB), 10 ether, 0);

        assertGt(withFee.liquidity, withoutFee.liquidity, "projected supply includes the protocol fee");
    }

    // ----------------------------------------------------------------------------------------
    // Internal swap-amount formula precision
    // ----------------------------------------------------------------------------------------

    function testQuoteZapTokenSingleSidedSmallPoolUsesFormulaPrecision() public {
        uint256 reserveA = 2_857_911_946_302;
        uint256 reserveB = 2_330_969_554_244_432_846;
        uint256 amountBIn = 6_992_700_000_000_000_000;

        MockERC20 tokenC = new MockERC20();
        MockERC20 tokenD = new MockERC20();
        _seedPair(address(tokenC), address(tokenD), reserveA, reserveB);

        MockUniswapV2Pair pair = MockUniswapV2Pair(factory.getPair(address(tokenC), address(tokenD)));
        uint256 expectedSwap = _formulaSwapAmount(reserveB, reserveA, amountBIn, 0);
        uint256 expectedAmountOut = router.getAmountOut(expectedSwap, reserveB, reserveA);
        uint256 expectedLiquidity = (expectedAmountOut * pair.totalSupply()) / (reserveA - expectedAmountOut);

        ZapQuote memory quote = zap.quoteZapToken(address(tokenC), address(tokenD), 0, amountBIn);

        assertEq(quote.amountToSwap, expectedSwap, "amount to swap");
        assertEq(quote.amountOutFromSwap, expectedAmountOut, "amount out");
        assertEq(quote.liquidity, expectedLiquidity, "liquidity");
    }

    function testQuoteZapTokenUnbalancedPairUsesFormulaPrecision() public view {
        uint256 amountAIn = 200 ether;
        uint256 amountBIn = 10 ether;
        uint256 expectedSwap = _formulaSwapAmount(SEED_LIQUIDITY, SEED_LIQUIDITY, amountAIn, amountBIn);
        uint256 expectedAmountOut = router.getAmountOut(expectedSwap, SEED_LIQUIDITY, SEED_LIQUIDITY);

        ZapQuote memory quote = zap.quoteZapToken(address(tokenA), address(tokenB), amountAIn, amountBIn);

        assertEq(quote.amountToSwap, expectedSwap, "amount to swap");
        assertEq(quote.amountOutFromSwap, expectedAmountOut, "amount out");
    }

    // ----------------------------------------------------------------------------------------
    // Quote failures: one case per reachable error
    // ----------------------------------------------------------------------------------------

    function testQuoteZapTokenRevertsWhenAmountAExceeded() public {
        uint256 maxAmount = uint256(type(uint112).max);
        uint256 amount = maxAmount + 1;

        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV2ZapErrors.AmountExceeded.selector, amount, maxAmount)
        );
        zap.quoteZapToken(address(tokenA), address(tokenB), amount, 0);

        // Validation order is tokenA then tokenB, so with both amounts over the limit the payload
        // names tokenA's amount (both are reported through the same payload shape).
        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV2ZapErrors.AmountExceeded.selector, amount, maxAmount)
        );
        zap.quoteZapToken(address(tokenA), address(tokenB), amount, amount + 1);
    }

    function testQuoteZapTokenRevertsWhenAmountBExceeded() public {
        uint256 maxAmount = uint256(type(uint112).max);
        uint256 amount = maxAmount + 1;

        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV2ZapErrors.AmountExceeded.selector, amount, maxAmount)
        );
        zap.quoteZapToken(address(tokenA), address(tokenB), 0, amount);
    }

    function testQuoteZapTokenRevertsWhenNewPairInputCannotMintLiquidity() public {
        MockERC20 tokenC = new MockERC20();
        MockERC20 tokenD = new MockERC20();
        _registerPair(address(tokenC), address(tokenD));

        vm.expectRevert(IUniswapV2ZapErrors.InsufficientInitialLiquidity.selector);
        zap.quoteZapToken(address(tokenC), address(tokenD), 1, 1);
    }

    function testQuoteZapTokenRevertsWhenOptimalAmountIsZero() public {
        MockERC20 tokenC = new MockERC20();
        MockERC20 tokenD = new MockERC20();
        _seedPairAtRawAmounts(address(tokenC), address(tokenD), 1e30, 1e30, 1);

        vm.expectRevert(IUniswapV2ZapErrors.OptimalAmountZero.selector);
        zap.quoteZapToken(address(tokenC), address(tokenD), 1, 0);
    }

    function testQuoteZapTokenRevertsWhenSwapOutputIsZero() public {
        MockERC20 tokenC = new MockERC20();
        MockERC20 tokenD = new MockERC20();
        (address token0, address token1) = _sorted(address(tokenC), address(tokenD));
        _seedPairAtRawAmounts(token0, token1, 1e30, 1, 1);

        vm.expectRevert(IUniswapV2ZapErrors.SwapOutputZero.selector);
        zap.quoteZapToken(token0, token1, 1e30, 0);
    }

    function testQuoteZapTokenRevertsWhenLiquidityMintedIsZero() public {
        MockERC20 tokenC = new MockERC20();
        MockERC20 tokenD = new MockERC20();
        _seedPairAtRawAmounts(address(tokenC), address(tokenD), 1e30, 1e30, 1);

        vm.expectRevert(IUniswapV2ZapErrors.LiquidityMintedZero.selector);
        zap.quoteZapToken(address(tokenC), address(tokenD), 1e30 - 1, 0);
    }

    function testQuoteZapTokenHandlesMalformedPairStates() public {
        MockERC20 tokenC = new MockERC20();
        MockERC20 tokenD = new MockERC20();
        _registerPair(address(tokenC), address(tokenD));
        vm.expectRevert(IUniswapV2ZapErrors.PairMissingOrEmpty.selector);
        zap.quoteZapToken(address(tokenC), address(tokenD), 1, 0);

        // Pair deployed but never synced: both reserves still zero.
        MockERC20 tokenE = new MockERC20();
        MockERC20 tokenF = new MockERC20();
        _registerPair(address(tokenE), address(tokenF));
        vm.expectRevert(IUniswapV2ZapErrors.PairMissingOrEmpty.selector);
        zap.quoteZapToken(address(tokenE), address(tokenF), 1 ether, 0);

        // Only one reserve funded: `hasLiquidity` is true but the swap math divides by zero.
        MockERC20 tokenG = new MockERC20();
        MockERC20 tokenH = new MockERC20();
        (address token0, address token1) = _sorted(address(tokenG), address(tokenH));
        _seedPairAtRawAmounts(token0, token1, 1 ether, 0, 1);
        vm.expectRevert(IUniswapV2ZapErrors.InsufficientLiquidity.selector);
        zap.quoteZapToken(token0, token1, 1 ether, 0);

        // And a synced pair at the minimum seed still quotes one wei of liquidity: with totalSupply
        // at zero the quote falls back to sqrt(k) - MINIMUM_LIQUIDITY.
        MockERC20 tokenI = new MockERC20();
        MockERC20 tokenJ = new MockERC20();
        _seedPairAtRawAmounts(address(tokenI), address(tokenJ), 1_001, 1_001, 0);
        assertEq(zap.quoteZapToken(address(tokenI), address(tokenJ), 1_001, 1_001).liquidity, 1, "liquidity");
    }

    /// @dev The ratio-mismatch error that `_calcAmountToSwap` used to raise is deleted: it was
    /// unreachable, because both call sites pick the swap direction with the same comparison the
    /// guard re-checked (`error-standards` §8: no unreachable errors). The selector is kept as a
    /// literal so the probe does not depend on a declaration that no longer exists; it is the
    /// `cast sig` of the deleted no-argument signature, recorded in the README's ABI-diff table.
    function testQuoteZapTokenNeverRevertsWithTheRetiredRatioSelector() public view {
        uint256[7] memory amounts = [uint256(1), 1e3, 1e6, 1e12, 1e17, 1e21, 1e23];
        uint256 reverts;

        for (uint256 i = 0; i < amounts.length; i++) {
            for (uint256 j = 0; j < amounts.length; j++) {
                reverts += _expectNoRetiredRatioSelector(amounts[i], amounts[j]);
                reverts += _expectNoRetiredRatioSelector(amounts[i], 0);
                reverts += _expectNoRetiredRatioSelector(amounts[j], amounts[i]);
            }
        }

        assertGt(reverts, 0, "the probe must actually exercise failing quotes");
    }

    function _expectNoRetiredRatioSelector(uint256 amountAIn, uint256 amountBIn)
        internal
        view
        returns (uint256 reverted)
    {
        try zap.quoteZapToken(address(tokenA), address(tokenB), amountAIn, amountBIn) returns (ZapQuote memory) {}
        catch (bytes memory reason) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 32))
            }
            // No quote may ever raise it — that is what "the error was unreachable" means. A revert
            // re-introduced under that selector, from any direction-selection regression, fails here.
            assertTrue(selector != RETIRED_RATIO_ERROR_SELECTOR, "retired ratio error reached");
            reverted = 1;
        }
    }

    // ----------------------------------------------------------------------------------------
    // Zap-side failures: router failures, approval failures and slippage
    // ----------------------------------------------------------------------------------------

    function testZapTokenRevertsWhenAddLiquidityReverts() public {
        _fundUserTokenA(100 ether);
        router.setAddLiquidityRevert(true, "MOCK_ADD_LIQUIDITY_REVERT");

        vm.expectRevert("MOCK_ADD_LIQUIDITY_REVERT");
        vm.prank(user);
        zap.zapToken(_params(address(tokenA), address(tokenB), 100 ether, 0));
    }

    function testZapTokenRevertsWhenSwapReverts() public {
        _fundUserTokenA(100 ether);
        router.setSwapRevert(true, "MOCK_SWAP_REVERT");

        vm.expectRevert("MOCK_SWAP_REVERT");
        vm.prank(user);
        zap.zapToken(_params(address(tokenA), address(tokenB), 100 ether, 0));
    }

    function testZapTokenRevertsWhenApprovalFails() public {
        _fundUserTokenA(100 ether);
        tokenA.setApproveReverts(true);

        vm.expectRevert("MOCK_APPROVE");
        vm.prank(user);
        zap.zapToken(_params(address(tokenA), address(tokenB), 100 ether, 0));
    }

    function testZapTokenRevertsWhenLiquidityMinNotMet() public {
        _fundUserTokenA(100 ether);
        uint256 expectedLiquidity = zap.quoteZapToken(address(tokenA), address(tokenB), 100 ether, 0).liquidity;

        ZapTokenParams memory params = _params(address(tokenA), address(tokenB), 100 ether, 0);
        params.liquidityMin = type(uint256).max;

        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV2ZapErrors.SlippageExceeded.selector, expectedLiquidity, type(uint256).max)
        );
        vm.prank(user);
        zap.zapToken(params);
    }

    function testZapTokenRevertsWhenRouterMintsLessThanPromised() public {
        _fundUserTokenA(100 ether);

        ZapTokenParams memory params = _params(address(tokenA), address(tokenB), 100 ether, 0);
        params.liquidityMin = 1 ether;
        router.setLiquidityMintedOverride(true, 1 ether - 1);

        vm.expectRevert(abi.encodeWithSelector(IUniswapV2ZapErrors.SlippageExceeded.selector, 1 ether - 1, 1 ether));
        vm.prank(user);
        zap.zapToken(params);
    }

    function testZapNativeTokenRevertsWhenLiquidityMinNotMet() public {
        uint256 expectedLiquidity = zap.quoteZapNativeToken(address(tokenA), 0, 10 ether).liquidity;

        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV2ZapErrors.SlippageExceeded.selector, expectedLiquidity, type(uint256).max)
        );
        vm.prank(user);
        zap.zapNativeToken{value: 10 ether}(
            address(tokenA), 0, 1, 1, type(uint256).max, recipient, block.timestamp + 1
        );
    }

    function testZapTokenRevertsWhenAmountAMinNotMet() public {
        ZapQuote memory quote = zap.quoteZapToken(address(tokenA), address(tokenB), 100 ether, 0);
        _fundUserTokenA(100 ether);

        ZapTokenParams memory params = _params(address(tokenA), address(tokenB), 100 ether, 0);
        params.amountAMin = quote.amountAUsed + 1;

        vm.expectRevert("UniswapV2Router: INSUFFICIENT_A_AMOUNT");
        vm.prank(user);
        zap.zapToken(params);
    }

    function testZapTokenRevertsWhenAmountBMinNotMet() public {
        _fundUser(10 ether, 10 ether);

        ZapTokenParams memory params = _params(address(tokenA), address(tokenB), 10 ether, 10 ether);
        params.amountBMin = type(uint256).max;

        vm.expectRevert("UniswapV2Router: INSUFFICIENT_B_AMOUNT");
        vm.prank(user);
        zap.zapToken(params);
    }

    function testZapNativeTokenRevertsWhenTokenAmountMinNotMet() public {
        _fundUserTokenA(100 ether);

        // In the native pair the ERC20 is tokenB, so its minimum surfaces as the B-side error.
        vm.expectRevert("UniswapV2Router: INSUFFICIENT_B_AMOUNT");
        vm.prank(user);
        zap.zapNativeToken{value: 10 ether}(
            address(tokenA), 100 ether, type(uint256).max, 1, 1, recipient, block.timestamp + 1
        );
    }

    function testExpiredDeadlineReverts() public {
        _fundUserTokenA(100 ether);

        ZapTokenParams memory params = _params(address(tokenA), address(tokenB), 100 ether, 0);
        params.deadline = block.timestamp - 1;

        vm.expectRevert("UniswapV2Router: EXPIRED");
        vm.prank(user);
        zap.zapToken(params);
    }

    // ----------------------------------------------------------------------------------------
    // Refunds, dust and pre-existing balances
    // ----------------------------------------------------------------------------------------

    function testZapTokenDoesNotRefundExistingBalances() public {
        uint256 existingA = 7 ether;
        uint256 existingB = 3 ether;
        tokenA.mint(address(zap), existingA);
        tokenB.mint(address(zap), existingB);
        _fundUserTokenA(100 ether);

        vm.prank(user);
        zap.zapToken(_params(address(tokenA), address(tokenB), 100 ether, 0));

        assertEq(tokenA.balanceOf(address(zap)), existingA, "existing tokenA stays");
        assertEq(tokenB.balanceOf(address(zap)), existingB, "existing tokenB stays");
    }

    function testZapNativeTokenDoesNotRefundExistingBalances() public {
        uint256 existingToken = 7 ether;
        uint256 existingWrappedNative = 3 ether;
        tokenA.mint(address(zap), existingToken);
        weth.deposit{value: existingWrappedNative}();
        weth.transfer(address(zap), existingWrappedNative);

        vm.prank(user);
        zap.zapNativeToken{value: 10 ether}(address(tokenA), 0, 1, 1, 1, recipient, block.timestamp + 1);

        assertEq(tokenA.balanceOf(address(zap)), existingToken, "existing token stays");
        assertEq(weth.balanceOf(address(zap)), existingWrappedNative, "existing wrapped native stays");
    }

    function testZapTokenRefundsUnusedInput() public {
        ZapQuote memory quote = zap.quoteZapToken(address(tokenA), address(tokenB), 200 ether, 10 ether);
        _fundUser(200 ether, 10 ether);

        vm.prank(user);
        zap.zapToken(_params(address(tokenA), address(tokenB), 200 ether, 10 ether));

        _assertUserTokenBalancesMatchQuote(tokenA, tokenB, 200 ether, 10 ether, quote);
        _assertNoTokenDust(address(tokenA), address(tokenB));
    }

    function testZapNativeTokenRefundsUnusedInputs() public {
        uint256 nativeBefore = user.balance;
        ZapNativeQuote memory quote = zap.quoteZapNativeToken(address(tokenA), 200 ether, 5 ether);
        _fundUserTokenA(200 ether);

        vm.prank(user);
        zap.zapNativeToken{value: 5 ether}(address(tokenA), 200 ether, 1, 1, 1, recipient, block.timestamp + 1);

        // Conservation over both legs: the amount used plus the swap leg must equal what left the
        // caller. The zap keeps nothing, so whatever was not used came straight back.
        assertEq(
            user.balance,
            nativeBefore + (quote.swapTokenOut == address(weth) ? quote.amountOutFromSwap : 0)
                - quote.amountNativeUsed - (quote.swapTokenIn == address(weth) ? quote.amountToSwap : 0),
            "native refund"
        );
        assertEq(
            tokenA.balanceOf(user),
            200 ether + (quote.swapTokenOut == address(tokenA) ? quote.amountOutFromSwap : 0)
                - quote.amountTokenUsed - (quote.swapTokenIn == address(tokenA) ? quote.amountToSwap : 0),
            "token refund"
        );
        _assertNoNativeDust();
    }

    // ----------------------------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------------------------

    function testZapTokenEmitsEvent() public {
        ZapQuote memory quote = zap.quoteZapToken(address(tokenA), address(tokenB), 100 ether, 0);
        _fundUserTokenA(100 ether);

        vm.expectEmit(true, true, true, true, address(zap));
        emit TokenZapped({
            sender: user,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            to: recipient,
            amountA: quote.amountAUsed,
            amountB: quote.amountBUsed,
            liquidity: quote.liquidity
        });

        vm.prank(user);
        zap.zapToken(_params(address(tokenA), address(tokenB), 100 ether, 0));
    }

    function testZapNativeTokenEmitsEvent() public {
        ZapNativeQuote memory quote = zap.quoteZapNativeToken(address(tokenA), 0, 10 ether);

        vm.expectEmit(true, true, true, true, address(zap));
        emit NativeTokenZapped({
            sender: user,
            tokenAddress: address(tokenA),
            to: recipient,
            amountToken: quote.amountTokenUsed,
            amountNative: quote.amountNativeUsed,
            liquidity: quote.liquidity
        });

        vm.prank(user);
        zap.zapNativeToken{value: 10 ether}(address(tokenA), 0, 1, 1, 1, recipient, block.timestamp + 1);
    }

    // ----------------------------------------------------------------------------------------
    // Native refund failure and missing pairs
    // ----------------------------------------------------------------------------------------

    function testZapNativeTokenRevertsWhenNativeRefundFails() public {
        RejectNativeZapCaller caller = new RejectNativeZapCaller(zap);

        vm.expectRevert(IUniswapV2ZapErrors.NativeTransferFailed.selector);
        caller.zapNativeToken{value: 10 ether}(address(tokenA), recipient, block.timestamp + 1);
    }

    function testPairNotFoundSingleTokenReverts() public {
        MockERC20 tokenC = new MockERC20();
        MockERC20 tokenD = new MockERC20();
        _fundUserTokens(tokenC, tokenD, 100 ether, 0);

        vm.expectRevert(IUniswapV2ZapErrors.PairMissingOrEmpty.selector);
        vm.prank(user);
        zap.zapToken(_params(address(tokenC), address(tokenD), 100 ether, 0));
    }

    function testPairNotFoundDualTokenCreatesPair() public {
        MockERC20 tokenC = new MockERC20();
        MockERC20 tokenD = new MockERC20();
        _fundUserTokens(tokenC, tokenD, 100 ether, 200 ether);

        vm.prank(user);
        zap.zapToken(_params(address(tokenC), address(tokenD), 100 ether, 200 ether));

        address created = factory.getPair(address(tokenC), address(tokenD));
        assertTrue(created != address(0), "pair created");
        assertGt(MockUniswapV2Pair(created).balanceOf(recipient), 0, "recipient LP");
        _assertNoTokenDust(address(tokenC), address(tokenD));
    }

    // ----------------------------------------------------------------------------------------
    // Admin surface
    // ----------------------------------------------------------------------------------------

    function testNoAdminFunctions() public {
        _assertNoSelector("owner()");
        _assertNoSelector("pause()");
        _assertNoSelector("recover(address,uint256)");
        _assertNoSelector("admin()");
    }

    // ----------------------------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------------------------

    function _params(address tokenA_, address tokenB_, uint256 amountAIn, uint256 amountBIn)
        internal
        view
        returns (ZapTokenParams memory)
    {
        return ZapTokenParams({
            tokenA: tokenA_,
            tokenB: tokenB_,
            amountAIn: amountAIn,
            amountBIn: amountBIn,
            amountAMin: 1,
            amountBMin: 1,
            liquidityMin: 1,
            to: recipient,
            deadline: block.timestamp + 1
        });
    }

    function _sorted(address token0, address token1) internal pure returns (address, address) {
        return token0 < token1 ? (token0, token1) : (token1, token0);
    }

    function _registerPair(address tokenA_, address tokenB_) internal returns (MockUniswapV2Pair) {
        (address first, address second) = _sorted(tokenA_, tokenB_);
        MockUniswapV2Pair created = new MockUniswapV2Pair(first, second);
        factory.setPair(first, second, address(created));
        return created;
    }

    /// @dev Seeds through the real router, so reserves, totalSupply and kLast are exactly what a real
    /// first `mint` would leave behind.
    function _seedPair(address tokenA_, address tokenB_, uint256 amountA, uint256 amountB)
        internal
        returns (MockUniswapV2Pair)
    {
        _registerPair(tokenA_, tokenB_);
        MockERC20(tokenA_).mint(address(this), amountA);
        MockERC20(tokenB_).mint(address(this), amountB);
        MockERC20(tokenA_).approve(address(router), amountA);
        MockERC20(tokenB_).approve(address(router), amountB);
        router.addLiquidity(tokenA_, tokenB_, amountA, amountB, 1, 1, address(this), block.timestamp + 1);
        return MockUniswapV2Pair(factory.getPair(tokenA_, tokenB_));
    }

    /// @dev Forces an arbitrary pair state (reserves, supply, kLast) without going through the
    /// router: used for the malformed-pool and truncation cases.
    function _seedPairAtRawAmounts(address token0, address token1, uint256 reserve0, uint256 reserve1, uint256 supply)
        internal
        returns (MockUniswapV2Pair pair)
    {
        pair = _registerPair(token0, token1);
        MockERC20(token0).mint(address(pair), reserve0);
        MockERC20(token1).mint(address(pair), reserve1);

        (uint112 stored0, uint112 stored1) =
            pair.token0() == token0 ? (uint112(reserve0), uint112(reserve1)) : (uint112(reserve1), uint112(reserve0));
        pair.seed(stored0, stored1, supply, false);
    }

    function _seedNativePair(address token, uint256 nativeAmount, uint256 tokenAmount)
        internal
        returns (MockUniswapV2Pair)
    {
        // `_seedPair` mints the input tokens it needs, so no deposit is made here: the wrapped-native
        // balance comes from `MockERC20.mint` like any other ERC20.
        return _seedPair(address(weth), token, nativeAmount, tokenAmount);
    }

    function _fundUser(uint256 amountA, uint256 amountB) internal {
        if (amountA > 0) {
            tokenA.mint(user, amountA);
            vm.prank(user);
            tokenA.approve(address(zap), amountA);
        }
        if (amountB > 0) {
            tokenB.mint(user, amountB);
            vm.prank(user);
            tokenB.approve(address(zap), amountB);
        }
    }

    function _fundUserTokenA(uint256 amount) internal {
        tokenA.mint(user, amount);
        vm.prank(user);
        tokenA.approve(address(zap), amount);
    }

    function _fundUserTokenB(uint256 amount) internal {
        tokenB.mint(user, amount);
        vm.prank(user);
        tokenB.approve(address(zap), amount);
    }

    function _fundUserTokens(MockERC20 token0, MockERC20 token1, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            token0.mint(user, amount0);
            vm.prank(user);
            token0.approve(address(zap), amount0);
        }
        if (amount1 > 0) {
            token1.mint(user, amount1);
            vm.prank(user);
            token1.approve(address(zap), amount1);
        }
    }

    function _reserves(address token0, address token1) internal view returns (uint256, uint256) {
        MockUniswapV2Pair pair = MockUniswapV2Pair(factory.getPair(token0, token1));
        (uint112 reserveA, uint112 reserveB,) = pair.getReserves();
        return token0 == pair.token0()
            ? (uint256(reserveA), uint256(reserveB))
            : (uint256(reserveB), uint256(reserveA));
    }

    function _assertQuoteMatchesZapResult(uint256 amountAIn, uint256 amountBIn)
        internal
        returns (ZapQuote memory quote)
    {
        (uint256 reserveABefore, uint256 reserveBBefore) = _reserves(address(tokenA), address(tokenB));
        quote = zap.quoteZapToken(address(tokenA), address(tokenB), amountAIn, amountBIn);

        if (quote.willSwap) {
            if (quote.swapTokenIn == address(tokenA)) {
                assertEq(
                    quote.amountOutFromSwap,
                    router.getAmountOut(quote.amountToSwap, reserveABefore, reserveBBefore),
                    "router amount out"
                );
            } else {
                assertEq(
                    quote.amountOutFromSwap,
                    router.getAmountOut(quote.amountToSwap, reserveBBefore, reserveABefore),
                    "router amount out"
                );
            }
        }

        _fundUser(amountAIn, amountBIn);

        vm.prank(user);
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            zap.zapToken(_params(address(tokenA), address(tokenB), amountAIn, amountBIn));

        (uint256 reserveA, uint256 reserveB) = _reserves(address(tokenA), address(tokenB));
        assertEq(amountA, quote.amountAUsed, "amount A used");
        assertEq(amountB, quote.amountBUsed, "amount B used");
        assertEq(liquidity, quote.liquidity, "liquidity");
        assertEq(reserveA, quote.reserveAAfter, "reserve A after");
        assertEq(reserveB, quote.reserveBAfter, "reserve B after");
        _assertNoTokenDust(address(tokenA), address(tokenB));
    }

    function _assertUserTokenBalancesMatchQuote(
        MockERC20 token0,
        MockERC20 token1,
        uint256 amount0In,
        uint256 amount1In,
        ZapQuote memory quote
    ) internal view {
        assertEq(
            token0.balanceOf(user),
            amount0In + (quote.swapTokenOut == address(token0) ? quote.amountOutFromSwap : 0) - quote.amountAUsed
                - (quote.swapTokenIn == address(token0) ? quote.amountToSwap : 0),
            "user token0 refund"
        );
        assertEq(
            token1.balanceOf(user),
            amount1In + (quote.swapTokenOut == address(token1) ? quote.amountOutFromSwap : 0) - quote.amountBUsed
                - (quote.swapTokenIn == address(token1) ? quote.amountToSwap : 0),
            "user token1 refund"
        );
    }

    function _assertNoTokenDust(address token0, address token1) internal view {
        assertEq(IERC20(token0).balanceOf(address(zap)), 0, "zap token0 dust");
        assertEq(IERC20(token1).balanceOf(address(zap)), 0, "zap token1 dust");
    }

    function _assertNoNativeDust() internal view {
        assertEq(tokenA.balanceOf(address(zap)), 0, "zap token dust");
        assertEq(weth.balanceOf(address(zap)), 0, "zap weth dust");
        assertEq(address(zap).balance, 0, "zap eth dust");
    }

    function _moveTokenPairPriceWithAIn(uint256 amountAIn) internal {
        tokenA.mint(address(this), amountAIn);
        tokenA.approve(address(router), amountAIn);
        _swap(address(tokenA), address(tokenB), amountAIn);
    }

    function _moveNativePairPriceWithNativeIn(uint256 amountNativeIn) internal {
        weth.deposit{value: amountNativeIn}();
        weth.approve(address(router), amountNativeIn);
        _swap(address(weth), address(tokenA), amountNativeIn);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        router.swapExactTokensForTokens(amountIn, 0, path, address(this), block.timestamp + 1);
    }

    function _minAfterSlippage(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * (10_000 - bps)) / 10_000;
    }

    function _sendNativeToZap(address target, uint256 amount) internal {
        (bool success, bytes memory revertData) = target.call{value: amount}("");
        if (!success) {
            assembly {
                revert(add(revertData, 32), mload(revertData))
            }
        }
    }

    function _assertNoSelector(string memory signature) internal {
        (bool success,) = address(zap).call(abi.encodeWithSignature(signature));
        assertFalse(success, signature);
    }

    function _formulaSwapAmount(uint256 reserveIn, uint256 reserveOut, uint256 amountIn, uint256 amountOutAlready)
        internal
        pure
        returns (uint256)
    {
        uint256 imbalance = amountIn * reserveOut - reserveIn * amountOutAlready;
        uint256 denominator = reserveOut + amountOutAlready;
        return (
            Math.sqrt(reserveIn * reserveIn * 3_988_009 + (reserveIn * imbalance * 3_988_000) / denominator)
                - reserveIn * 1_997
        ) / 1_994;
    }
}

contract RejectNativeZapCaller {
    UniswapV2Zap public immutable zap;

    constructor(UniswapV2Zap zap_) {
        zap = zap_;
    }

    function zapNativeToken(address token, address to, uint256 deadline) external payable {
        zap.zapNativeToken{value: msg.value}(token, 0, 1, 1, 1, to, deadline);
    }

    receive() external payable {
        revert("NATIVE_REJECTED");
    }
}
