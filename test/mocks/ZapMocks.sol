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

    /// @dev Failure injection for the zap's `_approveToken` path: a token that refuses approval is
    /// what a paused/blacklisting token looks like from the zap's side.
    bool public approveReverts;

    function setApproveReverts(bool reverts) external {
        approveReverts = reverts;
    }

    function mint(address account, uint256 amount) external {
        totalSupply += amount;
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        require(!approveReverts, "MOCK_APPROVE");
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

/// @dev Pair mock with the real Uniswap V2 liquidity accounting. Every getter the zap reads
/// (`getReserves`, `token0`, `token1`, `totalSupply`, `kLast`) is independently settable, and the
/// mint helpers update all of them the way the real pair does — in particular the first mint burns
/// MINIMUM_LIQUIDITY and `mintFee` mints 1/6 of the growth in sqrt(k) to `feeTo` — so the zap's
/// total-supply projection is checked against the same math the pair itself would apply.
contract MockUniswapV2Pair is IUniswapV2Pair {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public immutable override token0;
    address public immutable override token1;

    uint256 public override totalSupply;
    uint256 public override kLast;

    /// @dev LP balances, so tests can assert that the recipient (not the zap) received the minted
    /// liquidity. The real pair is an ERC20; transferring LP is not needed by the zap, so only the
    /// balance that `mint`/`burn` would produce is tracked.
    mapping(address => uint256) public balanceOf;

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

    /// @dev What `UniswapV2Pair.mint` does to the LP ledger: the caller receives `liquidity` and the
    /// supply becomes `totalSupplyAfter` (which already includes the locked MINIMUM_LIQUIDITY and any
    /// protocol-fee mint).
    function mintTo(address to, uint256 liquidity, uint256 totalSupplyAfter) external {
        balanceOf[to] += liquidity;
        totalSupply = totalSupplyAfter;
    }

    /// @dev The state a real pair reaches after its first `mint` (or after `sync`): reserves, supply
    /// and the k-baseline in one call. `withKLast` mirrors `feeTo != address(0)` in the real pair.
    function seed(uint112 reserve0, uint112 reserve1, uint256 totalSupply_, bool withKLast) external {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = uint32(block.timestamp);
        totalSupply = totalSupply_;
        kLast = withKLast ? uint256(reserve0) * uint256(reserve1) : 0;
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

    /// @dev The pair half of a swap: move the output out, then fold both legs into the reserves.
    function settleSwap(address tokenIn, address tokenOut, address to, uint256 amountIn, uint256 amountOut)
        external
    {
        sendToken(tokenOut, to, amountOut);
        addToReserve(tokenIn, amountIn);
        removeFromReserve(tokenOut, amountOut);
    }

    /// @dev `UniswapV2Pair.mint` liquidity accounting: the first mint locks MINIMUM_LIQUIDITY, later
    /// mints are proportional to the smaller side, and `kLast` follows `feeTo` being set.
    function mintLiquidity(uint256 amount0, uint256 amount1, bool withKLast) external returns (uint256 liquidity) {
        if (totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            totalSupply = MINIMUM_LIQUIDITY;
        } else {
            liquidity = _min((amount0 * totalSupply) / _reserve0, (amount1 * totalSupply) / _reserve1);
        }
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");

        addToReserve(token0, amount0);
        addToReserve(token1, amount1);
        totalSupply += liquidity;
        if (withKLast) {
            kLast = uint256(_reserve0) * uint256(_reserve1);
        }
    }

    /// @dev `UniswapV2Pair._mintFee` projection: the protocol's 1/6 of the growth in sqrt(k) since
    /// `kLast`. Returns 0 when there is no fee recipient, no baseline, or no growth. The router mock
    /// applies this before minting, exactly like the real pair does inside `mint`.
    function pendingFeeLiquidity(address feeTo) public view returns (uint256 feeLiquidity) {
        if (feeTo == address(0) || kLast == 0) return 0;
        uint256 rootK = _sqrt(uint256(_reserve0) * uint256(_reserve1));
        uint256 rootKLast = _sqrt(kLast);
        if (rootK <= rootKLast) return 0;
        feeLiquidity = (totalSupply * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
    }

    /// @dev Applies the pending protocol-fee mint to `totalSupply`, the way the real pair does on the
    /// next `mint`/`burn`. Used to build a "fee already minted" starting state.
    function applyMintFee(address feeTo) external returns (uint256 feeLiquidity) {
        feeLiquidity = pendingFeeLiquidity(feeTo);
        totalSupply += feeLiquidity;
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

    /// @dev Mirrors `UniswapV2Factory.createPair`: deploys a pair with sorted tokens and registers it
    /// under both orders, so the router can create-on-demand like the real one does.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "UniswapV2: IDENTICAL_ADDRESSES");
        require(tokenA != address(0) && tokenB != address(0), "UniswapV2: ZERO_ADDRESS");
        require(_pairByTokenByToken[tokenA][tokenB] == address(0), "UniswapV2: PAIR_EXISTS");

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new MockUniswapV2Pair(token0, token1));
        _pairByTokenByToken[tokenA][tokenB] = pair;
        _pairByTokenByToken[tokenB][tokenA] = pair;
    }

    function getPair(address tokenA, address tokenB) external view override returns (address pair) {
        return _pairByTokenByToken[tokenA][tokenB];
    }
}

/// @dev Router mock with the real constant-product math (997/1000, `getAmountOut` verbatim from
/// UniswapV2Library, proportional mint with the locked MINIMUM_LIQUIDITY and the protocol-fee mint
/// applied first). Pairs come from the factory, never from a second registry, so the zap and the
/// router can never disagree about which pair they are talking to.
/// Every behaviour the zap depends on is injectable:
///
/// - `setAddLiquidityRevert` / `setSwapRevert` make a call revert with an arbitrary reason;
/// - `setLiquidityMintedOverride` / `setSwapOutputOverride` return a value that does not match the
///   math, which is what "the pool minted/paid out less than expected" looks like on chain;
/// - `setWeth` / `setFactory` swap the getters the zap derives its dependencies from.
contract MockUniswapV2Router02 is IUniswapV2Router02 {
    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    address public override factory;
    address public override WETH;

    bool private _addLiquidityReverts;
    string private _addLiquidityRevertReason;
    bool private _swapReverts;
    string private _swapRevertReason;

    bool private _liquidityMintedOverrideEnabled;
    uint256 private _liquidityMintedOverride;
    bool private _swapOutputOverrideEnabled;
    uint256 private _swapOutputOverride;

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH = weth_;
    }

    /// @dev Convenience for tests: registers the pair on the factory, which is the only registry the
    /// router consults.
    function setPair(address tokenA, address tokenB, address pairAddress) external {
        MockUniswapV2Factory(factory).setPair(tokenA, tokenB, pairAddress);
    }

    function setFactory(address factory_) external {
        factory = factory_;
    }

    function setWeth(address weth_) external {
        WETH = weth_;
    }

    function setAddLiquidityRevert(bool reverts, string calldata reason) external {
        _addLiquidityReverts = reverts;
        _addLiquidityRevertReason = reason;
    }

    function setSwapRevert(bool reverts, string calldata reason) external {
        _swapReverts = reverts;
        _swapRevertReason = reason;
    }

    function setLiquidityMintedOverride(bool enabled, uint256 value) external {
        _liquidityMintedOverrideEnabled = enabled;
        _liquidityMintedOverride = value;
    }

    function setSwapOutputOverride(bool enabled, uint256 value) external {
        _swapOutputOverrideEnabled = enabled;
        _swapOutputOverride = value;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external override returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        if (_addLiquidityReverts) revert(_addLiquidityRevertReason);
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        require(to != address(0), "MOCK_ZERO_TO");

        MockUniswapV2Pair pair = _pairOrCreate(tokenA, tokenB);
        (amountA, amountB) = _optimalAmounts(pair, tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        uint256 totalSupplyAfter;
        (liquidity, totalSupplyAfter) = _liquidityToMint(pair, tokenA, tokenB, amountA, amountB);

        require(MockERC20(tokenA).transferFrom(msg.sender, address(pair), amountA), "MOCK_PULL_A");
        require(MockERC20(tokenB).transferFrom(msg.sender, address(pair), amountB), "MOCK_PULL_B");

        pair.addToReserve(tokenA, amountA);
        pair.addToReserve(tokenB, amountB);
        pair.mintTo(to, liquidity, totalSupplyAfter);
        if (_feeTo() != address(0)) {
            (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
            pair.setKLast(uint256(reserve0) * uint256(reserve1));
        }
    }

    /// @dev `UniswapV2Router02._addLiquidity` amount optimisation.
    function _optimalAmounts(
        MockUniswapV2Pair pair,
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) private view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = _reservesOf(pair, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }

        uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "UniswapV2Router: INSUFFICIENT_B_AMOUNT");
            return (amountADesired, amountBOptimal);
        }
        uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
        require(amountAOptimal >= amountAMin, "UniswapV2Router: INSUFFICIENT_A_AMOUNT");
        return (amountAOptimal, amountBDesired);
    }

    /// @dev `UniswapV2Pair.mint` liquidity accounting, including the locked MINIMUM_LIQUIDITY on the
    /// first mint and the protocol-fee mint applied before the proportional share (`_mintFee`).
    /// The zap's `_quoteTotalSupplyAfterFeeMint` mirrors this branch; the router returns the same
    /// numbers so a quote can be compared against the real mint.
    function _liquidityToMint(
        MockUniswapV2Pair pair,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) private view returns (uint256 liquidity, uint256 totalSupplyAfter) {
        (uint256 reserveA, uint256 reserveB) = _reservesOf(pair, tokenA, tokenB);
        uint256 supply = pair.totalSupply();
        if (supply == 0) {
            uint256 rootK = _sqrt(amountA * amountB);
            require(rootK > MINIMUM_LIQUIDITY, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
            return (rootK - MINIMUM_LIQUIDITY, rootK);
        }

        supply += pair.pendingFeeLiquidity(_feeTo());
        liquidity = _min((amountA * supply) / reserveA, (amountB * supply) / reserveB);
        if (_liquidityMintedOverrideEnabled) {
            liquidity = _liquidityMintedOverride;
        }
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        totalSupplyAfter = supply + liquidity;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        if (_swapReverts) revert(_swapRevertReason);
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        require(path.length == 2, "MOCK_PATH");
        require(to != address(0), "MOCK_ZERO_TO");

        MockUniswapV2Pair pair = _pair(path[0], path[1]);
        uint256 amountOut = getAmountOut(amountIn, _reserveOf(pair, path[0]), _reserveOf(pair, path[1]));
        if (_swapOutputOverrideEnabled) {
            amountOut = _swapOutputOverride;
        }
        require(amountOut >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");

        require(MockERC20(path[0]).transferFrom(msg.sender, address(pair), amountIn), "MOCK_PULL_IN");
        pair.settleSwap(path[0], path[1], to, amountIn, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    /// @dev `UniswapV2Library.getAmountOut` verbatim: tests compare the zap's internal swap output
    /// against this instead of against a reimplementation.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    function _feeTo() private view returns (address) {
        return MockUniswapV2Factory(factory).feeTo();
    }

    function _pairOrCreate(address tokenA, address tokenB) private returns (MockUniswapV2Pair pair) {
        address pairAddress = MockUniswapV2Factory(factory).getPair(tokenA, tokenB);
        if (pairAddress == address(0)) {
            pairAddress = MockUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        pair = MockUniswapV2Pair(pairAddress);
    }

    function _pair(address tokenA, address tokenB) private view returns (MockUniswapV2Pair pair) {
        address pairAddress = MockUniswapV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), "MOCK_NO_PAIR");
        pair = MockUniswapV2Pair(pairAddress);
    }

    function _reservesOf(MockUniswapV2Pair pair, address tokenA, address tokenB)
        private
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        reserveA = tokenA == pair.token0() ? uint256(reserve0) : uint256(reserve1);
        reserveB = tokenB == pair.token0() ? uint256(reserve0) : uint256(reserve1);
    }

    function _reserveOf(MockUniswapV2Pair pair, address tokenAddress) private view returns (uint256 value) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        value = tokenAddress == pair.token0() ? uint256(reserve0) : uint256(reserve1);
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
