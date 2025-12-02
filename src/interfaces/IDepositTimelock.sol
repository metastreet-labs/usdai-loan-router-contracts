// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Deposit Timelock Interface
 * @author USD.AI Foundation
 */
interface IDepositTimelock {
    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid amount
     */
    error InvalidAmount();

    /**
     * @notice Invalid deposit
     */
    error InvalidDeposit();

    /**
     * @notice Invalid address
     */
    error InvalidAddress();

    /**
     * @notice Invalid bytes32
     */
    error InvalidBytes32();

    /**
     * @notice Invalid timestamp
     */
    error InvalidTimestamp();

    /**
     * @notice Unsupported token
     */
    error UnsupportedToken();

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when deposit is made
     * @param depositor Depositor address
     * @param target Target contract that can withdraw
     * @param context Context identifier
     * @param token Token address
     * @param amount Amount deposited
     * @param expiration Expiration timestamp
     */
    event Deposited(
        address indexed depositor,
        address indexed target,
        bytes32 indexed context,
        address token,
        uint256 amount,
        uint64 expiration
    );

    /**
     * @notice Emitted when deposit is canceled
     * @param depositor Depositor address
     * @param target Target contract
     * @param context Context identifier
     * @param amount Amount returned
     */
    event Canceled(address indexed depositor, address indexed target, bytes32 indexed context, uint256 amount);

    /**
     * @notice Emitted when deposit is withdrawn
     * @param depositor Depositor address
     * @param withdrawer Withdrawer address
     * @param context Context identifier
     * @param depositToken Deposit token address
     * @param withdrawToken Withdraw token address
     * @param depositAmount Deposit amount
     * @param withdrawAmount Withdraw amount
     * @param refundDepositAmount Deposit amount refunded
     * @param refundWithdrawAmount Withdraw amount refunded
     */
    event Withdrawn(
        address indexed depositor,
        address indexed withdrawer,
        bytes32 indexed context,
        address depositToken,
        address withdrawToken,
        uint256 depositAmount,
        uint256 withdrawAmount,
        uint256 refundDepositAmount,
        uint256 refundWithdrawAmount
    );

    /**
     * @notice Emitted when swap adapter is added
     * @param token Token address
     * @param swapAdapter Swap adapter address
     */
    event SwapAdapterAdded(address indexed token, address indexed swapAdapter);

    /**
     * @notice Emitted when swap adapter is removed
     * @param token Token address
     */
    event SwapAdapterRemoved(address indexed token);

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get deposit token ID
     * @param depositor Depositor address
     * @param target Target address
     * @param context Context
     * @return Deposit token ID
     */
    function depositTokenId(
        address depositor,
        address target,
        bytes32 context
    ) external pure returns (uint256);

    /**
     * @notice Get deposit information
     * @param tokenId Token ID
     * @return depositor Depositor address
     * @return target Target contract address
     * @return context Context identifier
     * @return token Token address
     * @return amount Amount deposited
     * @return expiration Expiration timestamp
     */
    function depositInfo(
        uint256 tokenId
    )
        external
        view
        returns (address depositor, address target, bytes32 context, address token, uint256 amount, uint64 expiration);

    /*------------------------------------------------------------------------*/
    /* Depositor API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit tokens with timelock
     * @param target Target contract that can withdraw
     * @param context Context identifier
     * @param token Token address
     * @param amount Amount to deposit
     * @param expiration Expiration timestamp
     */
    function deposit(
        address target,
        bytes32 context,
        address token,
        uint256 amount,
        uint64 expiration
    ) external;

    /**
     * @notice Cancel deposit after expiration
     * @param target Target contract
     * @param context Context identifier
     * @return Amount returned
     */
    function cancel(
        address target,
        bytes32 context
    ) external returns (uint256);

    /*------------------------------------------------------------------------*/
    /* Withdrawer API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Withdraw deposit (only callable by target before expiration)
     * @param context Context identifier
     * @param depositor Depositor address
     * @param withdrawToken Token to withdraw
     * @param amount Minimum amount to withdraw
     * @param swapData Swap data
     * @return Withdraw amount
     */
    function withdraw(
        bytes32 context,
        address depositor,
        address withdrawToken,
        uint256 amount,
        bytes calldata swapData
    ) external returns (uint256);

    /*------------------------------------------------------------------------*/
    /* Permissioned API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Add swap adapter
     * @param token Token address
     * @param swapAdapter Swap adapter address
     */
    function addSwapAdapter(
        address token,
        address swapAdapter
    ) external;

    /**
     * @notice Remove swap adapter
     * @param token Token address
     */
    function removeSwapAdapter(
        address token
    ) external;
}
