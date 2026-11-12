// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {DeployUniswapV2Zap} from "../script/deploy/DeployUniswapV2Zap.s.sol";
import {UniswapV2Zap} from "../src/UniswapV2Zap.sol";
import {MockUniswapV2Router02} from "./mocks/ZapMocks.sol";

/// @dev `_validateConfig` and `_validateDeployment` are `internal`. The harness exposes them without
/// changing the production script's visibility, matching the sibling repositories' `Deploy*Harness`
/// pattern — visibility is not widened just to make a test possible (dev-standards §6.3).
contract DeployUniswapV2ZapHarness is DeployUniswapV2Zap {
    function validateConfigForTest(UniswapV2ZapConfig memory config) external view {
        _validateConfig(config);
    }

    function validateDeploymentForTest(UniswapV2ZapConfig memory config, UniswapV2Zap zap) external view {
        _validateDeployment(config, zap);
    }
}

/// @notice Every `_validateConfig` invariant gets a negative test (dev-standards §6.3).
/// @dev The gate has five invariants — chain id, Router has code, derived factory has code, derived
/// WETH has code, Router is not its own factory — so each negative case breaks exactly one and leaves
/// the rest valid. A check firing for the wrong reason shows up as the wrong revert string rather than
/// as a pass.
///
/// The harness is used instead of `run()` because `run()` reads `CHAIN_ID`/`ROUTER_ADDRESS` through
/// `vm.env*`, and `vm.setEnv` writes to the *process* environment Foundry shares between concurrently
/// executed tests — such a test passes or fails by execution order. `vm.chainId` is EVM-scoped. The
/// end-to-end deployment path is covered by `test/deploy_scripts_test.py` and
/// `script/e2e/anvil_e2e.sh`.
contract DeployUniswapV2ZapConfigTest is Test {
    DeployUniswapV2ZapHarness internal harness;
    uint256 internal chainId;

    address internal routerAddress;
    address internal factoryAddress = address(0xFAC70);
    address internal wrappedNativeAddress = address(0xE7E7);

    /// @dev `_validateConfig` only inspects `code.length`, so one byte of bytecode is enough to look
    /// deployed. The Router is a real mock so the zap's constructor can call `factory()` and `WETH()`.
    function setUp() public {
        harness = new DeployUniswapV2ZapHarness();
        chainId = block.chainid;
        vm.etch(factoryAddress, hex"6002");
        vm.etch(wrappedNativeAddress, hex"6003");
        routerAddress = address(new MockUniswapV2Router02(factoryAddress, wrappedNativeAddress));
        vm.etch(factoryAddress, hex"6002");
        vm.etch(wrappedNativeAddress, hex"6003");
    }

    function testAcceptsFullyValidConfig() public view {
        harness.validateConfigForTest(_validConfig());
    }

    function testRejectsMismatchedConfiguredChainId() public {
        DeployUniswapV2Zap.UniswapV2ZapConfig memory config = _validConfig();
        config.chainId = chainId + 1;
        vm.expectRevert("Chain ID mismatch");
        harness.validateConfigForTest(config);
    }

    /// @dev The other direction: the config is right for the chain the run started on, but the script
    /// executes elsewhere, so `block.chainid` alone must reject it.
    function testRejectsMismatchedBlockChainId() public {
        DeployUniswapV2Zap.UniswapV2ZapConfig memory config = _validConfig();
        vm.chainId(chainId + 1);
        vm.expectRevert("Chain ID mismatch");
        harness.validateConfigForTest(config);
    }

    function testRejectsRouterWithoutCode() public {
        DeployUniswapV2Zap.UniswapV2ZapConfig memory config = _validConfig();
        config.router = address(0xDEAD);
        vm.expectRevert("Router must be a deployed contract");
        harness.validateConfigForTest(config);
    }

    function testRejectsFactoryWithoutCode() public {
        DeployUniswapV2Zap.UniswapV2ZapConfig memory config = _validConfig();
        config.factory = address(0xDEAD);
        vm.expectRevert("Router factory must be a deployed contract");
        harness.validateConfigForTest(config);
    }

    function testRejectsWrappedNativeWithoutCode() public {
        DeployUniswapV2Zap.UniswapV2ZapConfig memory config = _validConfig();
        config.wrappedNativeToken = address(0xDEAD);
        vm.expectRevert("Router WETH must be a deployed contract");
        harness.validateConfigForTest(config);
    }

    function testRejectsRouterThatIsItsOwnFactory() public {
        DeployUniswapV2Zap.UniswapV2ZapConfig memory config = _validConfig();
        config.factory = config.router;
        vm.expectRevert("Router must not be its own factory");
        harness.validateConfigForTest(config);
    }

    /// @dev `_validateDeployment` reads the deployed contract back; an address with no code must be
    /// rejected before the getters are called.
    function testValidateDeploymentRejectsAddressWithoutCode() public {
        vm.expectRevert("UniswapV2Zap deployment failed");
        harness.validateDeploymentForTest(_validConfig(), UniswapV2Zap(payable(address(0xBEEF))));
    }

    function testValidateDeploymentAcceptsTheDeploymentItDescribes() public {
        UniswapV2Zap zap = new UniswapV2Zap(routerAddress);
        harness.validateDeploymentForTest(_validConfig(), zap);
    }

    function testValidateDeploymentRejectsRouterMismatch() public {
        UniswapV2Zap zap = new UniswapV2Zap(routerAddress);

        DeployUniswapV2Zap.UniswapV2ZapConfig memory config = _validConfig();
        config.router = address(0xA11CE2);
        vm.expectRevert("Router mismatch");
        harness.validateDeploymentForTest(config, zap);
    }

    function testValidateDeploymentRejectsFactoryMismatch() public {
        UniswapV2Zap zap = new UniswapV2Zap(routerAddress);

        DeployUniswapV2Zap.UniswapV2ZapConfig memory config = _validConfig();
        config.factory = address(0xFAC702);
        vm.expectRevert("Factory mismatch");
        harness.validateDeploymentForTest(config, zap);
    }

    function testValidateDeploymentRejectsWrappedNativeMismatch() public {
        UniswapV2Zap zap = new UniswapV2Zap(routerAddress);

        DeployUniswapV2Zap.UniswapV2ZapConfig memory config = _validConfig();
        config.wrappedNativeToken = address(0xE7E702);
        vm.expectRevert("Wrapped native mismatch");
        harness.validateDeploymentForTest(config, zap);
    }

    function _validConfig() internal view returns (DeployUniswapV2Zap.UniswapV2ZapConfig memory) {
        return DeployUniswapV2Zap.UniswapV2ZapConfig({
            chainId: chainId,
            router: routerAddress,
            factory: factoryAddress,
            wrappedNativeToken: wrappedNativeAddress
        });
    }
}
