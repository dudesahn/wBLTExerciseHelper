import brownie
from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
import pytest

# see the tracking.txt file for more info about adjusting cutoffs to better test different
#  branches of the two functions for exercising
def test_bmx_exercise_helper(
    obmx,
    bmx,
    bmx_exercise_helper,
    weth,
    w_blt,
    receive_underlying,
    obmx_whale,
    gauge,
    buy_underlying,
    w_blt_whale,
    bvm_router,
):
    # exercise a small amount
    obmx_before = obmx.balanceOf(obmx_whale)
    weth_before = weth.balanceOf(obmx_whale)
    bmx_before = bmx.balanceOf(obmx_whale)
    wblt_before = w_blt.balanceOf(obmx_whale)

    # test swapping in some wBLT for BMX (this should give us positive slippage)
    if buy_underlying:
        w_blt.approve(bvm_router, 2**256 - 1, {"from": w_blt_whale})
        w_blt_to_bmx = [(w_blt.address, bmx.address, False)]
        w_blt_to_swap = 15_000e18
        bvm_router.swapExactTokensForTokens(
            w_blt_to_swap,
            0,
            w_blt_to_bmx,
            w_blt_whale.address,
            2**256 - 1,
            {"from": w_blt_whale},
        )

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 9500  # in BPS
    swap_slippage = 100

    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})
    fee_before = weth.balanceOf(bmx_exercise_helper.feeAddress())

    if receive_underlying:
        result = bmx_exercise_helper.quoteExerciseToUnderlying(obmx, to_exercise, 0)
    else:
        result = bmx_exercise_helper.quoteExerciseProfit(obmx, to_exercise, 0)

    # use our preset slippage and amount
    print("Result w/ zero slippage", result.dict())
    real_slippage = (result["expectedProfit"] - result["realProfit"]) / result[
        "expectedProfit"
    ]
    print("Slippage (manually calculated):", "{:,.2f}%".format(real_slippage * 100))

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

    # exercise again, so we hit both sides of our checkAllowances
    bmx_exercise_helper.exercise(
        obmx,
        to_exercise,
        receive_underlying,
        profit_slippage,
        swap_slippage,
        {"from": obmx_whale},
    )


# note that this test MUST be run with something other than ganache
def test_bmx_exercise_helper_lp(
    obmx,
    bmx,
    bmx_exercise_helper,
    weth,
    w_blt,
    tests_using_tenderly,
    obmx_whale,
    gauge,
    buy_underlying,
    w_blt_whale,
    bvm_router,
    tests_using_anvil,
):
    # exerciseToLp for wBLT helper crashes ganache, rip
    if not tests_using_anvil and not tests_using_tenderly:
        print("\n🚨🚨 Need to use Anvil 🔨 or Tenderly 🥩 to test LP exercising 🚨🚨\n")
        return

    # exercise a small amount
    obmx_before = obmx.balanceOf(obmx_whale)
    weth_before = weth.balanceOf(obmx_whale)
    bmx_before = bmx.balanceOf(obmx_whale)
    wblt_before = w_blt.balanceOf(obmx_whale)
    lp_before = gauge.balanceOf(obmx_whale)

    # test swapping in some wBLT for BMX (this should give us positive slippage)
    if buy_underlying:
        w_blt.approve(bvm_router, 2**256 - 1, {"from": w_blt_whale})
        w_blt_to_bmx = [(w_blt.address, bmx.address, False)]
        w_blt_to_swap = 15_000e18
        bvm_router.swapExactTokensForTokens(
            w_blt_to_swap,
            0,
            w_blt_to_bmx,
            w_blt_whale.address,
            2**256 - 1,
            {"from": w_blt_whale},
        )

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_500e18
    profit_slippage = 9500  # in BPS
    swap_slippage = 100
    percent_to_lp = 100
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
    bvm_router,
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
    profit_slippage = 9500  # in BPS
    swap_slippage = 100
    percent_to_lp = 100
    discount = 35
    to_lp = int(1_000e18 * percent_to_lp / 10_000)

    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})

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
        bvm_router.swapExactTokensForTokens(
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


def test_bmx_exercise_helper_reverts(
    obmx,
    bmx_exercise_helper,
    weth,
    bmx,
    obmx_whale,
    gauge,
    screamsh,
    bmx_whale,
    bvm_router,
    w_blt,
    tests_using_anvil,
):
    # can't pull revert strings from write functions with anvil from some weird reason
    if tests_using_anvil:
        print(
            "\n🚨🚨 Can't use Anvil 🔨 when testing revert strings on write functions 🚨🚨\n"
        )
        return

    # control how much we exercise. larger size, more slippage
    to_exercise = 1_000e18
    profit_slippage = 1500  # in BPS
    swap_slippage = 100
    discount = 35
    percent_to_lp = 10_001

    # check our reverts for exercising
    with brownie.reverts("Can't exercise zero"):
        bmx_exercise_helper.quoteExerciseProfit(obmx, 0, profit_slippage)

    with brownie.reverts("Slippage must be less than 10,000"):
        bmx_exercise_helper.quoteExerciseProfit(obmx, to_exercise, 10_001)

    with brownie.reverts("Can't exercise zero"):
        bmx_exercise_helper.quoteExerciseToUnderlying(obmx, 0, profit_slippage)

    with brownie.reverts("Slippage must be less than 10,000"):
        bmx_exercise_helper.quoteExerciseToUnderlying(obmx, to_exercise, 10_001)

    with brownie.reverts("Percent must be < 10,000"):
        bmx_exercise_helper.quoteExerciseLp(
            obmx, to_exercise, profit_slippage, percent_to_lp, discount
        )

    percent_to_lp = 2500
    with brownie.reverts("Need more wBLT, decrease _percentToLp or _discount values"):
        bmx_exercise_helper.quoteExerciseLp(
            obmx, to_exercise, profit_slippage, percent_to_lp, discount
        )

    percent_to_lp = 600
    profit_slippage = 1
    obmx.approve(bmx_exercise_helper, 2**256 - 1, {"from": obmx_whale})
    with brownie.reverts("Profit slippage higher than allowed"):
        bmx_exercise_helper.exerciseToLp(
            obmx,
            to_exercise,
            profit_slippage,
            swap_slippage,
            percent_to_lp,
            discount,
            {"from": obmx_whale},
        )
    with brownie.reverts("Profit slippage higher than allowed"):
        bmx_exercise_helper.exercise(
            obmx,
            to_exercise,
            False,
            profit_slippage,
            swap_slippage,
            {"from": obmx_whale},
        )

    # receiveFlashLoan
    with brownie.reverts("Only balancer vault can call"):
        bmx_exercise_helper.receiveFlashLoan(
            [weth.address], [69e18], [0], "0x", {"from": obmx_whale}
        )

    balancer = accounts.at("0xBA12222222228d8Ba445958a75a0704d566BF2C8", force=True)
    with brownie.reverts("Flashloan not in progress"):
        bmx_exercise_helper.receiveFlashLoan(
            [weth.address], [69e18], [0], "0x", {"from": balancer}
        )

    # setFee
    bmx_exercise_helper.setFee(screamsh, 50, {"from": screamsh})
    with brownie.reverts("setFee: Fee max is 1%"):
        bmx_exercise_helper.setFee(screamsh, 101, {"from": screamsh})

    with brownie.reverts():
        bmx_exercise_helper.setFee(obmx_whale, 10, {"from": obmx_whale})

    # getAmountsIn
    with brownie.reverts("getAmountsIn: Path length must be >1"):
        bmx_exercise_helper.getAmountsIn(1e18, [weth.address], {"from": screamsh})

    with brownie.reverts("_getAmountIn: _amountOut must be >0"):
        bmx_exercise_helper.getAmountsIn(
            0, [weth.address, bmx.address], {"from": screamsh}
        )

    # max out allowed slippage so we don't revert on that
    to_exercise = 1_000e18
    profit_slippage = 10_000  # in BPS
    swap_slippage = 10_000
    discount = 35

    # dump the price to make it unprofitable to exercise
    bmx.approve(bvm_router, 2**256 - 1, {"from": bmx_whale})
    bmx_to_w_blt = [(bmx.address, w_blt.address, False)]
    bmx_to_swap = 500_000e18
    bvm_router.swapExactTokensForTokens(
        bmx_to_swap,
        0,
        bmx_to_w_blt,
        bmx_whale.address,
        2**256 - 1,
        {"from": bmx_whale},
    )

    # check more reverts for exercising
    with brownie.reverts("Cost exceeds profit"):
        bmx_exercise_helper.exerciseToLp(
            obmx,
            to_exercise,
            profit_slippage,
            swap_slippage,
            percent_to_lp,
            discount,
            {"from": obmx_whale},
        )

    with brownie.reverts("Cost exceeds profit"):
        bmx_exercise_helper.exercise(
            obmx,
            to_exercise,
            False,
            profit_slippage,
            swap_slippage,
            {"from": obmx_whale},
        )

    with brownie.reverts("Cost exceeds profit"):
        bmx_exercise_helper.exercise(
            obmx,
            to_exercise,
            True,
            profit_slippage,
            swap_slippage,
            {"from": obmx_whale},
        )

    with brownie.reverts("Cost exceeds profit"):
        bmx_exercise_helper.quoteExerciseProfit(obmx, to_exercise, profit_slippage)

    with brownie.reverts("Cost exceeds profit"):
        bmx_exercise_helper.quoteExerciseToUnderlying(
            obmx, to_exercise, profit_slippage
        )

    with brownie.reverts("Cost exceeds profit"):
        bmx_exercise_helper.quoteExerciseLp(
            obmx, to_exercise, profit_slippage, percent_to_lp, discount
        )
