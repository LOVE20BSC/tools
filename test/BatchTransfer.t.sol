// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {BatchTransfer} from "../src/BatchTransfer.sol";
import {IBatchTransferErrors, IBatchTransferEvents} from "../src/interfaces/IBatchTransfer.sol";
import {
    BrokenQueryERC20,
    GasHungryRecipient,
    MockERC20,
    NoReturnERC20,
    RejectNative,
    ShortReturnERC20
} from "./mocks/BatchTransferMocks.sol";

contract BatchTransferTest is Test, IBatchTransferEvents {
    /// @dev Per-recipient gas budget used throughout; the contract takes it as an argument now, so the
    /// tests pin one value rather than reading a constant off the contract.
    uint256 internal constant GAS_LIMIT = 50_000;

    BatchTransfer internal batchTransfer;
    MockERC20 internal token;

    address internal sender = address(0xA11CE);
    address internal recipient1 = address(0xB0B);
    address internal recipient2 = address(0xCAFE);
    address internal recipient3 = address(0xD00D);

    function setUp() public {
        batchTransfer = new BatchTransfer();
        token = new MockERC20();
    }

    function testBatchTransferNative() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(1 ether, 2 ether, 3 ether);

        vm.deal(sender, 10 ether);
        vm.expectEmit(true, false, false, true, address(batchTransfer));
        emit NativeBatchTransferred({
            sender: sender,
            totalAmount: 6 ether,
            recipientCount: 3
        });
        vm.prank(sender);
        uint256 totalAmount = batchTransfer.batchTransferNative{value: 6 ether}(recipients, amounts, GAS_LIMIT);

        assertEq(totalAmount, 6 ether);
        assertEq(recipient1.balance, 1 ether);
        assertEq(recipient2.balance, 2 ether);
        assertEq(recipient3.balance, 3 ether);
        assertEq(address(batchTransfer).balance, 0);
    }

    function testBatchTransferNativeRevertsOnValueMismatchBeforeTransfer() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(1 ether, 2 ether, 3 ether);

        vm.deal(sender, 10 ether);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.NativeValueMismatch.selector, 6 ether, 5 ether));
        batchTransfer.batchTransferNative{value: 5 ether}(recipients, amounts, GAS_LIMIT);

        assertEq(recipient1.balance, 0);
        assertEq(recipient2.balance, 0);
        assertEq(recipient3.balance, 0);
        assertEq(address(batchTransfer).balance, 0);
    }

    function testBatchTransferNativeRevertsOnRejectingRecipient() public {
        RejectNative rejectNative = new RejectNative();
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = address(rejectNative);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;

        vm.deal(sender, 2 ether);
        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.NativeTransferFailed.selector,
                1,
                address(rejectNative),
                1 ether,
                keccak256(_errorString("REJECT_NATIVE")),
                _errorString("REJECT_NATIVE").length
            )
        );
        batchTransfer.batchTransferNative{value: 2 ether}(recipients, amounts, GAS_LIMIT);

        assertEq(recipient1.balance, 0);
        assertEq(address(rejectNative).balance, 0);
        assertEq(address(batchTransfer).balance, 0);
    }

    function testBatchTransferERC20() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        token.mint(sender, 1_000);
        vm.prank(sender);
        token.approve(address(batchTransfer), 600);

        vm.expectEmit(true, true, false, true, address(batchTransfer));
        emit ERC20BatchTransferred({
            tokenAddress: address(token),
            sender: sender,
            totalAmount: 600,
            recipientCount: 3
        });
        vm.prank(sender);
        uint256 totalAmount = batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);

        assertEq(totalAmount, 600);
        assertEq(token.balanceOf(sender), 400);
        assertEq(token.balanceOf(recipient1), 100);
        assertEq(token.balanceOf(recipient2), 200);
        assertEq(token.balanceOf(recipient3), 300);
        assertEq(token.balanceOf(address(batchTransfer)), 0);
        assertEq(token.allowance(sender, address(batchTransfer)), 0);
    }

    function testBatchTransferERC20SupportsTokensWithoutReturnValue() public {
        NoReturnERC20 noReturnToken = new NoReturnERC20();
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        noReturnToken.mint(sender, 1_000);
        vm.prank(sender);
        noReturnToken.approve(address(batchTransfer), 600);

        vm.prank(sender);
        uint256 totalAmount = batchTransfer.batchTransferERC20(address(noReturnToken), recipients, amounts, GAS_LIMIT);

        assertEq(totalAmount, 600);
        assertEq(noReturnToken.balanceOf(sender), 400);
        assertEq(noReturnToken.balanceOf(recipient1), 100);
        assertEq(noReturnToken.balanceOf(recipient2), 200);
        assertEq(noReturnToken.balanceOf(recipient3), 300);
    }

    function testBatchTransferERC20RevertsBeforeTransferOnInsufficientBalance() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        token.mint(sender, 599);
        vm.prank(sender);
        token.approve(address(batchTransfer), 600);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.ERC20InsufficientBalance.selector, address(token), sender, 600, 599
            )
        );
        batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);

        assertEq(token.balanceOf(sender), 599);
        assertEq(token.balanceOf(recipient1), 0);
        assertEq(token.balanceOf(recipient2), 0);
        assertEq(token.balanceOf(recipient3), 0);
    }

    function testBatchTransferERC20RevertsBeforeTransferOnInsufficientAllowance() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        token.mint(sender, 1_000);
        vm.prank(sender);
        token.approve(address(batchTransfer), 599);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.ERC20InsufficientAllowance.selector,
                address(token),
                sender,
                address(batchTransfer),
                600,
                599
            )
        );
        batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);

        assertEq(token.balanceOf(sender), 1_000);
        assertEq(token.balanceOf(recipient1), 0);
        assertEq(token.balanceOf(recipient2), 0);
        assertEq(token.balanceOf(recipient3), 0);
    }

    function testBatchTransferERC20RevertsOnFalseReturn() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        token.mint(sender, 1_000);
        vm.prank(sender);
        token.approve(address(batchTransfer), 600);
        token.setReturnFalse(true);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.ERC20InvalidReturn.selector, address(token), 0, recipient1, 100, keccak256(abi.encode(false)), 32
            )
        );
        batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);

        assertEq(token.balanceOf(sender), 1_000);
        assertEq(token.balanceOf(recipient1), 0);
        assertEq(token.balanceOf(recipient2), 0);
        assertEq(token.balanceOf(recipient3), 0);
    }

    function testBatchTransferERC20RevertsOnTransferRevertAndRollsBack() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        token.mint(sender, 1_000);
        vm.prank(sender);
        token.approve(address(batchTransfer), 600);
        token.setRevertRecipient(recipient2);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.ERC20TransferFailed.selector,
                address(token),
                1,
                recipient2,
                200,
                keccak256(_errorString("MOCK_RECIPIENT")),
                _errorString("MOCK_RECIPIENT").length
            )
        );
        batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);

        assertEq(token.balanceOf(sender), 1_000);
        assertEq(token.balanceOf(recipient1), 0);
        assertEq(token.balanceOf(recipient2), 0);
        assertEq(token.balanceOf(recipient3), 0);
        assertEq(token.allowance(sender, address(batchTransfer)), 600);
    }

    function testBatchTransferERC20RevertsOnShortTransferReturn() public {
        ShortReturnERC20 shortReturnToken = new ShortReturnERC20();
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        shortReturnToken.mint(sender, 1_000);
        vm.prank(sender);
        shortReturnToken.approve(address(batchTransfer), 600);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.ERC20InvalidReturn.selector, address(shortReturnToken), 0, recipient1, 100, keccak256(hex"01"), 1
            )
        );
        batchTransfer.batchTransferERC20(address(shortReturnToken), recipients, amounts, GAS_LIMIT);

        assertEq(shortReturnToken.balanceOf(sender), 1_000);
        assertEq(shortReturnToken.balanceOf(recipient1), 0);
        assertEq(shortReturnToken.allowance(sender, address(batchTransfer)), 600);
    }

    function testBatchTransferERC20RevertsOnBalanceQueryFailure() public {
        BrokenQueryERC20 brokenToken = new BrokenQueryERC20();
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        brokenToken.setBalanceMode(BrokenQueryERC20.QueryMode.Revert);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.ERC20BalanceQueryFailed.selector,
                address(brokenToken),
                sender,
                keccak256(_errorString("BROKEN_QUERY")),
                _errorString("BROKEN_QUERY").length
            )
        );
        batchTransfer.batchTransferERC20(address(brokenToken), recipients, amounts, GAS_LIMIT);
    }

    function testBatchTransferERC20RevertsOnAllowanceQueryFailure() public {
        BrokenQueryERC20 brokenToken = new BrokenQueryERC20();
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        brokenToken.setAllowanceMode(BrokenQueryERC20.QueryMode.Revert);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.ERC20AllowanceQueryFailed.selector,
                address(brokenToken),
                sender,
                address(batchTransfer),
                keccak256(_errorString("BROKEN_QUERY")),
                _errorString("BROKEN_QUERY").length
            )
        );
        batchTransfer.batchTransferERC20(address(brokenToken), recipients, amounts, GAS_LIMIT);
    }

    function testRevertsOnEmptyBalanceQueryReturn() public {
        BrokenQueryERC20 brokenToken = new BrokenQueryERC20();
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        brokenToken.setBalanceMode(BrokenQueryERC20.QueryMode.Empty);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.ERC20BalanceQueryFailed.selector,
                address(brokenToken),
                sender,
                keccak256(bytes("")),
                0
            )
        );
        batchTransfer.batchTransferERC20(address(brokenToken), recipients, amounts, GAS_LIMIT);
    }

    function testNativeBalances() public {
        vm.deal(recipient1, 1 ether);
        vm.deal(recipient2, 2 ether);
        vm.deal(recipient3, 3 ether);

        uint256[] memory balances = batchTransfer.nativeBalances(_recipients3());

        assertEq(balances.length, 3);
        assertEq(balances[0], 1 ether);
        assertEq(balances[1], 2 ether);
        assertEq(balances[2], 3 ether);
    }

    function testERC20Balances() public {
        token.mint(recipient1, 100);
        token.mint(recipient2, 200);
        token.mint(recipient3, 300);

        uint256[] memory balances = batchTransfer.erc20Balances(address(token), _recipients3());

        assertEq(balances.length, 3);
        assertEq(balances[0], 100);
        assertEq(balances[1], 200);
        assertEq(balances[2], 300);
    }

    function testERC20BalancesRevertsOnShortBalanceReturn() public {
        BrokenQueryERC20 brokenToken = new BrokenQueryERC20();
        address[] memory accounts = _recipients3();

        brokenToken.setBalanceMode(BrokenQueryERC20.QueryMode.Short);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.ERC20BalanceQueryFailed.selector, address(brokenToken), recipient1, keccak256(hex"01"), 1
            )
        );
        batchTransfer.erc20Balances(address(brokenToken), accounts);
    }

    function testAllowsEmptyBalanceQueries() public view {
        address[] memory accounts = new address[](0);

        uint256[] memory nativeBalanceValues = batchTransfer.nativeBalances(accounts);
        uint256[] memory erc20BalanceValues = batchTransfer.erc20Balances(address(token), accounts);

        assertEq(nativeBalanceValues.length, 0);
        assertEq(erc20BalanceValues.length, 0);
    }

    function testAllowsLargeTransferRecipientBatches() public {
        uint256 recipientCount = 201;
        address[] memory recipients = new address[](recipientCount);
        uint256[] memory amounts = new uint256[](recipientCount);

        for (uint256 i = 0; i < recipientCount; i++) {
            recipients[i] = address(uint160(i + 1));
            amounts[i] = 1;
        }

        token.mint(sender, recipientCount);
        vm.prank(sender);
        token.approve(address(batchTransfer), recipientCount);

        vm.prank(sender);
        uint256 totalAmount = batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);

        assertEq(totalAmount, recipientCount);
        assertEq(token.balanceOf(sender), 0);
        assertEq(token.balanceOf(recipients[0]), 1);
        assertEq(token.balanceOf(recipients[recipientCount - 1]), 1);
    }

    function testAllowsLargeBalanceAccountBatches() public view {
        uint256 accountCount = 501;
        address[] memory accounts = new address[](accountCount);

        uint256[] memory balances = batchTransfer.nativeBalances(accounts);

        assertEq(balances.length, accountCount);
        assertEq(balances[0], 0);
        assertEq(balances[accountCount - 1], 0);
    }

    function testRevertsOnEmptyTransferBatch() public {
        address[] memory recipients = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(IBatchTransferErrors.EmptyBatch.selector);
        batchTransfer.batchTransferNative(recipients, amounts, GAS_LIMIT);

        vm.expectRevert(IBatchTransferErrors.EmptyBatch.selector);
        batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);
    }

    function testRevertsOnLengthMismatch() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.ArrayLengthMismatch.selector, 3, 2));
        batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);
    }

    function testRevertsOnZeroRecipient() public {
        address[] memory recipients = _recipients3();
        recipients[1] = address(0);
        uint256[] memory amounts = _amounts3(100, 200, 300);

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.ZeroRecipient.selector, 1));
        batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);
    }

    function testRevertsOnZeroAmount() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 0, 300);

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.ZeroAmount.selector, 1));
        batchTransfer.batchTransferERC20(address(token), recipients, amounts, GAS_LIMIT);
    }

    function testRevertsOnTokenNotContract() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.TokenNotContract.selector, address(0)));
        batchTransfer.batchTransferERC20(address(0), recipients, amounts, GAS_LIMIT);

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.TokenNotContract.selector, recipient1));
        batchTransfer.erc20Balances(recipient1, recipients);
    }

    function _recipients3() internal view returns (address[] memory recipients) {
        recipients = new address[](3);
        recipients[0] = recipient1;
        recipients[1] = recipient2;
        recipients[2] = recipient3;
    }

    function _amounts3(uint256 amount1, uint256 amount2, uint256 amount3)
        internal
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](3);
        amounts[0] = amount1;
        amounts[1] = amount2;
        amounts[2] = amount3;
    }

    function _errorString(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", reason);
    }

    // ----------------------------------------------------------------------------------------
    // Caller-supplied gas limit
    // ----------------------------------------------------------------------------------------

    function testRevertsOnZeroGasLimitForNative() public {
        address[] memory recipients = new address[](1);
        recipients[0] = recipient1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.deal(sender, 1 ether);
        vm.prank(sender);
        vm.expectRevert(IBatchTransferErrors.ZeroGasLimit.selector);
        batchTransfer.batchTransferNative{value: 1 ether}(recipients, amounts, 0);
    }

    function testRevertsOnZeroGasLimitForERC20() public {
        address[] memory recipients = new address[](1);
        recipients[0] = recipient1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        token.mint(sender, 1_000);
        vm.prank(sender);
        token.approve(address(batchTransfer), 100);

        vm.prank(sender);
        vm.expectRevert(IBatchTransferErrors.ZeroGasLimit.selector);
        batchTransfer.batchTransferERC20(address(token), recipients, amounts, 0);
    }

    /// @dev The budget is the caller's, not a constant: a recipient that needs more than the limit must
    /// fail, and the same recipient must succeed once the limit is raised. This is what makes the
    /// parameter meaningful instead of decorative.
    function testGasLimitIsActuallyApplied() public {
        GasHungryRecipient hungry = new GasHungryRecipient();
        address[] memory recipients = new address[](1);
        recipients[0] = address(hungry);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.deal(sender, 2 ether);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchTransferErrors.NativeTransferFailed.selector,
                0,
                address(hungry),
                1 ether,
                keccak256(""),
                0
            )
        );
        batchTransfer.batchTransferNative{value: 1 ether}(recipients, amounts, 5_000);

        assertEq(hungry.received(), 0, "nothing arrived under the low limit");

        vm.prank(sender);
        batchTransfer.batchTransferNative{value: 1 ether}(recipients, amounts, 200_000);

        assertEq(hungry.received(), 1 ether, "arrived once the limit was raised");
    }
}
