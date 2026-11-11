// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface IBatchTransferEvents {
    event NativeBatchTransfer(address indexed sender, uint256 totalAmount, uint256 recipientCount);
    event ERC20BatchTransfer(
        address indexed token, address indexed sender, uint256 totalAmount, uint256 recipientCount
    );
}

interface IBatchTransferErrors {
    error EmptyBatch();
    error ArrayLengthMismatch(uint256 recipientsLength, uint256 amountsLength);
    error ZeroRecipient(uint256 index);
    error ZeroAmount(uint256 index);
    error NativeValueMismatch(uint256 expected, uint256 actual);
    error NativeTransferFailed(uint256 index, address recipient, uint256 amount, bytes reason);
    error InvalidToken(address token);
    error ERC20BalanceQueryFailed(address token, address account, bytes data);
    error ERC20AllowanceQueryFailed(address token, address owner, address spender, bytes data);
    error ERC20InsufficientBalance(address token, address owner, uint256 balance, uint256 required);
    error ERC20InsufficientAllowance(
        address token, address owner, address spender, uint256 allowanceAmount, uint256 required
    );
    error ERC20TransferFailed(address token, uint256 index, address recipient, uint256 amount, bytes reason);
    error ERC20InvalidReturn(address token, uint256 index, address recipient, uint256 amount, bytes returnData);
}

interface IBatchTransfer is IBatchTransferEvents, IBatchTransferErrors {
    function NATIVE_TRANSFER_GAS_LIMIT() external view returns (uint256);

    function batchTransferNative(address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        returns (uint256 totalAmount);

    function batchTransferERC20(address token, address[] calldata recipients, uint256[] calldata amounts)
        external
        returns (uint256 totalAmount);

    function nativeBalances(address[] calldata accounts) external view returns (uint256[] memory balances);

    function erc20Balances(address token, address[] calldata accounts)
        external
        view
        returns (uint256[] memory balances);
}
