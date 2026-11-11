// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IBatchTransfer} from "./interfaces/IBatchTransfer.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";

contract BatchTransfer is IBatchTransfer {
    uint256 public constant override NATIVE_TRANSFER_GAS_LIMIT = 50_000;

    function batchTransferNative(address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        override
        returns (uint256 totalAmount)
    {
        totalAmount = _checkTransferBatch(recipients, amounts);
        if (msg.value != totalAmount) {
            revert NativeValueMismatch(totalAmount, msg.value);
        }

        uint256 recipientCount = recipients.length;
        for (uint256 i = 0; i < recipientCount; i++) {
            (bool success, bytes memory data) =
                // forge-lint: disable-next-line(arbitrary-send-eth, return-bomb)
                recipients[i].call{value: amounts[i], gas: NATIVE_TRANSFER_GAS_LIMIT}("");
            if (!success) {
                (bytes32 errorHash, uint256 errorLength) = _errorFingerprint(data);
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert NativeTransferFailed(i, recipients[i], amounts[i], errorHash, errorLength);
            }
        }

        emit NativeBatchTransferred({
            sender: msg.sender,
            totalAmount: totalAmount,
            recipientCount: recipientCount
        });
    }

    function batchTransferERC20(address tokenAddress, address[] calldata recipients, uint256[] calldata amounts)
        external
        override
        returns (uint256 totalAmount)
    {
        _checkTokenContract(tokenAddress);
        totalAmount = _checkTransferBatch(recipients, amounts);

        uint256 senderBalance = _erc20BalanceOf(tokenAddress, msg.sender);
        if (senderBalance < totalAmount) {
            revert ERC20InsufficientBalance(tokenAddress, msg.sender, totalAmount, senderBalance);
        }

        uint256 senderAllowance = _erc20Allowance(tokenAddress, msg.sender, address(this));
        if (senderAllowance < totalAmount) {
            revert ERC20InsufficientAllowance(tokenAddress, msg.sender, address(this), totalAmount, senderAllowance);
        }

        uint256 recipientCount = recipients.length;
        for (uint256 i = 0; i < recipientCount; i++) {
            _safeTransferFrom(tokenAddress, msg.sender, recipients[i], amounts[i], i);
        }

        emit ERC20BatchTransferred({
            tokenAddress: tokenAddress,
            sender: msg.sender,
            totalAmount: totalAmount,
            recipientCount: recipientCount
        });
    }

    function nativeBalances(address[] calldata accounts) external view override returns (uint256[] memory balances) {
        balances = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            balances[i] = accounts[i].balance;
        }
    }

    function erc20Balances(address tokenAddress, address[] calldata accounts)
        external
        view
        override
        returns (uint256[] memory balances)
    {
        _checkTokenContract(tokenAddress);

        balances = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            balances[i] = _erc20BalanceOf(tokenAddress, accounts[i]);
        }
    }

    function _checkTransferBatch(address[] calldata recipients, uint256[] calldata amounts)
        internal
        pure
        returns (uint256 totalAmount)
    {
        uint256 recipientCount = recipients.length;
        if (recipientCount == 0) {
            revert EmptyBatch();
        }
        if (recipientCount != amounts.length) {
            revert ArrayLengthMismatch(recipientCount, amounts.length);
        }

        for (uint256 i = 0; i < recipientCount; i++) {
            if (recipients[i] == address(0)) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert ZeroRecipient(i);
            }
            if (amounts[i] == 0) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert ZeroAmount(i);
            }
            totalAmount += amounts[i];
        }
    }

    function _checkTokenContract(address tokenAddress) internal view {
        if (tokenAddress == address(0) || tokenAddress.code.length == 0) {
            revert TokenNotContract(tokenAddress);
        }
    }

    function _erc20BalanceOf(address tokenAddress, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory data) =
            tokenAddress.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, account));
        if (!success || data.length < 32) {
            (bytes32 returnDataHash, uint256 returnDataLength) = _errorFingerprint(data);
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert ERC20BalanceQueryFailed(tokenAddress, account, returnDataHash, returnDataLength);
        }

        balance = abi.decode(data, (uint256));
    }

    function _erc20Allowance(address tokenAddress, address owner, address spender)
        internal
        view
        returns (uint256 allowanceAmount)
    {
        (bool success, bytes memory data) =
            tokenAddress.staticcall(abi.encodeWithSelector(IERC20Minimal.allowance.selector, owner, spender));
        if (!success || data.length < 32) {
            (bytes32 returnDataHash, uint256 returnDataLength) = _errorFingerprint(data);
            revert ERC20AllowanceQueryFailed(tokenAddress, owner, spender, returnDataHash, returnDataLength);
        }

        allowanceAmount = abi.decode(data, (uint256));
    }

    function _safeTransferFrom(address tokenAddress, address from, address to, uint256 amount, uint256 index)
        internal
    {
        (bool success, bytes memory data) =
            tokenAddress.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!success) {
            (bytes32 errorHash, uint256 errorLength) = _errorFingerprint(data);
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert ERC20TransferFailed(tokenAddress, index, to, amount, errorHash, errorLength);
        }
        if (!_isSuccessfulERC20Return(data)) {
            (bytes32 returnDataHash, uint256 returnDataLength) = _errorFingerprint(data);
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert ERC20InvalidReturn(tokenAddress, index, to, amount, returnDataHash, returnDataLength);
        }
    }

    function _errorFingerprint(bytes memory data) internal pure returns (bytes32 errorHash, uint256 errorLength) {
        return (keccak256(data), data.length);
    }

    function _isSuccessfulERC20Return(bytes memory data) internal pure returns (bool) {
        if (data.length == 0) {
            return true;
        }
        if (data.length < 32) {
            return false;
        }

        return abi.decode(data, (uint256)) == 1;
    }
}
