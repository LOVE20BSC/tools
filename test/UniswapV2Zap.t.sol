// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {UniswapV2Zap} from "../src/UniswapV2Zap.sol";
import {IUniswapV2ZapErrors, ZapTokenParams} from "../src/interfaces/IUniswapV2Zap.sol";
import {
    MockERC20,
    MockUniswapV2Factory,
    MockUniswapV2Pair,
    MockUniswapV2Router02,
    MockWrappedNative
} from "./mocks/ZapMocks.sol";

contract UniswapV2ZapTest is Test, IUniswapV2ZapErrors {
    UniswapV2Zap internal zap;
    MockUniswapV2Router02 internal router;
    MockUniswapV2Factory internal factory;
    MockWrappedNative internal weth;
    MockERC20 internal token;
    MockUniswapV2Pair internal pair;

    address internal user = address(0x1234);
    address internal recipient = address(0x5678);

    uint256 internal constant INITIAL_LIQUIDITY = 1_000 ether;
    uint256 internal constant ZAP_AMOUNT = 10 ether;

    receive() external payable {}

    function setUp() public {
        weth = new MockWrappedNative();
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router02(address(factory), address(weth));
        zap = new UniswapV2Zap(address(router));

        token = new MockERC20();
        pair = _createPair(address(weth), address(token));

        vm.deal(address(this), INITIAL_LIQUIDITY);
        weth.deposit{value: INITIAL_LIQUIDITY}();
        weth.transfer(address(pair), INITIAL_LIQUIDITY);
        token.mint(address(pair), INITIAL_LIQUIDITY);
        pair.addToReserve(address(weth), INITIAL_LIQUIDITY);
        pair.addToReserve(address(token), INITIAL_LIQUIDITY);
        pair.setTotalSupply(INITIAL_LIQUIDITY);

        vm.deal(user, 100 ether);
    }

    function testConstructorBindsRouterFactoryAndWrappedNative() public view {
        assertEq(address(zap.router()), address(router));
        assertEq(zap.factory(), address(factory));
        assertEq(zap.wrappedNativeToken(), address(weth));
    }

    function testConstructorRevertsForZeroRouter() public {
        vm.expectRevert(ZeroRouter.selector);
        new UniswapV2Zap(address(0));
    }

    function testReceiveRejectsNonWrappedNative() public {
        vm.deal(address(this), 1 ether);

        vm.expectRevert(NativeTokenNotAccepted.selector);
        _sendNativeToZap(1 ether);

        assertEq(address(zap).balance, 0);
    }

    function testZapTokenAddsLiquidity() public {
        vm.deal(address(this), ZAP_AMOUNT);
        token.mint(user, 100 ether);
        weth.deposit{value: ZAP_AMOUNT}();
        weth.transfer(user, ZAP_AMOUNT);

        vm.startPrank(user);
        token.approve(address(zap), 100 ether);
        weth.approve(address(zap), ZAP_AMOUNT);
        vm.stopPrank();

        uint256 pairSupplyBefore = pair.totalSupply();

        vm.prank(user);
        (uint256 amountA, uint256 amountB, uint256 liquidity) = zap.zapToken(
            ZapTokenParams({
                tokenA: address(weth),
                tokenB: address(token),
                amountAIn: ZAP_AMOUNT,
                amountBIn: ZAP_AMOUNT,
                amountAMin: 1,
                amountBMin: 1,
                liquidityMin: 1,
                to: recipient,
                deadline: block.timestamp
            })
        );

        assertGt(amountA, 0);
        assertGt(amountB, 0);
        assertGt(liquidity, 0);
        assertEq(pair.totalSupply() - pairSupplyBefore, liquidity);
        assertEq(token.balanceOf(address(zap)), 0);
        assertEq(weth.balanceOf(address(zap)), 0);
    }

    function testZapNativeTokenAddsLiquidity() public {
        uint256 pairSupplyBefore = pair.totalSupply();

        vm.prank(user);
        (uint256 amountToken, uint256 amountNative, uint256 liquidity) =
            zap.zapNativeToken{value: ZAP_AMOUNT}(address(token), 0, 1, 1, 1, recipient, block.timestamp);

        assertGt(amountToken, 0);
        assertGt(amountNative, 0);
        assertGt(liquidity, 0);
        assertEq(pair.totalSupply() - pairSupplyBefore, liquidity);
        assertEq(token.balanceOf(address(zap)), 0);
        assertEq(weth.balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
        assertEq(user.balance, 100 ether - ZAP_AMOUNT);
    }

    function testNoAdminFunctions() public {
        _assertNoSelector("owner()");
        _assertNoSelector("pause()");
        _assertNoSelector("recover(address,uint256)");
        _assertNoSelector("admin()");
    }

    function _sendNativeToZap(uint256 amount) internal {
        (bool success, bytes memory revertData) = address(zap).call{value: amount}("");
        if (!success) {
            assembly {
                revert(add(revertData, 32), mload(revertData))
            }
        }
    }

    function _createPair(address token0, address token1) internal returns (MockUniswapV2Pair) {
        (address first, address second) = token0 < token1 ? (token0, token1) : (token1, token0);
        MockUniswapV2Pair created = new MockUniswapV2Pair(first, second);
        factory.setPair(first, second, address(created));
        router.setPair(first, second, address(created));
        return created;
    }

    function _assertNoSelector(string memory signature) internal {
        (bool success,) = address(zap).call(abi.encodeWithSignature(signature));
        assertFalse(success, signature);
    }
}
