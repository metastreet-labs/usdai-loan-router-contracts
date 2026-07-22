// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";
import {TestERC721} from "../mocks/TestERC721.sol";
import {LenderHookRecorder} from "../mocks/LenderHookRecorder.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {ILoanRouterV2Hooks} from "src/interfaces/ILoanRouterV2Hooks.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";

/**
 * @title Refinance test
 * @author USD.AI Foundation
 */
contract LoanRouterV2RefinanceTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /* Flat refinance fee of 100k USDai */
    uint256 internal constant REFINANCE_FEE = 100_000 * 1e18;

    /* Cash-out delta of 5M USDai */
    uint256 internal constant CASH_DELTA = 5_000_000 * 1e18;

    /*------------------------------------------------------------------------*/
    /* Originated loans */
    /*------------------------------------------------------------------------*/

    /* Originated loan under test */
    ILoanRouterV2.LoanTermsV2 internal loanA;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public override {
        /* Deploy the fresh router, timelocks, and roles */
        super.setUp();

        /* Originate the loan under test */
        loanA = originateDefault();

        /* Mock the mandatory lender refinance hook so the test isolates router accounting */
        vm.mockCall(STAKED_USDAI, abi.encodeWithSelector(ILoanRouterV2Hooks.onLoanRefinanced.selector), "");

        /* Let the tranche 0 lender fund cash-out deltas from the deposit timelock */
        vm.prank(users.deployer);
        IAccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), STAKED_USDAI);

        vm.prank(STAKED_USDAI);
        IERC20(USDAI).approve(address(depositTimelock), type(uint256).max);
    }

    /*------------------------------------------------------------------------*/
    /* Test: cash-out */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A cash-out draws the delta from the deposit timelock, pays the borrower, and resets the schedule
     */
    function test__RefinanceCashOut() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        uint256 newPrincipal = balance + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Capture the old loan hash */
        bytes32 oldHash = router.loanTermsHash(loanA);

        /* Read balances before refinancing */
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 timelockBefore = IERC20(USDAI).balanceOf(address(depositTimelock));

        /* Refinance without any borrower balance or approval */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Borrower receives the delta net of the fee */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), CASH_DELTA - REFINANCE_FEE, "borrower cash-out");

        /* Fee recipient receives the fee */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + REFINANCE_FEE, "fee recipient");

        /* Deposit timelock drained by the delta */
        assertEq(IERC20(USDAI).balanceOf(address(depositTimelock)), timelockBefore - CASH_DELTA, "timelock drained");

        /* New loan carries the new principal and resets the schedule */
        _assertNewLoanState(newTerms, newPrincipal);

        /* Old loan is repaid */
        (ILoanRouterV2.LoanStatus oldStatus,,,) = router.loanState(oldHash);

        assertEq(uint8(oldStatus), uint8(ILoanRouterV2.LoanStatus.Repaid), "old loan not repaid");
    }

    /**
     * @notice A cash-out resets the repayment count and origination to the refinance time
     */
    function test__RefinanceResetsScheduleState() public {
        /* Read the old loan origination and first deadline */
        bytes32 oldHash = router.loanTermsHash(loanA);

        (,, uint64 oldOrigination,) = router.loanState(oldHash);

        uint64 oldFirstDeadline = router.deadlines(loanA)[0];

        /* Warp to the first deadline without repaying so time has passed */
        vm.warp(oldFirstDeadline);

        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        uint256 newPrincipal = balance + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Read the new loan state */
        (, uint16 newCount, uint64 newOrigination,) = router.loanState(router.loanTermsHash(newTerms));

        /* Repayment count resets to zero */
        assertEq(newCount, 0, "repayment count not reset");

        /* Origination advances to the refinance time */
        assertEq(newOrigination, uint64(block.timestamp), "origination not set to refinance time");

        assertGt(newOrigination, oldOrigination, "origination not advanced");

        /* New schedule recomputes from the new origination */
        uint64[] memory newSchedule = router.deadlines(newTerms);

        uint64[] memory expectedSchedule = _scheduleAt(newTerms, uint64(block.timestamp));

        assertEq(newSchedule.length, expectedSchedule.length, "schedule length");

        /* The first deadline moves past the old first deadline */
        assertGt(newSchedule[0], oldFirstDeadline, "schedule not recomputed");
    }

    /*------------------------------------------------------------------------*/
    /* Test: lender hook */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Refinancing calls onLoanRefinanced on the tranche 0 lender with its index
     */
    function test__RefinanceNotifiesLenderHook() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        uint256 newPrincipal = balance + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Compute the old and new loan hashes */
        bytes32 oldHash = router.loanTermsHash(loanA);

        bytes32 newHash = router.loanTermsHash(newTerms);

        /* Expect the refinance hook on tranche 0 carrying its index */
        vm.expectCall(
            STAKED_USDAI,
            abi.encodeWithSelector(
                ILoanRouterV2Hooks.onLoanRefinanced.selector, loanA, newTerms, oldHash, newHash, uint8(0), CASH_DELTA, 0
            )
        );

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);
    }

    /*------------------------------------------------------------------------*/
    /* Test: allowed changes */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Refinancing may switch to a different interest rate model
     */
    function test__RefinanceChangesInterestRateModel() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        uint256 newPrincipal = balance + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Point the new terms at a fresh rate model */
        SimpleInterestRateModel newModel = new SimpleInterestRateModel();

        newTerms.interestRateSpec.model = address(newModel);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* New loan is active under the new model */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active), "new loan not active");
    }

    /**
     * @notice The new lender must be whoever currently holds the old position NFT
     */
    function test__RefinanceLenderFollowsPositionOwner() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Deploy a lender that supports the refinance hook and receives positions */
        LenderHookRecorder newLender = new LenderHookRecorder();

        /* Transfer the old tranche position to the new lender */
        uint256 oldTokenId = router.loanTokenIds(loanA)[0];

        vm.prank(STAKED_USDAI);
        router.transferFrom(STAKED_USDAI, address(newLender), oldTokenId);

        /* Grow the principal and set the tranche lender to the new holder */
        uint256 newPrincipal = balance + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        newTerms.trancheSpecs[0].lender = address(newLender);

        /* Let the new lender fund cash-out deltas from the deposit timelock */
        vm.prank(users.deployer);
        IAccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), address(newLender));

        /* Fund the new lender and approve the deposit timelock */
        deal(USDAI, address(newLender), CASH_DELTA);

        vm.prank(address(newLender));
        IERC20(USDAI).approve(address(depositTimelock), type(uint256).max);

        /* New lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* New position is minted to the new lender */
        uint256 newTokenId = router.loanTokenIds(newTerms)[0];

        assertEq(router.ownerOf(newTokenId), address(newLender), "new lender not position owner");
    }

    /*------------------------------------------------------------------------*/
    /* Test: fee and cash edge cases */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A cash-out with no fee spec pays the borrower the full delta
     */
    function test__RefinanceZeroFee() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        uint256 newPrincipal = balance + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Drop the fee spec so the refinance carries no fee */
        newTerms.feeSpecs = new ILoanRouterV2.FeeSpec[](0);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so only the cash-out reaches it */
        deal(USDAI, users.borrower, 0);

        /* Read balances before refinancing */
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 timelockBefore = IERC20(USDAI).balanceOf(address(depositTimelock));

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Borrower receives the full cash-out */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), CASH_DELTA, "borrower cash-out");

        /* Fee recipient receives nothing */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore, "fee recipient");

        /* Deposit timelock drained by the delta */
        assertEq(IERC20(USDAI).balanceOf(address(depositTimelock)), timelockBefore - CASH_DELTA, "timelock drained");

        /* New loan is active */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active), "new loan not active");
    }

    /**
     * @notice A cash-out that exactly covers the fee pays the borrower nothing
     */
    function test__RefinanceCashOutExactlyCoversFee() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by exactly the refinance fee */
        uint256 newPrincipal = balance + REFINANCE_FEE;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, REFINANCE_FEE);

        /* Zero the borrower so no borrower balance is available */
        deal(USDAI, users.borrower, 0);

        /* Read balances before refinancing */
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 timelockBefore = IERC20(USDAI).balanceOf(address(depositTimelock));

        /* Refinance without any borrower balance or approval */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Borrower receives nothing because the cash-out exactly covers the fee */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), 0, "borrower balance");

        /* Fee recipient receives the fee */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + REFINANCE_FEE, "fee recipient");

        /* Deposit timelock drained by the fee amount */
        assertEq(IERC20(USDAI).balanceOf(address(depositTimelock)), timelockBefore - REFINANCE_FEE, "timelock drained");
    }

    /**
     * @notice A ratio refinance fee is charged on the old balance, not the grown principal
     */
    function test__RefinanceFeeChargesOldBalance() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        uint256 newPrincipal = balance + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Replace the fee with a one percent ratio on the amount basis */
        RatioFeeModel ratioFeeModel = new RatioFeeModel();

        uint256 feeRate = FIXED_POINT_SCALE / 100;

        ILoanRouterV2.FeeSpec[] memory feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Refinance,
            recipient: address(0),
            model: address(ratioFeeModel),
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Amount, rate: feeRate}))
        });
        newTerms.feeSpecs = feeSpecs;

        /* The fee is one percent of the old balance, not the grown principal */
        uint256 expectedFee = Math.mulDiv(balance, feeRate, FIXED_POINT_SCALE, Math.Rounding.Ceil);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Read the fee recipient balance before refinancing */
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Fee recipient receives one percent of the old balance */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + expectedFee, "fee on old balance");

        /* Borrower receives the cash-out net of that fee */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), CASH_DELTA - expectedFee, "borrower cash-out net of fee");
    }

    /*------------------------------------------------------------------------*/
    /* Test: reverts */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A caller without the originator role cannot refinance
     */
    function test__RevertWhen_CallerNotRefinancer() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* An unauthorized account is rejected */
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Refinancing an already refinanced loan is rejected
     */
    function test__RevertWhen_OldLoanNotActive() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Refinance once, clearing the old loan */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Refinancing the cleared loan again reverts */
        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A reverting lender hook is no longer caught and reverts the refinance
     */
    function test__RevertWhen_LenderHookReverts() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Make the mandatory lender refinance hook revert */
        vm.mockCallRevert(
            STAKED_USDAI, abi.encodeWithSelector(ILoanRouterV2Hooks.onLoanRefinanced.selector), "hook reverted"
        );

        /* The refinance reverts because the hook is no longer caught */
        vm.prank(users.deployer);
        vm.expectRevert();
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the borrower is rejected
     */
    function test__RevertWhen_BorrowerChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Change the borrower */
        newTerms.borrower = users.lender2;

        /* The router rejects the changed borrower */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Borrower"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A stale expected balance from a last-minute prepay is rejected
     */
    function test__RevertWhen_ExpectedBalanceMismatch() public {
        /* Pay the first installment and read the quoted balance */
        uint256 balance = _payFirstInstallment(loanA);

        /* Build terms off the quoted balance */
        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Borrower prepays part of the principal after the quote was taken */
        _prepay(loanA, CASH_DELTA);

        /* The router rejects the now-stale expected balance */
        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidAmount.selector);
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Expired new loan terms are rejected
     */
    function test__RevertWhen_NewTermsExpired() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Set the expiration into the past */
        newTerms.expiration = uint64(block.timestamp - 1);

        /* The router rejects the expired terms */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Expiration"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the currency token is rejected
     */
    function test__RevertWhen_CurrencyTokenChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Change the currency token */
        newTerms.currencyToken = USDC;

        /* The router rejects the changed currency token */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Currency Token"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the collateral token is rejected
     */
    function test__RevertWhen_CollateralTokenChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Point the collateral token at a fresh NFT */
        TestERC721 otherCollateral = new TestERC721("Other", "OTH");

        newTerms.collateralToken = address(otherCollateral);

        /* The router rejects the changed collateral token */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Collateral Token"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the collateral token IDs is rejected
     */
    function test__RevertWhen_CollateralTokenIdsChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Swap in a different collateral token ID */
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = newTerms.collateralTokenIds[0] + 1;
        newTerms.collateralTokenIds = tokenIds;

        /* The router rejects the changed collateral token IDs */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Collateral Token IDs"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A zero interest rate model address is rejected
     */
    function test__RevertWhen_InterestRateModelZero() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Zero the interest rate model */
        newTerms.interestRateSpec.model = address(0);

        /* The router rejects the missing interest rate model */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Interest Rate Model"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A zero tranche rate is rejected
     */
    function test__RevertWhen_RateZero() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Zero the tranche rate */
        newTerms.trancheSpecs[0].rate = 0;

        /* The router rejects the zero rate */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Rate"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A tranche rate above the fixed point scale is rejected
     */
    function test__RevertWhen_RateAboveScale() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Push the tranche rate above the fixed point scale */
        newTerms.trancheSpecs[0].rate = FIXED_POINT_SCALE + 1;

        /* The router rejects the out of range rate */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Rate"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A zero tranche amount is rejected
     */
    function test__RevertWhen_TrancheAmountZero() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Zero the tranche amount */
        newTerms.trancheSpecs[0].amount = 0;

        /* The router rejects the zero tranche amount */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Tranche Amount"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A new principal too small to cover one unit per window is rejected
     */
    function test__RevertWhen_PrincipalTooSmall() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms =
            _buildNewTerms(loanA, RATE_10_PCT, balance + CASH_DELTA, REFINANCE_FEE);

        /* Shrink the tranche amount below the window count */
        newTerms.trancheSpecs[0].amount = 1;

        /* The router rejects the undersized principal */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Principal"));
        router.refinance(loanA, newTerms, balance);
    }

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Read the outstanding balance without repaying
     * @param terms Loan terms
     * @return balance Scaled outstanding balance
     */
    function _readBalance(
        ILoanRouterV2.LoanTermsV2 storage terms
    ) internal view returns (uint256 balance) {
        /* Return the stored outstanding balance */
        (,,, balance) = router.loanState(router.loanTermsHash(terms));
    }

    /**
     * @notice Pay the first scheduled installment and return the resulting balance
     * @param terms Loan terms
     * @return balance Scaled outstanding balance after the payment
     */
    function _payFirstInstallment(
        ILoanRouterV2.LoanTermsV2 storage terms
    ) internal returns (uint256 balance) {
        /* Read the deadline schedule */
        uint64[] memory schedule = router.deadlines(terms);

        /* Pay the first installment at its deadline */
        _repayAt(terms, schedule[0]);

        /* Return the outstanding balance */
        (,,, balance) = router.loanState(router.loanTermsHash(terms));
    }

    /**
     * @notice Prepay principal ahead of schedule
     * @param terms Loan terms
     * @param amount Amount to prepay
     */
    function _prepay(
        ILoanRouterV2.LoanTermsV2 storage terms,
        uint256 amount
    ) internal {
        /* Fund the borrower with the exact prepayment plus headroom */
        deal(USDAI, users.borrower, amount + 1e20);

        /* Approve and prepay as the borrower */
        vm.startPrank(users.borrower);
        IERC20(USDAI).approve(address(router), amount);
        router.repay(terms, amount);
        vm.stopPrank();
    }

    /**
     * @notice Build refinanced single-tranche terms with a new rate, principal, and fee
     * @param oldTerms Old loan terms
     * @param newRate New per-second rate scaled by 1e18
     * @param newPrincipal New tranche amount
     * @param refinanceFee Flat refinance fee
     * @return newTerms Refinanced loan terms
     */
    function _buildNewTerms(
        ILoanRouterV2.LoanTermsV2 storage oldTerms,
        uint256 newRate,
        uint256 newPrincipal,
        uint256 refinanceFee
    ) internal view returns (ILoanRouterV2.LoanTermsV2 memory newTerms) {
        /* Deep copy the old terms into memory */
        newTerms = oldTerms;

        /* Set the new tranche amount and rate */
        ILoanRouterV2.TrancheSpec[] memory tranches = new ILoanRouterV2.TrancheSpec[](1);
        tranches[0] =
            ILoanRouterV2.TrancheSpec({lender: oldTerms.trancheSpecs[0].lender, amount: newPrincipal, rate: newRate});
        newTerms.trancheSpecs = tranches;

        /* Attach the refinance fee spec */
        ILoanRouterV2.FeeSpec[] memory feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Refinance,
            recipient: address(0),
            model: address(absoluteFeeModel),
            options: abi.encode(AbsoluteFeeModel.Options({amount: refinanceFee}))
        });
        newTerms.feeSpecs = feeSpecs;

        /* Keep the new offer valid */
        newTerms.expiration = uint64(block.timestamp + 30 days);
    }

    /**
     * @notice Fund the tranche 0 cash-out delta into the deposit timelock from its lender
     * @param newTerms Refinanced loan terms
     * @param amount Cash-out delta
     */
    function _fundCashOut(
        ILoanRouterV2.LoanTermsV2 memory newTerms,
        uint256 amount
    ) internal {
        /* Compute the new loan terms hash */
        bytes32 newHash = router.loanTermsHash(newTerms);

        /* Read the tranche lender */
        address lender = newTerms.trancheSpecs[0].lender;

        /* Lender deposits the delta keyed to the router and new hash */
        vm.prank(lender);
        depositTimelock.deposit(
            address(router), newHash, newTerms.currencyToken, amount, uint64(block.timestamp + 7 days)
        );
    }

    /**
     * @notice Assert the new loan is active with the expected balance and a reset schedule
     * @param newTerms Refinanced loan terms
     * @param expectedBalance Expected scaled balance
     */
    function _assertNewLoanState(
        ILoanRouterV2.LoanTermsV2 memory newTerms,
        uint256 expectedBalance
    ) internal view {
        /* Read the new loan state */
        (ILoanRouterV2.LoanStatus status, uint16 count, uint64 origination, uint256 balance) =
            router.loanState(router.loanTermsHash(newTerms));

        /* New loan is active */
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active), "new loan not active");

        /* Balance equals the new principal */
        assertEq(balance, expectedBalance, "balance changed");

        /* Repayment count resets to zero */
        assertEq(count, 0, "repayment count not reset");

        /* Origination timestamp resets to the refinance time */
        assertEq(origination, uint64(block.timestamp), "origination not reset");

        /* Schedule recomputes from the new origination timestamp */
        uint64[] memory scheduleAfter = router.deadlines(newTerms);

        uint64[] memory scheduleExpected = _scheduleAt(newTerms, uint64(block.timestamp));

        assertEq(scheduleAfter.length, scheduleExpected.length, "schedule length changed");

        /* Every deadline matches the recomputed schedule */
        for (uint256 i; i < scheduleExpected.length; i++) {
            assertEq(scheduleAfter[i], scheduleExpected[i], "deadline mismatch");
        }
    }
}
