// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Test} from "forge-std/Test.sol";
import {BatchTransfer} from "../src/BatchTransfer.sol";
import {IBatchTransferErrors, IBatchTransferEvents} from "../src/interface/IBatchTransfer.sol";

contract MockERC20 {
    string public constant name = "Mock Token";
    string public constant symbol = "MOCK";
    uint8 public constant decimals = 18;

    bool public returnFalse;
    address public revertRecipient;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setReturnFalse(bool returnFalse_) external {
        returnFalse = returnFalse_;
    }

    function setRevertRecipient(address revertRecipient_) external {
        revertRecipient = revertRecipient_;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == revertRecipient) {
            revert("MOCK_RECIPIENT");
        }
        if (returnFalse) {
            return false;
        }

        require(balanceOf[from] >= amount, "MOCK_BALANCE");
        require(allowance[from][msg.sender] >= amount, "MOCK_ALLOWANCE");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        return true;
    }
}

contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "NO_RETURN_BALANCE");
        require(allowance[from][msg.sender] >= amount, "NO_RETURN_ALLOWANCE");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract BrokenQueryERC20 {
    enum QueryMode {
        Ok,
        Revert,
        Short
    }

    QueryMode public balanceMode;
    QueryMode public allowanceMode;

    uint256 public balanceValue = 1_000;
    uint256 public allowanceValue = 1_000;

    function setBalanceMode(QueryMode balanceMode_) external {
        balanceMode = balanceMode_;
    }

    function setAllowanceMode(QueryMode allowanceMode_) external {
        allowanceMode = allowanceMode_;
    }

    fallback() external {
        if (msg.sig == bytes4(keccak256("balanceOf(address)"))) {
            _returnByMode(balanceMode, balanceValue);
        }
        if (msg.sig == bytes4(keccak256("allowance(address,address)"))) {
            _returnByMode(allowanceMode, allowanceValue);
        }

        revert("UNKNOWN_SELECTOR");
    }

    function _returnByMode(QueryMode mode, uint256 value) internal pure {
        if (mode == QueryMode.Revert) {
            revert("BROKEN_QUERY");
        }
        if (mode == QueryMode.Short) {
            assembly {
                mstore(0x00, 1)
                return(0x1f, 1)
            }
        }

        assembly {
            mstore(0x00, value)
            return(0x00, 0x20)
        }
    }
}

contract ShortReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    fallback() external {
        if (msg.sig != bytes4(keccak256("transferFrom(address,address,uint256)"))) {
            revert("UNKNOWN_SELECTOR");
        }

        assembly {
            mstore(0x00, 1)
            return(0x1f, 1)
        }
    }
}

contract RejectNative {
    receive() external payable {
        revert("REJECT_NATIVE");
    }
}

contract BatchTransferTest is Test, IBatchTransferEvents {
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
        emit NativeBatchTransfer(sender, 6 ether, 3);
        vm.prank(sender);
        uint256 totalAmount = batchTransfer.batchTransferNative{value: 6 ether}(recipients, amounts);

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
        batchTransfer.batchTransferNative{value: 5 ether}(recipients, amounts);

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
                _errorString("REJECT_NATIVE")
            )
        );
        batchTransfer.batchTransferNative{value: 2 ether}(recipients, amounts);

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
        emit ERC20BatchTransfer(address(token), sender, 600, 3);
        vm.prank(sender);
        uint256 totalAmount = batchTransfer.batchTransferERC20(address(token), recipients, amounts);

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
        uint256 totalAmount = batchTransfer.batchTransferERC20(address(noReturnToken), recipients, amounts);

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
                IBatchTransferErrors.ERC20InsufficientBalance.selector, address(token), sender, 599, 600
            )
        );
        batchTransfer.batchTransferERC20(address(token), recipients, amounts);

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
                599,
                600
            )
        );
        batchTransfer.batchTransferERC20(address(token), recipients, amounts);

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
                IBatchTransferErrors.ERC20InvalidReturn.selector, address(token), 0, recipient1, 100, abi.encode(false)
            )
        );
        batchTransfer.batchTransferERC20(address(token), recipients, amounts);

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
                _errorString("MOCK_RECIPIENT")
            )
        );
        batchTransfer.batchTransferERC20(address(token), recipients, amounts);

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
                IBatchTransferErrors.ERC20InvalidReturn.selector, address(shortReturnToken), 0, recipient1, 100, hex"01"
            )
        );
        batchTransfer.batchTransferERC20(address(shortReturnToken), recipients, amounts);

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
                _errorString("BROKEN_QUERY")
            )
        );
        batchTransfer.batchTransferERC20(address(brokenToken), recipients, amounts);
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
                _errorString("BROKEN_QUERY")
            )
        );
        batchTransfer.batchTransferERC20(address(brokenToken), recipients, amounts);
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
                IBatchTransferErrors.ERC20BalanceQueryFailed.selector, address(brokenToken), recipient1, hex"01"
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
        uint256 totalAmount = batchTransfer.batchTransferERC20(address(token), recipients, amounts);

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
        batchTransfer.batchTransferNative(recipients, amounts);

        vm.expectRevert(IBatchTransferErrors.EmptyBatch.selector);
        batchTransfer.batchTransferERC20(address(token), recipients, amounts);
    }

    function testRevertsOnLengthMismatch() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.ArrayLengthMismatch.selector, 3, 2));
        batchTransfer.batchTransferERC20(address(token), recipients, amounts);
    }

    function testRevertsOnZeroRecipient() public {
        address[] memory recipients = _recipients3();
        recipients[1] = address(0);
        uint256[] memory amounts = _amounts3(100, 200, 300);

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.ZeroRecipient.selector, 1));
        batchTransfer.batchTransferERC20(address(token), recipients, amounts);
    }

    function testRevertsOnZeroAmount() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 0, 300);

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.ZeroAmount.selector, 1));
        batchTransfer.batchTransferERC20(address(token), recipients, amounts);
    }

    function testRevertsOnInvalidToken() public {
        address[] memory recipients = _recipients3();
        uint256[] memory amounts = _amounts3(100, 200, 300);

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.InvalidToken.selector, address(0)));
        batchTransfer.batchTransferERC20(address(0), recipients, amounts);

        vm.expectRevert(abi.encodeWithSelector(IBatchTransferErrors.InvalidToken.selector, recipient1));
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
}
