# README

## wBLT Exercise Helper

- This contract simplifies the process of redeeming oTokens (such as oBMX) paired with wBLT for WETH, underlying,
  or for the wBLT-underlying LP.
- Typically, the `paymentToken` (in this case, wBLT) is needed up front for redemption. This contract uses flash loans
  to eliminate that requirement.
- View functions `quoteExerciseProfit`, `quoteExerciseToUnderlying`, and `quoteExerciseLp` are provided to be useful
  both internally and externally for estimations of output and optimal inputs.
- A 0.25% fee is sent to `feeAddress` on each exercise. Fee is adjustable between 0-1%.

### Testing

To run the test suite:

```
brownie test -s
```

To generate a coverage report:

```
brownie test --coverage
```

Then to visualize:

```
brownie gui
```

Note that ganache crashes when trying `exerciseToLp()`, so this test will only run using tenderly. Additionally, to
properly test both branches of our WETH balance checks in `exercise()` and `exerciseToLp()`, the tests note
that it is easiest to adjust the WETH threshold values on the specified lines. With these adjustments, all functions,
with the exception of `_safeTransfer`, `_safeTransferFrom`, and `getAmountIn` are (theoretically) 100% covered.

### Test Results

- All tests pass using a very similar framework adapted from
  [SimpleExerciseHelper](https://github.com/dudesahn/SimpleExerciseHelper) that achieves 100% coverage.
- Coverage testing fails...pretty much no matter what with Brownie.
