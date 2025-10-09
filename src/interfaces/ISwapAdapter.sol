// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Swap Adapter Interface
 * @author MetaStreet Foundation
 */
interface ISwapAdapter {
    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Swapped out event
     * @param inputToken Input token
     * @param outputToken Output token
     * @param inputAmount Input amount
     * @param outputAmount Output amount
     */
    event Swapped(address indexed inputToken, address indexed outputToken, uint256 inputAmount, uint256 outputAmount);

    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Swap input token for exact output amount of output token
     * @param inputToken Input token
     * @param outputToken Output token
     * @param inputAmount Input amount
     * @param outputAmount Output amount
     * @param path Swap path
     * @return Output amount
     * @return Refund input amount
     * @return Refund output amount
     */
    function swap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes calldata path
    ) external returns (uint256, uint256, uint256);
}
