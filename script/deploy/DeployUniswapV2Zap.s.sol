// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {UniswapV2Zap} from "../../src/UniswapV2Zap.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2Router02.sol";

/// @notice Deploys UniswapV2Zap and validates the deployment.
/// @dev The only constructor input is the Router, and `factory` / `wrappedNativeToken` are derived
/// from it, so `_loadConfig` reads one address and the pre-broadcast phase checks the two derived
/// values on the already-deployed dependency (dev-standards §5.4: a cross-repository dependency
/// that is already on chain may be read at construction time). The Router belongs to `dex`, so the
/// address comes from the copied `addresses.uniswapv2.params`, never from this repository's own
/// records. The whole binding graph is read back after `stopBroadcast()` (§6.3), and the address is
/// printed as `KEY=VALUE` because this repository keeps no `fs_permissions` entry.
contract DeployUniswapV2Zap is Script {
    struct UniswapV2ZapConfig {
        uint256 chainId;
        address router;
        address factory;
        address wrappedNativeToken;
    }

    function run() external returns (UniswapV2Zap zap) {
        UniswapV2ZapConfig memory config = _loadConfig();
        _validateConfig(config);

        vm.startBroadcast();
        zap = new UniswapV2Zap(config.router);
        vm.stopBroadcast();

        _validateDeployment(config, zap);
        _logDeploymentSummary(address(zap));
    }

    function _loadConfig() internal view returns (UniswapV2ZapConfig memory config) {
        config.chainId = vm.envUint("CHAIN_ID");
        config.router = vm.envAddress("ROUTER_ADDRESS");
        // Derived, not configured: the zap caches these two at construction time, so validating them
        // before the broadcast is what keeps a wrong Router from producing a wrong-but-deployed zap.
        config.factory = IUniswapV2Router02(config.router).factory();
        config.wrappedNativeToken = IUniswapV2Router02(config.router).WETH();
    }

    function _validateConfig(UniswapV2ZapConfig memory config) internal view {
        require(block.chainid == config.chainId, "Chain ID mismatch");
        require(config.router.code.length != 0, "Router must be a deployed contract");
        require(config.factory.code.length != 0, "Router factory must be a deployed contract");
        require(config.wrappedNativeToken.code.length != 0, "Router WETH must be a deployed contract");
        require(config.factory != config.router, "Router must not be its own factory");
    }

    function _validateDeployment(UniswapV2ZapConfig memory config, UniswapV2Zap zap) internal view {
        require(address(zap).code.length != 0, "UniswapV2Zap deployment failed");
        require(address(zap.router()) == config.router, "Router mismatch");
        require(zap.factory() == config.factory, "Factory mismatch");
        require(zap.wrappedNativeToken() == config.wrappedNativeToken, "Wrapped native mismatch");
    }

    function _logDeploymentSummary(address zap) internal pure {
        console2.log("UniswapV2Zap constructor parameter: ROUTER_ADDRESS");
        console2.log("\n=== Deployment Summary ===");
        console2.log("UNISWAP_V2_ZAP_ADDRESS=", zap);
    }
}
