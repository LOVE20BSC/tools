// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IBatchTransfer} from "./interface/IBatchTransfer.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract BatchTransfer is IBatchTransfer {
    uint256 public constant override NATIVE_TRANSFER_GAS_LIMIT = 50_000;

    function batchTransferNative(address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        override
        returns (uint256 totalAmount)
    {
        totalAmount = _validateTransferBatch(recipients, amounts);
        if (msg.value != totalAmount) {
            revert NativeValueMismatch(totalAmount, msg.value);
        }

        uint256 recipientCount = recipients.length;
        for (uint256 i = 0; i < recipientCount; i++) {
            (bool success, bytes memory data) =
                recipients[i].call{value: amounts[i], gas: NATIVE_TRANSFER_GAS_LIMIT}("");
            if (!success) {
                revert NativeTransferFailed(i, recipients[i], amounts[i], data);
            }
        }

        emit NativeBatchTransfer(msg.sender, totalAmount, recipientCount);
    }

    function batchTransferERC20(address token, address[] calldata recipients, uint256[] calldata amounts)
        external
        override
        returns (uint256 totalAmount)
    {
        _requireTokenContract(token);
        totalAmount = _validateTransferBatch(recipients, amounts);

        uint256 senderBalance = _erc20BalanceOf(token, msg.sender);
        if (senderBalance < totalAmount) {
            revert ERC20InsufficientBalance(token, msg.sender, senderBalance, totalAmount);
        }

        uint256 senderAllowance = _erc20Allowance(token, msg.sender, address(this));
        if (senderAllowance < totalAmount) {
            revert ERC20InsufficientAllowance(token, msg.sender, address(this), senderAllowance, totalAmount);
        }

        uint256 recipientCount = recipients.length;
        for (uint256 i = 0; i < recipientCount; i++) {
            _safeTransferFrom(token, msg.sender, recipients[i], amounts[i], i);
        }

        emit ERC20BatchTransfer(token, msg.sender, totalAmount, recipientCount);
    }

    function nativeBalances(address[] calldata accounts) external view override returns (uint256[] memory balances) {
        balances = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            balances[i] = accounts[i].balance;
        }
    }

    function erc20Balances(address token, address[] calldata accounts)
        external
        view
        override
        returns (uint256[] memory balances)
    {
        _requireTokenContract(token);

        balances = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            balances[i] = _erc20BalanceOf(token, accounts[i]);
        }
    }

    function _validateTransferBatch(address[] calldata recipients, uint256[] calldata amounts)
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
                revert ZeroRecipient(i);
            }
            if (amounts[i] == 0) {
                revert ZeroAmount(i);
            }
            totalAmount += amounts[i];
        }
    }

    function _requireTokenContract(address token) internal view {
        if (token == address(0) || token.code.length == 0) {
            revert InvalidToken(token);
        }
    }

    function _erc20BalanceOf(address token, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, account));
        if (!success || data.length < 32) {
            revert ERC20BalanceQueryFailed(token, account, data);
        }

        balance = abi.decode(data, (uint256));
    }

    function _erc20Allowance(address token, address owner, address spender)
        internal
        view
        returns (uint256 allowanceAmount)
    {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(IERC20Minimal.allowance.selector, owner, spender));
        if (!success || data.length < 32) {
            revert ERC20AllowanceQueryFailed(token, owner, spender, data);
        }

        allowanceAmount = abi.decode(data, (uint256));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount, uint256 index) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!success) {
            revert ERC20TransferFailed(token, index, to, amount, data);
        }
        if (!_isSuccessfulERC20Return(data)) {
            revert ERC20InvalidReturn(token, index, to, amount, data);
        }
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
