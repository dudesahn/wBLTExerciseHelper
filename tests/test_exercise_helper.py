from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
import pytest


def test_bmx_exercise_helper(
    obmx,
    bmx,
    bmx_exercise_helper,
    weth,
    w_blt,
    receive_underlying,
    obmx_whale,
    gauge,
):
    # exercise a small amount
    obmx_before = obmx.balanceOf(obmx_whale)
    weth_before = weth.balanceOf(obmx_whale)
    bmx_before = bmx.balanceOf(obmx_whale)
    wblt_before = w_blt.balanceOf(obmx_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 50

    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})
    fee_before = weth.balanceOf(bmx_exercise_helper.feeAddress())

    # use our preset slippage and amount
    if receive_underlying:
        result = bmx_exercise_helper.quoteExerciseToUnderlying(obmx, to_exercise, 0)
    else:
        result = bmx_exercise_helper.quoteExerciseProfit(obmx, to_exercise, 0)
    print("Result w/ zero slippage", result.dict())
    real_slippage = (result["expectedProfit"] - result["realProfit"]) / result[
        "expectedProfit"
    ]
    print("Slippage (manually calculated):", "{:,.2f}%".format(real_slippage * 100))

    # use our preset slippage and amount
    bmx_exercise_helper.exercise(
        obmx,
        to_exercise,
        receive_underlying,
        profit_slippage,
        swap_slippage,
        {"from": obmx_whale},
    )

    if receive_underlying:
        assert bmx_before < bmx.balanceOf(obmx_whale)
        profit = bmx.balanceOf(obmx_whale) - bmx_before
    else:
        assert weth_before < weth.balanceOf(obmx_whale)
        profit = weth.balanceOf(obmx_whale) - weth_before

    assert obmx.balanceOf(obmx_whale) == obmx_before - to_exercise
    fees = weth.balanceOf(bmx_exercise_helper.feeAddress()) - fee_before

    assert bmx.balanceOf(bmx_exercise_helper) == 0
    assert weth.balanceOf(bmx_exercise_helper) == 0
    assert w_blt.balanceOf(bmx_exercise_helper) == 0
    assert obmx.balanceOf(bmx_exercise_helper) == 0
    assert gauge.balanceOf(bmx_exercise_helper) == 0

    weth_received = weth.balanceOf(obmx_whale) - weth_before
    wblt_received = w_blt.balanceOf(obmx_whale) - wblt_before
    bmx_received = bmx.balanceOf(obmx_whale) - bmx_before

    if receive_underlying:
        print(
            "\n🥟 Dumped",
            "{:,.2f}".format(to_exercise / 1e18),
            "oBMX for",
            "{:,.5f}".format(profit / 1e18),
            "BMX 👻",
        )
        print("Received", wblt_received / 1e18, "wBLT")
        print("Received", weth_received / 1e18, "WETH")
    else:
        print(
            "\n🥟 Dumped",
            "{:,.2f}".format(to_exercise / 1e18),
            "oBMX for",
            "{:,.5f}".format(profit / 1e18),
            "WETH 👻",
        )
        print("Received", wblt_received / 1e18, "wBLT")
        print("Received", bmx_received / 1e18, "BMX")
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WETH in fees\n")


def test_bmx_exercise_helper_lp(
    obmx, bmx, bmx_exercise_helper, weth, w_blt, tests_using_tenderly, obmx_whale, gauge
):
    # exerciseToLp for wBLT helper crashes ganche, rip
    if not tests_using_tenderly:
        return

    # exercise a small amount
    obmx_before = obmx.balanceOf(obmx_whale)
    weth_before = weth.balanceOf(obmx_whale)
    bmx_before = bmx.balanceOf(obmx_whale)
    wblt_before = w_blt.balanceOf(obmx_whale)
    lp_before = gauge.balanceOf(obmx_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_500e18
    profit_slippage = 800  # in BPS
    swap_slippage = 50
    percent_to_lp = 755
    discount = 35

    # to_exercise = 500e18. percent_to_lp =  500 = 0.21367%, 701 = , 751 = 0.20803%, 755 = 0.20794%
    # to_exercise = 1_000e18. percent_to_lp = 751 = 0.4152%, 701 = 0.41744%, 500 = 0.4264%, 755 = 0.41502%
    # to_exercise = 1_500e18. percent_to_lp =  500 = , 701 = , 751 = , 755 = 0.62125%, 760 = 0.62091%, 762 = 0.62078% (any higher reverts, ~.25 wBLT returned)
    # to_exercise = 3_000e18. percent_to_lp =  500 = 1.26845%, 701 = , 751 = , 755 = 1.23482%

    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})
    fee_before = weth.balanceOf(bmx_exercise_helper.feeAddress())

    # first check exercising our LP
    output = bmx_exercise_helper.quoteExerciseLp(
        obmx, to_exercise, profit_slippage, percent_to_lp, discount
    )
    print("\nLP view output:", output.dict())
    print("Slippage:", output["profitSlippage"] / 1e18)
    print("Estimated LP Out:", output["lpAmountOut"] / 1e18)
    print("Estimated Extra wBLT:", output["wBLTOut"] / 1e18)

    # DO WE EXPERIENCE EXTRA SLIPPAGE HERE BECAUSE WE DUMP BMX IN THE PROCESS BEFORE EXERCISING TO LP? ************
    # estimated amount of LP is higher than the amount we actually get, but we get more wBLT than we estimate

    # use our preset slippage and amount
    bmx_exercise_helper.exerciseToLp(
        obmx,
        to_exercise,
        profit_slippage,
        swap_slippage,
        percent_to_lp,
        discount,
        {"from": obmx_whale},
    )

    assert obmx.balanceOf(obmx_whale) == obmx_before - to_exercise

    fees = weth.balanceOf(bmx_exercise_helper.feeAddress()) - fee_before

    assert bmx.balanceOf(bmx_exercise_helper) == 0
    assert weth.balanceOf(bmx_exercise_helper) == 0
    assert w_blt.balanceOf(bmx_exercise_helper) == 0
    assert obmx.balanceOf(bmx_exercise_helper) == 0

    weth_received = weth.balanceOf(obmx_whale) - weth_before
    wblt_received = w_blt.balanceOf(obmx_whale) - wblt_before
    bmx_received = bmx.balanceOf(obmx_whale) - bmx_before
    lp_received = gauge.balanceOf(obmx_whale) - lp_before

    print(
        "LP % slippage:",
        "{:,.5f}%".format(
            100 * ((output["lpAmountOut"] - lp_received) / output["lpAmountOut"])
        ),
    )

    print("\nReceived", weth_received / 1e18, "WETH")  # $1600
    print("Received", wblt_received / 1e18, "wBLT")  # $1.03
    print("Received", bmx_received / 1e18, "BMX")  # $0.55
    print("LP Received:", lp_received / 1e18)  # $1.52941176471
    print("\n🤑 Took", "{:,.9f}".format(fees / 1e18), "WETH in fees\n")


def test_bmx_exercise_helper_lp_weird(
    obmx,
    bmx,
    bmx_exercise_helper,
    weth,
    router,
    w_blt,
    tests_using_tenderly,
    obmx_whale,
    gauge,
):
    # we use tx.return_value here, and tenderly doesn't like that
    if tests_using_tenderly:
        return

    # exercise a small amount
    obmx_before = obmx.balanceOf(obmx_whale)
    weth_before = weth.balanceOf(obmx_whale)
    bmx_before = bmx.balanceOf(obmx_whale)
    wblt_before = w_blt.balanceOf(obmx_whale)
    lp_before = gauge.balanceOf(obmx_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 800  # in BPS
    swap_slippage = 50
    percent_to_lp = 650
    discount = 35
    to_lp = int(1_000e18 * percent_to_lp / 10_000)

    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})
    fee_before = weth.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a")

    # first check exercising our LP
    output = bmx_exercise_helper.quoteExerciseLp(
        obmx, to_exercise, profit_slippage, percent_to_lp, discount
    )
    print("\nLP view output:", output.dict())
    print("Slippage:", output["profitSlippage"] / 1e18)
    print("Estimated LP Out:", output["lpAmountOut"] / 1e18)
    print("Estimated Extra wBLT:", output["wBLTOut"] / 1e18)

    output = obmx.getPaymentTokenAmountForExerciseLp(to_lp, discount)
    print(
        "Simulation:",
        output.dict(),
        output["paymentAmount"] + output["paymentAmountToAddLiquidity"],
    )

    # test swapping in some BMX for wBLT
    dump_some_bmx = False
    if dump_some_bmx:
        bmx.approve(router, 2**256 - 1, {"from": obmx_whale})
        bmx_to_w_blt = [(bmx.address, w_blt.address, False)]
        bmx_to_swap = bmx.balanceOf(obmx_whale)
        router.swapExactTokensForTokens(
            bmx_to_swap,
            0,
            bmx_to_w_blt,
            obmx_whale.address,
            2**256 - 1,
            {"from": obmx_whale},
        )

    w_blt.approve(obmx, 2**256 - 1, {"from": obmx_whale})
    tx = obmx.exerciseLp(
        to_lp, 2**256 - 1, obmx_whale, discount, 2**256 - 1, {"from": obmx_whale}
    )
    print("Real thing:", tx.return_value)
    obmx_after = obmx.balanceOf(obmx_whale)
    assert obmx_before - obmx_after == to_lp
