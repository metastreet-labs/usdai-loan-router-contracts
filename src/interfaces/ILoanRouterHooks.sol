// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILoanRouter} from "./ILoanRouter.sol";

/**
 * @title Loan Router Callback Hooks
 * @author MetaStreet Foundation
 */
interface ILoanRouterHooks {
    /*------------------------------------------------------------------------*/
    /* Public API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Called when loan is originated
     * @param loanTerms Loan terms
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     */
    function onLoanOriginated(
        ILoanRouter.LoanTerms calldata loanTerms,
        bytes32 loanTermsHash,
        uint8 trancheIndex
    ) external;

    /**
     * @notice Called when lender is repaid
     * @param loanTerms Loan terms
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     * @param loanBalance Loan balance
     * @param principal Principal amount
     * @param interest Interest amount
     * @param prepay Prepay amount
     */
    function onLoanRepayment(
        ILoanRouter.LoanTerms calldata loanTerms,
        bytes32 loanTermsHash,
        uint8 trancheIndex,
        uint256 loanBalance,
        uint256 principal,
        uint256 interest,
        uint256 prepay
    ) external;

    /**
     * @notice Called when loan is liquidated
     * @param loanTerms Loan terms
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     */
    function onLoanLiquidated(
        ILoanRouter.LoanTerms calldata loanTerms,
        bytes32 loanTermsHash,
        uint8 trancheIndex
    ) external;

    /**
     * @notice Called when loan collateral is liquidated
     * @param loanTerms Loan terms
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     * @param principal Principal amount
     * @param interest Interest amount
     */
    function onLoanCollateralLiquidated(
        ILoanRouter.LoanTerms calldata loanTerms,
        bytes32 loanTermsHash,
        uint8 trancheIndex,
        uint256 principal,
        uint256 interest
    ) external;
}
