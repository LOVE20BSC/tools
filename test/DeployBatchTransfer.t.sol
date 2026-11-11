// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {DeployBatchTransfer} from "../script/deploy/DeployBatchTransfer.s.sol";

/// @dev `_validateConfig` is `internal`. This harness exposes it without touching the script's
/// visibility, matching the pattern the sibling repositories use (`DeployCoreHarness`,
/// `DeployActionHarness`). No production visibility change to make a test possible (§6.3).
contract DeployBatchTransferHarness is DeployBatchTransfer {
    function validateConfigForTest(BatchTransferConfig memory config) external view {
        _validateConfig(config);
    }
}

/// @notice Every `_validateConfig` invariant gets a negative test (dev-standards §6.3).
/// @dev `_validateConfig` has exactly one invariant -- `block.chainid == config.chainId` -- so both
/// sides of the comparison are exercised separately: a script that read only one of them would
/// still pass a one-sided test.
///
/// The gate is called through the harness rather than through `run()`, for two reasons. `run()`
/// reads `CHAIN_ID` with `vm.envUint`, and `vm.setEnv` writes to the *process* environment, which
/// Foundry shares between concurrently executed tests -- a test that mutates it races every other
/// test using it and the result depends on execution order. `run()` then also deploys and
/// broadcasts; the deployment itself is covered end to end by `21_check_batch_transfer.sh`'s
/// regression test in `test/deploy_scripts_test.py`. `vm.chainId`, in contrast, is EVM-scoped.
contract DeployBatchTransferConfigTest is Test {
    DeployBatchTransferHarness internal harness;
    uint256 internal chainId;

    function setUp() public {
        harness = new DeployBatchTransferHarness();
        chainId = block.chainid;
    }

    function testAcceptsMatchingChainId() public view {
        harness.validateConfigForTest(_config(chainId));
    }

    function testRejectsMismatchedConfiguredChainId() public {
        vm.expectRevert("Chain ID mismatch");
        harness.validateConfigForTest(_config(chainId + 1));
    }

    /// @dev The other direction: the configuration is correct for the chain the run started on, but
    /// the script executes on another one, so `block.chainid` alone must be enough to reject it.
    function testRejectsMismatchedBlockChainId() public {
        DeployBatchTransfer.BatchTransferConfig memory config = _config(chainId);
        vm.chainId(chainId + 1);
        vm.expectRevert("Chain ID mismatch");
        harness.validateConfigForTest(config);
    }

    function _config(uint256 chainId_) internal pure returns (DeployBatchTransfer.BatchTransferConfig memory) {
        return DeployBatchTransfer.BatchTransferConfig({chainId: chainId_});
    }
}
