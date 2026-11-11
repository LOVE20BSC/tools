// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IBatchTransferEvents {
    event NativeBatchTransferred(
        address indexed sender,
        uint256 totalAmount,
        uint256 recipientCount
    );
    event ERC20BatchTransferred(
        address indexed tokenAddress,
        address indexed sender,
        uint256 totalAmount,
        uint256 recipientCount
    );
}

interface IBatchTransferErrors {
    error EmptyBatch();
    error ArrayLengthMismatch(
        uint256 recipientsLength,
        uint256 amountsLength
    );
    error ZeroRecipient(uint256 index);
    error ZeroAmount(uint256 index);
    error NativeValueMismatch(
        uint256 expected,
        uint256 actual
    );
    error NativeTransferFailed(
        uint256 index,
        address recipient,
        uint256 amount,
        bytes32 errorHash,
        uint256 errorLength
    );
    error TokenNotContract(address tokenAddress);
    error ERC20BalanceQueryFailed(
        address tokenAddress,
        address account,
        bytes32 returnDataHash,
        uint256 returnDataLength
    );
    error ERC20AllowanceQueryFailed(
        address tokenAddress,
        address owner,
        address spender,
        bytes32 returnDataHash,
        uint256 returnDataLength
    );
    error ERC20InsufficientBalance(
        address tokenAddress,
        address owner,
        uint256 balance,
        uint256 required
    );
    error ERC20InsufficientAllowance(
        address tokenAddress,
        address owner,
        address spender,
        uint256 allowanceAmount,
        uint256 required
    );
    error ERC20TransferFailed(
        address tokenAddress,
        uint256 index,
        address recipient,
        uint256 amount,
        bytes32 errorHash,
        uint256 errorLength
    );
    error ERC20InvalidReturn(
        address tokenAddress,
        uint256 index,
        address recipient,
        uint256 amount,
        bytes32 returnDataHash,
        uint256 returnDataLength
    );
}

interface IBatchTransfer is IBatchTransferEvents, IBatchTransferErrors {
    function NATIVE_TRANSFER_GAS_LIMIT() external view returns (uint256);

    function batchTransferNative(address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        returns (uint256 totalAmount);

    function batchTransferERC20(address tokenAddress, address[] calldata recipients, uint256[] calldata amounts)
        external
        returns (uint256 totalAmount);

    function nativeBalances(address[] calldata accounts) external view returns (uint256[] memory balances);

    function erc20Balances(address tokenAddress, address[] calldata accounts)
        external
        view
        returns (uint256[] memory balances);
}
