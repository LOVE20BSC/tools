// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IUniswapV2Factory} from "../../src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "../../src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2Router02.sol";
import {IWrappedNative} from "../../src/interfaces/IWrappedNative.sol";

contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        totalSupply += amount;
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "MOCK_ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MOCK_BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockWrappedNative is MockERC20, IWrappedNative {
    function deposit() external payable override {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external override {
        require(balanceOf[msg.sender] >= amount, "MOCK_BALANCE");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "MOCK_NATIVE_SEND");
    }

    receive() external payable {}
}

contract MockUniswapV2Pair is IUniswapV2Pair {
    address public immutable override token0;
    address public immutable override token1;

    uint256 public override totalSupply;
    uint256 public override kLast;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    constructor(address token0_, address token1_) {
        require(token0_ != token1_, "MOCK_IDENTICAL_TOKENS");
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves()
        external
        view
        override
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
    {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    function setReserves(uint112 reserve0, uint112 reserve1) external {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = uint32(block.timestamp);
    }

    function setTotalSupply(uint256 totalSupply_) external {
        totalSupply = totalSupply_;
    }

    function setKLast(uint256 kLast_) external {
        kLast = kLast_;
    }

    function addToReserve(address tokenAddress, uint256 amount) public {
        if (tokenAddress == token0) {
            _reserve0 = uint112(uint256(_reserve0) + amount);
        } else {
            require(tokenAddress == token1, "MOCK_UNKNOWN_TOKEN");
            _reserve1 = uint112(uint256(_reserve1) + amount);
        }
    }

    function removeFromReserve(address tokenAddress, uint256 amount) public {
        if (tokenAddress == token0) {
            require(uint256(_reserve0) >= amount, "MOCK_RESERVE");
            _reserve0 = uint112(uint256(_reserve0) - amount);
        } else {
            require(tokenAddress == token1, "MOCK_UNKNOWN_TOKEN");
            require(uint256(_reserve1) >= amount, "MOCK_RESERVE");
            _reserve1 = uint112(uint256(_reserve1) - amount);
        }
    }

    function sendToken(address tokenAddress, address to, uint256 amount) public {
        require(tokenAddress == token0 || tokenAddress == token1, "MOCK_UNKNOWN_TOKEN");
        MockERC20(tokenAddress).transfer(to, amount);
    }

    function settleSwap(
        address tokenIn,
        address tokenOut,
        address to,
        uint256 amountIn,
        uint256 amountOut
    ) external {
        sendToken(tokenOut, to, amountOut);
        addToReserve(tokenIn, amountIn);
        removeFromReserve(tokenOut, amountOut);
    }
}

contract MockUniswapV2Factory is IUniswapV2Factory {
    address public override feeTo;

    mapping(address => mapping(address => address)) private _pairByTokenByToken;

    function setPair(address tokenA, address tokenB, address pairAddress) external {
        _pairByTokenByToken[tokenA][tokenB] = pairAddress;
        _pairByTokenByToken[tokenB][tokenA] = pairAddress;
    }

    function setFeeTo(address feeTo_) external {
        feeTo = feeTo_;
    }

    function getPair(address tokenA, address tokenB) external view override returns (address pair) {
        return _pairByTokenByToken[tokenA][tokenB];
    }
}

contract MockUniswapV2Router02 is IUniswapV2Router02 {
    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;

    address public immutable override factory;
    address public immutable override WETH;

    mapping(address => mapping(address => address)) private _pairByTokenByToken;

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH = weth_;
    }

    function setPair(address tokenA, address tokenB, address pairAddress) external {
        _pairByTokenByToken[tokenA][tokenB] = pairAddress;
        _pairByTokenByToken[tokenB][tokenA] = pairAddress;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external override returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(to != address(0), "MOCK_ZERO_TO");

        MockUniswapV2Pair pair = _pair(tokenA, tokenB);
        uint256 totalSupply = pair.totalSupply();
        uint256 minted = totalSupply == 0
            ? _sqrt(amountADesired * amountBDesired)
            : _liquidity(pair, tokenA, tokenB, amountADesired, amountBDesired, totalSupply);

        require(MockERC20(tokenA).transferFrom(msg.sender, address(pair), amountADesired), "MOCK_PULL_A");
        require(MockERC20(tokenB).transferFrom(msg.sender, address(pair), amountBDesired), "MOCK_PULL_B");

        pair.addToReserve(tokenA, amountADesired);
        pair.addToReserve(tokenB, amountBDesired);
        pair.setTotalSupply(totalSupply + minted);

        return (amountADesired, amountBDesired, minted);
    }

    function _liquidity(
        MockUniswapV2Pair pair,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 totalSupply
    ) private view returns (uint256 liquidity) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        liquidity = _min(
            (amountA * totalSupply) / _reserveOf(pair, tokenA, reserve0, reserve1),
            (amountB * totalSupply) / _reserveOf(pair, tokenB, reserve0, reserve1)
        );
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external override returns (uint256[] memory amounts) {
        require(path.length == 2, "MOCK_PATH");
        require(to != address(0), "MOCK_ZERO_TO");

        MockUniswapV2Pair pair = _pair(path[0], path[1]);
        uint256 amountOut = _amountOut(pair, path[0], path[1], amountIn);
        require(amountOut >= amountOutMin, "MOCK_SLIPPAGE");

        require(MockERC20(path[0]).transferFrom(msg.sender, address(pair), amountIn), "MOCK_PULL_IN");
        pair.settleSwap(path[0], path[1], to, amountIn, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    function _amountOut(MockUniswapV2Pair pair, address tokenIn, address tokenOut, uint256 amountIn)
        private
        view
        returns (uint256 amountOut)
    {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 reserveIn = _reserveOf(pair, tokenIn, reserve0, reserve1);
        uint256 reserveOut = _reserveOf(pair, tokenOut, reserve0, reserve1);

        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    function _pair(address tokenA, address tokenB) private view returns (MockUniswapV2Pair pair) {
        address pairAddress = _pairByTokenByToken[tokenA][tokenB];
        require(pairAddress != address(0), "MOCK_NO_PAIR");
        pair = MockUniswapV2Pair(pairAddress);
    }

    function _reserveOf(MockUniswapV2Pair pair, address tokenAddress, uint112 reserve0, uint112 reserve1)
        private
        view
        returns (uint256 reserve)
    {
        reserve = tokenAddress == pair.token0() ? uint256(reserve0) : uint256(reserve1);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sqrt(uint256 value) private pure returns (uint256 result) {
        if (value == 0) return 0;
        result = value;
        uint256 x = (value + 1) / 2;
        while (x < result) {
            result = x;
            x = (value / x + x) / 2;
        }
    }
}
