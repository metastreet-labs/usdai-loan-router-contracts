// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import {BaseTest} from "../Base.t.sol";
import {ILoanRouter} from "src/interfaces/ILoanRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LoanRouterLiquidateTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    /*------------------------------------------------------------------------*/
    /* Helper Functions */
    /*------------------------------------------------------------------------*/

    function _borrowLoan(
        uint256 principal,
        uint256 numTranches
    ) internal returns (ILoanRouter.LoanTerms memory) {
        uint256 originationFee = principal / 100; // 1%
        uint256 exitFee = principal / 200; // 0.5%

        ILoanRouter.LoanTerms memory loanTerms =
            createLoanTerms(users.borrower, principal, numTranches, originationFee, exitFee);

        // Lenders deposit to DepositTimelock
        bytes32 loanTermsHash = loanRouter.loanTermsHash(loanTerms);

        for (uint256 i = 0; i < numTranches; i++) {
            address lender = loanTerms.trancheSpecs[i].lender;
            vm.startPrank(lender);
            uint256 depositAmount = (loanTerms.trancheSpecs[i].amount * 10016 * 1e12) / 10000;
            depositTimelock.deposit(address(loanRouter), loanTermsHash, USDAI, depositAmount, loanTerms.expiration);
            vm.stopPrank();
        }

        // Borrower borrows funds
        vm.startPrank(users.borrower);

        ILoanRouter.LenderDepositInfo[] memory lenderDepositInfos = createDepositTimelockInfos(numTranches);

        loanRouter.borrow(loanTerms, lenderDepositInfos);

        vm.stopPrank();

        return loanTerms;
    }

    /**
     * @notice Helper function to complete liquidation by simulating the liquidator callback
     * @param loanTerms Loan terms
     * @param proceeds Liquidation proceeds to return
     */
    function _completeLiquidation(
        ILoanRouter.LoanTerms memory loanTerms,
        uint256 proceeds
    ) internal {
        // Fund the liquidator with proceeds (simulating successful auction)
        deal(USDC, ENGLISH_AUCTION_LIQUIDATOR, proceeds);

        // Impersonate the liquidator to call the callback
        vm.startPrank(ENGLISH_AUCTION_LIQUIDATOR);

        // Transfer proceeds to LoanRouter
        if (proceeds > 0) {
            IERC20(USDC).transfer(address(loanRouter), proceeds);
        }

        // Call onCollateralLiquidated callback
        loanRouter.onCollateralLiquidated(abi.encode(loanTerms), proceeds);

        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: liquidate() - Success Cases */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_AfterGracePeriod_SingleTranche() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get loan state before
        (ILoanRouter.LoanStatus statusBefore,, uint64 repaymentDeadline,) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(uint8(statusBefore), uint8(ILoanRouter.LoanStatus.Active), "Loan should be active");

        // Warp past grace period (repaymentDeadline + gracePeriodDuration + 1)
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set proceeds to 120% of principal (simulating profit on liquidation)
        uint256 proceeds = principal * 120 / 100;

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Verify loan status is Liquidated (before proceeds callback)
        (ILoanRouter.LoanStatus statusAfter,,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(uint8(statusAfter), uint8(ILoanRouter.LoanStatus.Liquidated), "Loan should be liquidated");

        // Record lender1 balance before
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);

        // Complete liquidation (send proceeds and call callback) - simulates separate transaction
        _completeLiquidation(loanTerms, proceeds);

        // Record lender1 balance after
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);

        // Lender1 should receive proceeds
        assertGt(lender1BalanceAfter - lender1BalanceBefore, principal, "Lender1 should receive proceeds");

        // Verify loan status is now CollateralLiquidated
        (statusAfter,,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(statusAfter),
            uint8(ILoanRouter.LoanStatus.CollateralLiquidated),
            "Loan should be collateral liquidated"
        );
    }

    function test__Liquidate_AfterGracePeriod_MultipleTranches() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 3);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set proceeds to 70% of principal
        uint256 proceeds = (principal * 70) / 100;

        // Record lender balances before
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2BalanceBefore = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3BalanceBefore = IERC20(USDC).balanceOf(users.lender3);
        uint256 feeRecipientBalanceBefore = IERC20(USDC).balanceOf(users.feeRecipient);

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify loan status is CollateralLiquidated (after callback)
        (ILoanRouter.LoanStatus statusAfter,,, uint256 balanceAfter) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(statusAfter),
            uint8(ILoanRouter.LoanStatus.CollateralLiquidated),
            "Loan should be collateral liquidated"
        );
        assertEq(balanceAfter, 0, "Loan balance should be zero");

        // Verify lenders received their share of proceeds
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2BalanceAfter = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3BalanceAfter = IERC20(USDC).balanceOf(users.lender3);
        uint256 feeRecipientBalanceAfter = IERC20(USDC).balanceOf(users.feeRecipient);

        // All lenders should receive something (proceeds distributed)
        assertGt(lender1BalanceAfter, lender1BalanceBefore, "Lender1 should receive proceeds");
        assertGt(lender2BalanceAfter, lender2BalanceBefore, "Lender2 should receive proceeds");

        // Fee recipient should receive liquidation fee
        assertGt(feeRecipientBalanceAfter, feeRecipientBalanceBefore, "Fee recipient should receive liquidation fee");

        // Total distributed should equal proceeds
        assertEq(
            lender1BalanceAfter - lender1BalanceBefore + lender2BalanceAfter - lender2BalanceBefore
                + feeRecipientBalanceAfter - feeRecipientBalanceBefore,
            proceeds,
            "Total distributed should equal proceeds"
        );

        // Lender3 should receive nothing
        assertEq(lender3BalanceAfter, lender3BalanceBefore, "Lender3 should receive nothing");
    }

    /*------------------------------------------------------------------------*/
    /* Test: liquidate() - Failure Cases */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_RevertIf_LoanNotActive() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms =
            createLoanTerms(users.borrower, principal, 1, principal / 100, principal / 200);

        // Try to liquidate before borrowing
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();
    }

    function test__Liquidate_RevertIf_WithinGracePeriod() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to within grace period (repaymentDeadline + 1 day, still within 30 day grace)
        vm.warp(repaymentDeadline + 1 days);

        // Try to liquidate
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();
    }

    function test__Liquidate_RevertIf_BeforeRepaymentDeadline() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Try to liquidate immediately after borrowing (before repayment deadline)
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: onCollateralLiquidated() - Success Cases */
    /*------------------------------------------------------------------------*/

    function test__OnCollateralLiquidated_PartialProceeds_DistributesProportionally() public {
        uint256 principal = 300_000 * 1e6; // 300k USDC
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 3);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set proceeds to only 50% of principal (severe loss)
        uint256 proceeds = (principal * 50) / 100;

        // Record balances before
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2BalanceBefore = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3BalanceBefore = IERC20(USDC).balanceOf(users.lender3);

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify lenders received proportional shares
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender2BalanceAfter = IERC20(USDC).balanceOf(users.lender2);
        uint256 lender3BalanceAfter = IERC20(USDC).balanceOf(users.lender3);

        uint256 lender1Gain = lender1BalanceAfter - lender1BalanceBefore;
        uint256 lender2Gain = lender2BalanceAfter - lender2BalanceBefore;

        // All lender1 and lender2 should receive something
        assertGt(lender1Gain, 0, "Lender1 should receive proceeds");
        assertGt(lender2Gain, 0, "Lender2 should receive proceeds");

        // Lender3 should receive nothing
        assertEq(lender3BalanceAfter, lender3BalanceBefore, "Lender3 should receive nothing");

        // Total distributed should be less than or equal to proceeds after fee
        uint256 liquidationFee = (proceeds * LIQUIDATION_FEE_RATE) / 10000;
        uint256 proceedsAfterFee = proceeds - liquidationFee;
        uint256 totalDistributed = lender1Gain + lender2Gain;
        assertEq(totalDistributed, proceedsAfterFee, "Total distributed should not exceed proceeds after fee");
    }

    function test__OnCollateralLiquidated_ZeroProceeds() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Record balances before
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);
        uint256 feeRecipientBalanceBefore = IERC20(USDC).balanceOf(users.feeRecipient);

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation with zero proceeds
        _completeLiquidation(loanTerms, 0);

        // Verify lender received nothing (or very little due to rounding)
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);
        assertEq(lender1BalanceAfter, lender1BalanceBefore, "Lender should receive nothing with zero proceeds");

        // Verify fee recipient received nothing
        uint256 feeRecipientBalanceAfter = IERC20(USDC).balanceOf(users.feeRecipient);
        assertEq(
            feeRecipientBalanceAfter,
            feeRecipientBalanceBefore,
            "Fee recipient should receive nothing with zero proceeds"
        );

        // Verify loan state is CollateralLiquidated with zero balance
        (ILoanRouter.LoanStatus statusAfter,,, uint256 balanceAfter) =
            loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(statusAfter),
            uint8(ILoanRouter.LoanStatus.CollateralLiquidated),
            "Loan should be collateral liquidated"
        );
        assertEq(balanceAfter, 0, "Loan balance should be zero");
    }

    /*------------------------------------------------------------------------*/
    /* Test: onCollateralLiquidated() - Failure Cases */
    /*------------------------------------------------------------------------*/

    function test__OnCollateralLiquidated_RevertIf_NotCalledByLiquidator() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Try to call onCollateralLiquidated directly (not from liquidator)
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidCaller.selector);
        loanRouter.onCollateralLiquidated(abi.encode(loanTerms), 100_000 * 1e6);
        vm.stopPrank();
    }

    function test__OnCollateralLiquidated_RevertIf_LoanNotLiquidated() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Loan is Active, not Liquidated - try to call callback
        vm.startPrank(ENGLISH_AUCTION_LIQUIDATOR);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.onCollateralLiquidated(abi.encode(loanTerms), 100_000 * 1e6);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: Liquidation Fee Distribution */
    /*------------------------------------------------------------------------*/

    function test__Liquidation_LiquidationFeeDistribution() public {
        uint256 principal = 100_000 * 1e6; // 100k USDC
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set proceeds to 80k USDC
        uint256 proceeds = 80_000 * 1e6;

        // Calculate expected liquidation fee (10%)
        uint256 expectedLiquidationFee = (proceeds * LIQUIDATION_FEE_RATE) / 10000;

        // Record fee recipient balance before
        uint256 feeRecipientBalanceBefore = IERC20(USDC).balanceOf(users.feeRecipient);
        uint256 lender1BalanceBefore = IERC20(USDC).balanceOf(users.lender1);

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify fee recipient received liquidation fee + remaining proceeds
        uint256 feeRecipientBalanceAfter = IERC20(USDC).balanceOf(users.feeRecipient);
        uint256 feeRecipientGain = feeRecipientBalanceAfter - feeRecipientBalanceBefore;

        // Fee recipient should receive at least the liquidation fee
        assertGe(feeRecipientGain, expectedLiquidationFee, "Fee recipient should receive at least liquidation fee");

        // Verify lender received proceeds after fee
        uint256 lender1BalanceAfter = IERC20(USDC).balanceOf(users.lender1);
        uint256 lender1Gain = lender1BalanceAfter - lender1BalanceBefore;

        // Lender + fee recipient should receive approximately all proceeds
        uint256 totalDistributed = lender1Gain + feeRecipientGain;
        assertApproxEqAbs(totalDistributed, proceeds, 2, "Total distributed should approximately equal proceeds");
    }

    /*------------------------------------------------------------------------*/
    /* Test: Edge Cases */
    /*------------------------------------------------------------------------*/

    function test__Liquidate_AtExactGracePeriodEnd() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 1);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp to EXACTLY at the end of grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION);

        // Set proceeds
        uint256 proceeds = 80_000 * 1e6;

        // Should revert because we need to be AFTER grace period
        vm.startPrank(users.liquidator);
        vm.expectRevert(ILoanRouter.InvalidLoanState.selector);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Warp 1 second past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Now it should work
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify loan was liquidated
        (ILoanRouter.LoanStatus status,,,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(status), uint8(ILoanRouter.LoanStatus.CollateralLiquidated), "Loan should be collateral liquidated"
        );
    }

    function test__Liquidate_VerySmallProceeds() public {
        uint256 principal = 100_000 * 1e6;
        ILoanRouter.LoanTerms memory loanTerms = _borrowLoan(principal, 3);

        // Get repayment deadline
        (,, uint64 repaymentDeadline,) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));

        // Warp past grace period
        vm.warp(repaymentDeadline + GRACE_PERIOD_DURATION + 1);

        // Set very small proceeds (1 USDC)
        uint256 proceeds = 1 * 1e6;

        // Call liquidate
        vm.startPrank(users.liquidator);
        loanRouter.liquidate(loanTerms);
        vm.stopPrank();

        // Complete liquidation
        _completeLiquidation(loanTerms, proceeds);

        // Verify loan was liquidated successfully despite tiny proceeds
        (ILoanRouter.LoanStatus status,,, uint256 balance) = loanRouter.loanState(loanRouter.loanTermsHash(loanTerms));
        assertEq(
            uint8(status), uint8(ILoanRouter.LoanStatus.CollateralLiquidated), "Loan should be collateral liquidated"
        );
        assertEq(balance, 0, "Loan balance should be zero");
    }
}
