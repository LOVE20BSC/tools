// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {BatchTransfer} from "../../src/BatchTransfer.sol";

/// @notice Deploys BatchTransfer and validates the deployment.
/// @dev The contract has no constructor parameters, so `_loadConfig` only reads the chain ID: the
/// deployment has no inputs beyond "which chain". Every static check runs before `startBroadcast()`
/// and the whole binding graph is read back after `stopBroadcast()`, per dev-standards §6.3.
/// The address is printed as `KEY=VALUE` instead of being written with `vm.writeFile`: this
/// repository keeps no `fs_permissions` entry (foundry.toml is shared with the build/lint gates),
/// and §6.3 allows either form. `11_deploy_batch_transfer.sh` extracts the line from the deploy log
/// and replaces the address file atomically.
contract DeployBatchTransfer is Script {
    struct BatchTransferConfig {
        uint256 chainId;
    }

    function run() external returns (BatchTransfer batchTransfer) {
        BatchTransferConfig memory config = _loadConfig();
        _validateConfig(config);

        vm.startBroadcast();
        batchTransfer = new BatchTransfer();
        vm.stopBroadcast();

        _validateDeployment(batchTransfer);
        _logDeploymentSummary(address(batchTransfer));
    }

    function _loadConfig() internal view returns (BatchTransferConfig memory config) {
        config.chainId = vm.envUint("CHAIN_ID");
    }

    function _validateConfig(BatchTransferConfig memory config) internal view {
        require(block.chainid == config.chainId, "Chain ID mismatch");
    }

    function _validateDeployment(BatchTransfer batchTransfer) internal view {
        // The contract has no constructor parameters and no deployment-time constants: every knob
        // (including the per-recipient gas budget) is a call argument now, so the only thing left to
        // verify is that code actually landed. Behaviour is covered by the test suite.
        require(address(batchTransfer).code.length != 0, "BatchTransfer deployment failed");
    }

    function _logDeploymentSummary(address batchTransfer) internal pure {
        console2.log("BatchTransfer has no constructor parameters");
        console2.log("\n=== Deployment Summary ===");
        console2.log("BATCH_TRANSFER_ADDRESS=", batchTransfer);
    }
}
