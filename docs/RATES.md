# USDai Loan Router Rates and Fees

This document describes the interest rate models and supported fees in USDai
Loan Router.

## Parameters and State

Relevant loan parameters and state variables for interest rate models. All
interest rates are per-second rates.

| Loan Parameter            | Description             |
| :------------------------ | :---------------------- |
| `duration`                | Loan Duration           |
| `repaymentInterval`       | Loan Repayment Interval |
| `feeSpec.gracePeriodRate` | Grace Period Rate       |
| `trancheSpecs[0].amount`  | Tranche 1 Amount        |
| `trancheSpecs[0].rate`    | Tranche 1 Rate          |
| `trancheSpecs[1].amount`  | Tranche 2 Amount        |
| `trancheSpecs[1].rate`    | Tranche 2 Rate          |
| ...                       | ...                     |

| State Variable      | Description                                                |
| :------------------ | :--------------------------------------------------------- |
| `balance`           | Outstanding Loan Balance (Principal Remaining)             |
| `maturity`          | Loan Maturity Timestamp (Origination Timestamp + Duration) |
| `repaymentDeadline` | Current Repayment Deadline Timestamp                       |

## SimpleInterestRateModel

The `SimpleInterestRateModel` implements a loan repayment schedule
with fixed principal payments and simple interest.

### Principal Repayment Calculation

The repayment amount $P$, comprised of interest payment $P_i$ and
principal payment $P_p$, can be calculated from the outstanding loan balance
$B$, number of repayments remaining $M$, repayment interval $D_r$, and blended
interest rate $R$.

$$ M = \frac{\text{maturity} - \text{repaymentDeadline}}{\text{repaymentInterval}} + 1 $$

$$ R = \frac{\sum \text{trancheSpecs}[i]\text{.rate} \cdot \text{trancheSpecs}[i]\text{.amount}}{\sum \text{trancheSpecs}[i]\text{.amount}} $$

$$ P_i = B \cdot R \cdot D_r $$

$$ P_p = \frac{B}{M} $$

$$ P = P_i + P_p $$

Example with $10,000 principal, 15% interest rate, 12 repayments, and ~30 day repayment intervals:

```python
B = 10000.0                 # Loan Balance
R = 0.15 / (365 * 86400)    # Blended Interest Rate
D_r = (365 / 12) * 86400    # Repayment interval
N = 12                      # Total Number of Repayments

for i in range(N, 0, -1):
    P_i = B * R * D_r
    P_p = B / i
    P = P_i + P_p
    print(f"Balance: {B:<10.2f} P_i: {P_i:<10.2f} P_p: {P_p:<10.2f} P: {P:<10.2f}")
    B -= P_p

print(f"Balance: {B:<10.2f}")
```

```
Balance: 10000.00   P_i: 125.00     P_p: 833.33     P: 958.33
Balance: 9166.67    P_i: 114.58     P_p: 833.33     P: 947.92
Balance: 8333.33    P_i: 104.17     P_p: 833.33     P: 937.50
Balance: 7500.00    P_i: 93.75      P_p: 833.33     P: 927.08
Balance: 6666.67    P_i: 83.33      P_p: 833.33     P: 916.67
Balance: 5833.33    P_i: 72.92      P_p: 833.33     P: 906.25
Balance: 5000.00    P_i: 62.50      P_p: 833.33     P: 895.83
Balance: 4166.67    P_i: 52.08      P_p: 833.33     P: 885.42
Balance: 3333.33    P_i: 41.67      P_p: 833.33     P: 875.00
Balance: 2500.00    P_i: 31.25      P_p: 833.33     P: 864.58
Balance: 1666.67    P_i: 20.83      P_p: 833.33     P: 854.17
Balance: 833.33     P_i: 10.42      P_p: 833.33     P: 843.75
Balance: 0.00
```

### Tranche Distribution Calculations

The `SimpleInterestRateModel` assumes interest and principal payments are made
across all tranches evenly (i.e. not by seniority), treating them essentially
as independent amortized loans. The combined interest and principal payments
can be split according to the calculations below.

#### Tranche Interest Payments

Tranche interest payments are proportional to the combined interest payment by
their weighted rates.

For example, for two tranches with amounts $A_0$, $A_1$, and rates $R_0$, $R_1$, respectively:

$$ P\_{i0} = \frac{A_0}{A_0 + A_1} \cdot B \cdot R_0 \cdot D_r $$

$$ P\_{i1} = \frac{A_1}{A_0 + A_1} \cdot B \cdot R_1 \cdot D_r $$

$$ R = \frac{A_0 R_0 + A_1 R_1}{A_0 + A_1} $$

$$
\begin{aligned}
P_{i0} + P_{i1} &= \left( \frac{A_0 R_0}{A_0 + A_1} + \frac{A_1 R_1}{A_0 + A_1} \right) \cdot B \cdot D_r \\
                &= \left( \frac{A_0 R_0 + A_1 R_1}{A_0 + A_1} \right) \cdot B \cdot D_r \\
                &= B \cdot R \cdot D_r \\
                &= P_i
\end{aligned}
$$

$$
\begin{aligned}
P_{i0} / P_i &= \frac{ \frac{A_0}{A_0 + A_1} \cdot B \cdot R_0 \cdot D_r }{B \cdot R \cdot D_r} \\
             &= \frac{ \frac{A_0}{A_0 + A_1} \cdot R_0}{R} \\
             &= \frac{A_0 R_0}{A_0 + A_1} \frac{A_0 R_0 + A_1 R_1}{A_0 + A_1} \\
             &= \frac{A_0 R_0}{A_0 R_0 + A_1 R_1}
\end{aligned}
$$

#### Tranche Principal Payments

Tranche principal payments are proportional to the combined principal payment
by their tranche amounts.

$$ P\_{p} = \frac{B}{M} $$

$$ P\_{p0} = \frac{A_0}{A_0 + A_1} \cdot \frac{B}{M} $$

$$
\begin{aligned}
P_{p0} / P_p &= \frac{\frac{A_0}{A_0 + A_1} \cdot \frac{B}{M}}{\frac{B}{M}} \\
             &= \frac{A_0}{A_0 + A_1}
\end{aligned}
$$

## AmortizedInterestRateModel

The `AmortizedInterestRateModel` implements an amortized loan repayment
schedule with fixed overall repayments and simple interest.

### Fixed Repayment Calculation

The fixed repayment amount $P$, comprised of interest payment $P_i$ and
principal payment $P_p$, can be calculated from the outstanding loan balance
$B$, number of repayments remaining $M$, repayment interval $D_r$, and blended
interest rate $R$.

$$ M = \frac{\text{maturity} - \text{repaymentDeadline}}{\text{repaymentInterval}} + 1 $$

$$ R = \frac{\sum \text{trancheSpecs}[i]\text{.rate} \cdot \text{trancheSpecs}[i]\text{.amount}}{\sum \text{trancheSpecs}[i]\text{.amount}} $$

$$ P_i = B \cdot R \cdot D_r $$

$$ P_p = \frac{P_i}{(1 + R \cdot D_r)^M - 1} $$

$$ P = P_i + P_p $$

Example with $10,000 principal, 15% interest rate, 12 repayments, and ~30 day repayment intervals:

```python
B = 10000.0                 # Loan Balance
R = 0.15 / (365 * 86400)    # Blended Interest Rate
D_r = (365 / 12) * 86400    # Repayment interval
N = 12                      # Total Number of Repayments

for i in range(N, 0, -1):
    P_i = B * R * D_r
    P_p = P_i / ((1 + R * D_r)**i - 1)
    P = P_i + P_p
    print(f"Balance: {B:<10.2f} P_i: {P_i:<10.2f} P_p: {P_p:<10.2f} P: {P:<10.2f}")
    B -= P_p

print(f"Balance: {B:<10.2f}")
```

```
Balance: 10000.00   P_i: 125.00     P_p: 777.58     P: 902.58
Balance: 9222.42    P_i: 115.28     P_p: 787.30     P: 902.58
Balance: 8435.11    P_i: 105.44     P_p: 797.14     P: 902.58
Balance: 7637.97    P_i: 95.47      P_p: 807.11     P: 902.58
Balance: 6830.86    P_i: 85.39      P_p: 817.20     P: 902.58
Balance: 6013.66    P_i: 75.17      P_p: 827.41     P: 902.58
Balance: 5186.25    P_i: 64.83      P_p: 837.75     P: 902.58
Balance: 4348.50    P_i: 54.36      P_p: 848.23     P: 902.58
Balance: 3500.27    P_i: 43.75      P_p: 858.83     P: 902.58
Balance: 2641.44    P_i: 33.02      P_p: 869.57     P: 902.58
Balance: 1771.87    P_i: 22.15      P_p: 880.43     P: 902.58
Balance: 891.44     P_i: 11.14      P_p: 891.44     P: 902.58
Balance: -0.00
```

### Tranche Distribution Calculations

The `AmortizedInterestRateModel` assumes interest and principal payments are made
across all tranches evenly (i.e. not by seniority), treating them essentially
as independent amortized loans. The combined interest and principal payments
can be split according to the calculations below.

#### Tranche Interest Payments

Tranche interest payments are proportional to the combined interest payment by
their weighted rates, as in the `SimpleInterestRateModel`.

#### Tranche Principal Payments

Tranche principal payments are approximately, but not exactly, proportional to
the combined principal payment by their tranche amounts. To show this, we use
the Binomial approximation $(1 + x)^M \approx 1 + M x$:

$$
\begin{aligned}
P_{p0} / P_p &= \frac{\frac{P_{i0}}{(1 + R_0 \cdot D_r)^M - 1}}{\frac{P_i}{(1 + R \cdot D_r)^M - 1}} \\
             &= \frac{P_{i0}}{P_i} \frac{(1 + R \cdot D_r)^M - 1}{(1 + R_0 \cdot D_r)^M - 1} \\
             &\approx \frac{P_{i0}}{P_i} \frac{1 + M \cdot R \cdot D_r - 1}{1 + M \cdot R_0 \cdot D_r - 1} \\
             &= \frac{P_{i0}}{P_i} \frac{R}{R_0} \\
             &= \frac{A_0 R_0}{A_0 R_0 + A_1 R_1} \frac{\frac{A_0 R_0 + A_1 R_1}{A_0 + A_1}}{R_0} \\
             &= \frac{A_0}{A_0 R_0 + A_1 R_1} \frac{A_0 R_0 + A_1 R_1}{A_0 + A_1} \\
             &= \frac{A_0}{A_0 + A_1}
\end{aligned}
$$

## Repayment Conditions

#### On-Time Payment

Under the condition `block.timestamp < repaymentDeadline`, the repayment is
considered on-time and the repayment amount required is equal to `P`. The
`repaymentDeadline` is advanced by `repaymentInterval`.

#### Late Payment

Under the condition `block.timestamp > repaymentDeadline`, the repayment is
considered late, and the repayment amount required is a combination of missed
repayments and grace period interest. The `repaymentDeadline` is advanced by
`repaymentInterval * N_missed`.

$$ N\_{\text{missed}} = \lfloor \frac{\text{block.timestamp} - \text{repaymentDeadline}}{\text{repaymentInterval}} \rfloor + 1 $$

$$ I_{\text{grace}} = P \cdot R_{\text{grace}} \cdot (\text{block.timestamp} - \text{repaymentDeadline}) $$

$$ P_{\text{late}} = P \cdot N_{\text{missed}} + I\_{\text{grace}} $$

#### Additional or Excess Payment

Under the condition `block.timestamp < repaymentDeadline - repaymentInterval`,
or under the condition that the payment amount exceeds the required repayment,
the excess amount is used to directly reduce `balance`, which subsequently
reduces the overall interest owed and future repayment amounts. The
`repaymentDeadline` remains unchanged.

Excess payments are distributed to tranches proportionally.

## Fees

USDai Loan Router supports three optional fees. The fee recipient for all fees
is configured at the contract-level with the `setFeeRecipient()` API.

### Origination Fee

The origination fee is captured from the principal at loan origination in
`borrow()` and transferred to the fee recipient. The borrower is transferred
the loan principal less the origination fee.

### Exit Fee

The exit fee is captured on the final repayment in `repay()`, under the
condition that `repaymentDeadline == maturity`, and transferred to the fee
recipient.

### Liquidation Fee

The liquidation fee is captured from liquidation proceeds in
`onCollateralLiquidated()` and transferred to the fee recipient. The
liquidation fee rate is configured at the contract-level with the
`setLiquidationFeeRate()` API.
