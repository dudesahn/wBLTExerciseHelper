// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {Ownable2Step} from "@openzeppelin/contracts@4.9.3/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";

interface IoToken is IERC20 {
    function exercise(
        uint256 amount,
        uint256 maxPaymentAmount,
        address recipient
    ) external returns (uint256);

    function getDiscountedPrice(uint256 amount) external view returns (uint256);

    function discount() external view returns (uint256);

    function underlyingToken() external view returns (address);

    function getPaymentTokenAmountForExerciseLp(
        uint256 amount,
        uint256 discount
    )
        external
        view
        returns (uint256 paymentAmount, uint256 paymentAmountToAddLiquidity);

    function exerciseLp(
        uint256 amount,
        uint256 maxPaymentAmount,
        address recipient,
        uint256 discount,
        uint256 deadline
    ) external returns (uint256, uint256);
}

interface IBalancer {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IPairFactory {
    function getFee(address pair) external view returns (uint256);

    function getPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address);
}

interface IRouter {
    struct Route {
        address from;
        address to;
        bool stable;
    }

    function getReserves(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (uint256 reserve0, uint256 reserve1);

    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        bool stable
    ) external view returns (uint256 amount);

    function getAmountsOut(
        uint256 amountIn,
        Route[] memory routes
    ) external view returns (uint256[] memory amounts);

    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired
    )
        external
        view
        returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function quoteMintAmountBLT(
        address _underlyingToken,
        uint256 _bltAmountNeeded
    ) external view returns (uint256);

    function quoteRedeemAmountBLT(
        address _underlyingToken,
        uint256 _amount
    ) external view returns (uint256 wBLTAmount);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSimple(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title wBLT Exercise Helper
 * @notice This contract easily converts oTokens that are paired with wBLT
 *  (such as oBMX) to WETH, underlying, or underlying-wBLT LP token using flash loans.
 */

contract wBLTExerciseHelper is Ownable2Step {
    /// @notice WETH, payment token
    IERC20 internal constant weth =
        IERC20(0x4200000000000000000000000000000000000006);

    /// @notice Wrapped BLT, our auto-compounding LP vault token
    IERC20 internal constant wBLT =
        IERC20(0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A);

    /// @notice Flashloan from Balancer vault
    IBalancer internal constant balancerVault =
        IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @notice BMX router for swaps
    IRouter internal constant router =
        IRouter(0xf5A008cA68870f223cd76E31248Cd04aF6cb9AF3);

    /// @notice BVM standard router, used for a few functions missing from BMX router
    IRouter internal constant bvmRouter =
        IRouter(0xE11b93B61f6291d35c5a2beA0A9fF169080160cF);

    /// @notice Pair factory, use this to check the current swap fee on a given pool
    IPairFactory internal constant pairFactory =
        IPairFactory(0xe21Aac7F113Bd5DC2389e4d8a8db854a87fD6951);

    /// @notice Check whether we are in the middle of a flashloan (used for callback)
    bool public flashEntered;

    /// @notice Used to track the deployed version of this contract.
    string public constant apiVersion = "0.2.0";

    /// @notice Where we send our 0.25% fee
    address public feeAddress = 0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a;

    uint256 public fee = 25;

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant DISCOUNT_DENOMINATOR = 100;

    /// @notice Route for selling wBLT -> WETH
    IRouter.Route[] internal wBltToWeth;

    /// @notice Route for selling WETH -> wBLT
    IRouter.Route[] internal wethToWblt;

    constructor() {
        // setup our routes
        wBltToWeth.push(IRouter.Route(address(wBLT), address(weth), false));
        wethToWblt.push(IRouter.Route(address(weth), address(wBLT), false));

        // do necessary approvals
        weth.approve(address(router), type(uint256).max);
        wBLT.approve(address(router), type(uint256).max);
    }

    /**
     * @notice Check if spot swap price and exercising are similar enough for our liking.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to WETH.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @return wethNeeded How much WETH is needed for given amount of oToken.
     * @return withinSlippageTolerance Whether expected vs real profit fall within our
     *  slippage tolerance.
     * @return realProfit Simulated profit in WETH after repaying flash loan.
     * @return expectedProfit Calculated ideal profit based on redemption discount plus
     *  allowed slippage.
     * @return profitSlippage Expected profit slippage with given oToken amount, 18
     *  decimals. Zero means extra profit (positive slippage).
     */
    function quoteExerciseProfit(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed
    )
        public
        view
        returns (
            uint256 wethNeeded,
            bool withinSlippageTolerance,
            uint256 realProfit,
            uint256 expectedProfit,
            uint256 profitSlippage
        )
    {
        if (_optionTokenAmount == 0) {
            revert("Can't exercise zero");
        }
        if (_profitSlippageAllowed > MAX_BPS) {
            revert("Slippage must be less than 10,000");
        }

        // calculate how much WETH we need for our oToken amount
        // we need this many wBLT for a given amount of oToken
        uint256 wBLTNeeded = IoToken(_oToken).getDiscountedPrice(
            _optionTokenAmount
        );
        // we need this much WETH to mint that much wBLT
        wethNeeded = router.quoteMintAmountBLT(address(weth), wBLTNeeded);

        IRouter.Route[] memory tokenToWeth = new IRouter.Route[](2);
        tokenToWeth[0] = IRouter.Route(
            IoToken(_oToken).underlyingToken(),
            address(wBLT),
            false
        );
        tokenToWeth[1] = IRouter.Route(address(wBLT), address(weth), false);

        // compare our WETH needed to spot price
        uint256[] memory amounts = router.getAmountsOut(
            _optionTokenAmount,
            tokenToWeth
        );
        uint256 wethReceived = amounts[2];
        uint256 estimatedFee = (wethReceived * fee) / MAX_BPS;

        // make sure we don't spend more than we have
        if (wethNeeded > wethReceived - estimatedFee) {
            revert("Cost exceeds profit");
        } else {
            realProfit = wethReceived - wethNeeded - estimatedFee;
        }

        // calculate our ideal profit using the discount and known wethNeeded
        uint256 discount = IoToken(_oToken).discount();
        expectedProfit =
            ((wethNeeded * (DISCOUNT_DENOMINATOR - discount)) / discount) -
            estimatedFee;

        // if profitSlippage returns zero, we have positive slippage (extra profit)
        if (expectedProfit > realProfit) {
            profitSlippage = 1e18 - ((realProfit * 1e18) / expectedProfit);
        }

        // allow for our expected slippage as well
        expectedProfit =
            (expectedProfit * (MAX_BPS - _profitSlippageAllowed)) /
            MAX_BPS;

        // check if real profit is greater than expected when allowing for slippage
        if (realProfit > expectedProfit) {
            withinSlippageTolerance = true;
        }
    }

    /**
     * @notice Check if spot swap price and exercising are similar enough for our liking.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to underlying.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @return wethNeeded How much WETH is needed for given amount of oToken.
     * @return withinSlippageTolerance Whether expected vs real profit fall within our
     *  slippage tolerance.
     * @return realProfit Simulated profit in underlying after repaying flash loan.
     * @return expectedProfit Calculated ideal profit based on redemption discount plus
     *  allowed slippage.
     * @return profitSlippage Expected profit slippage with given oToken amount, 18
     *  decimals. Zero means extra profit (positive slippage).
     */
    function quoteExerciseToUnderlying(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed
    )
        public
        view
        returns (
            uint256 wethNeeded,
            bool withinSlippageTolerance,
            uint256 realProfit,
            uint256 expectedProfit,
            uint256 profitSlippage
        )
    {
        if (_optionTokenAmount == 0) {
            revert("Can't exercise zero");
        }
        if (_profitSlippageAllowed > MAX_BPS) {
            revert("Slippage must be less than 10,000");
        }

        // calculate how much WETH we need for our oToken amount
        // we need this many wBLT for a given amount of oToken
        uint256 wBLTNeeded = IoToken(_oToken).getDiscountedPrice(
            _optionTokenAmount
        );
        // we need this much WETH to mint that much wBLT
        wethNeeded = router.quoteMintAmountBLT(address(weth), wBLTNeeded);

        // create our route for swapping underlying -> WETH
        IRouter.Route[] memory swapRoute = new IRouter.Route[](2);
        swapRoute[0] = IRouter.Route(
            IoToken(_oToken).underlyingToken(),
            address(wBLT),
            false
        );
        swapRoute[1] = IRouter.Route(address(wBLT), address(weth), false);

        // simulate swapping all to WETH to better estimate total WETH needed
        uint256[] memory amounts = router.getAmountsOut(
            _optionTokenAmount,
            swapRoute
        );
        uint256 minAmount = amounts[2];
        minAmount = wethNeeded + (minAmount * fee) / MAX_BPS;

        // calculate how much underlying we need to get at least this much WETH
        // first do our WETH -> wBLT step
        minAmount = router.quoteRedeemAmountBLT(address(weth), minAmount);

        // then do our wBLT -> underlying step using getAmountsIn
        address[] memory underlyingTowBLT = new address[](2);
        underlyingTowBLT[0] = IoToken(_oToken).underlyingToken();
        underlyingTowBLT[1] = address(wBLT);
        amounts = getAmountsIn(minAmount, underlyingTowBLT);
        minAmount = amounts[0];

        // make sure exercising is profitable
        if (minAmount > _optionTokenAmount) {
            revert("Cost exceeds profit");
        } else {
            realProfit = _optionTokenAmount - minAmount;
        }

        // calculate our real and expected profit
        expectedProfit =
            (_optionTokenAmount *
                ((MAX_BPS *
                    (DISCOUNT_DENOMINATOR - IoToken(_oToken).discount())) /
                    DISCOUNT_DENOMINATOR -
                    fee)) /
            MAX_BPS;

        // if profitSlippage returns zero, we have positive slippage (extra profit)
        if (expectedProfit > realProfit) {
            profitSlippage = 1e18 - ((realProfit * 1e18) / expectedProfit);
        }

        // allow for our expected slippage as well
        expectedProfit =
            (expectedProfit * (MAX_BPS - _profitSlippageAllowed)) /
            MAX_BPS;

        // check if real profit is greater than expected when allowing for slippage
        if (realProfit > expectedProfit) {
            withinSlippageTolerance = true;
        }
    }

    /**
     * @notice Simulate our output, exercising oToken to LP, given various input
     *  parameters. Any extra is sent to user as wBLT.
     * @dev Returned lpAmountOut matches exactly with simulating an oToken exerciseLp()
     *  call. However, we slightly overestimate what will be returned by this contract's
     *  exerciseToLp() due to changing the blockchain state with multiple swaps prior to
     *  the final oToken exerciseLp() call. Note that this overestimation increases with
     *  _optionTokenAmount and decreases when minimizing underlyingOut, but typically is
     *  lower than 1%.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to LP.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @param _percentToLp Out of 10,000. How much our oToken should we send to exercise
     *  for LP?
     * @param _discount Our discount percentage for LP. How long do we want to lock for?
     * @return withinSlippageTolerance Whether expected vs real profit fall within our
     *  slippage tolerance.
     * @return lpAmountOut Simulated amount of LP token to receive.
     * @return wBLTOut Simulated amount of wBLT to receive.
     * @return profitSlippage Expected profit slippage with given oToken amount, 18
     *  decimals. Zero means extra profit (positive slippage).
     */
    function quoteExerciseLp(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed,
        uint256 _percentToLp,
        uint256 _discount
    )
        public
        view
        returns (
            bool withinSlippageTolerance,
            uint256 lpAmountOut,
            uint256 wBLTOut,
            uint256 profitSlippage
        )
    {
        if (_percentToLp > 10_000) {
            revert("Percent must be < 10,000");
        }

        // correct our optionTokenAmount for our percent to LP
        uint256 oTokensToSell = (_optionTokenAmount * (10_000 - _percentToLp)) /
            10_000;

        // simulate exercising our oTokens to underlying, and check slippage
        uint256 underlyingAmountOut;
        (
            ,
            withinSlippageTolerance,
            underlyingAmountOut,
            ,
            profitSlippage
        ) = quoteExerciseToUnderlying(
            _oToken,
            oTokensToSell,
            _profitSlippageAllowed
        );

        // simulate swapping our underlyingToken to wBLT
        address underlying = IoToken(_oToken).underlyingToken();
        uint256 wBLTAmountOut = bvmRouter.getAmountOut(
            underlyingAmountOut,
            underlying,
            address(wBLT),
            false
        );

        // simulate using our wBLT amount to LP with our selected discount
        uint256 oTokensToLp = _optionTokenAmount - oTokensToSell;
        (uint256 paymentAmount, uint256 matchingForLp) = IoToken(_oToken)
            .getPaymentTokenAmountForExerciseLp(oTokensToLp, _discount);
        paymentAmount += matchingForLp;

        // revert if we don't have enough
        if (paymentAmount > wBLTAmountOut) {
            revert("Need more wBLT, decrease _percentToLp or _discount values");
        }

        // how much LP would we get?
        (, , lpAmountOut) = bvmRouter.quoteAddLiquidity(
            underlying,
            address(wBLT),
            false,
            oTokensToLp,
            matchingForLp
        );

        // check how much wBLT we have remaining
        wBLTOut = wBLTAmountOut - paymentAmount;
    }

    /**
     * @notice Exercise our oToken for LP.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount The amount of oToken to exercise to LP.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @param _swapSlippageAllowed Slippage (really price impact) we allow while swapping
     *  between assets.
     */
    function exerciseToLp(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _profitSlippageAllowed,
        uint256 _swapSlippageAllowed,
        uint256 _percentToLp,
        uint256 _discount
    ) public {
        // first person does the approvals for everyone else, what a nice person!
        _checkAllowance(_oToken);

        // transfer option token to this contract
        _safeTransferFrom(
            _oToken,
            msg.sender,
            address(this),
            _optionTokenAmount
        );

        // correct our optionTokenAmount for our percent to LP
        uint256 oTokensToSell = (_optionTokenAmount * (10_000 - _percentToLp)) /
            10_000;

        // simulate exercising our oTokens to underlying, and check slippage
        (
            uint256 wethNeeded,
            bool withinSlippageTolerance,
            ,
            ,

        ) = quoteExerciseToUnderlying(
                _oToken,
                oTokensToSell,
                _profitSlippageAllowed
            );

        // revert if slippage is too high
        if (!withinSlippageTolerance) {
            revert("Profit slippage higher than allowed");
        }

        // convert tokens to underlying vs WETH as it should be lower fee overall
        _borrowPaymentToken(
            _oToken,
            oTokensToSell,
            wethNeeded,
            true,
            _swapSlippageAllowed
        );

        // don't worry about price impact for remaining swaps, as they should be small
        //  enough for it to be negligible, and true slippage (🥪) protection isn't
        //  possible without an external price oracle

        // convert any significant leftover WETH or underlying to wBLT before exercising
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 1e12) {
            // swap WETH for wBLT
            router.swapExactTokensForTokens(
                wethBalance,
                0,
                wethToWblt,
                address(this),
                block.timestamp
            );
            // update our balance
            wethBalance = weth.balanceOf(address(this));
        }

        IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());
        uint256 underlyingBalance = underlying.balanceOf(address(this));
        if (underlyingBalance > 1e15) {
            // swap underlying to wBLT
            bvmRouter.swapExactTokensForTokensSimple(
                underlyingBalance,
                0,
                address(underlying),
                address(wBLT),
                false,
                address(this),
                block.timestamp
            );
            // update our balance
            underlyingBalance = underlying.balanceOf(address(this));
        }

        // exercise our remaining oTokens and lock LP with msg.sender as recipient
        uint256 oTokensToLp = _optionTokenAmount - oTokensToSell;
        IoToken(_oToken).exerciseLp(
            oTokensToLp,
            wBLT.balanceOf(address(this)),
            msg.sender,
            _discount,
            block.timestamp
        );

        // update our wBLT balance after exercising
        uint256 wBLTBalance = wBLT.balanceOf(address(this));

        if (wBLTBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, wBLTBalance);
        }
        if (wethBalance > 0) {
            _safeTransfer(address(weth), msg.sender, wethBalance);
        }
        if (underlyingBalance > 0) {
            _safeTransfer(address(underlying), msg.sender, underlyingBalance);
        }
    }

    /**
     * @notice Exercise our oToken for WETH or underlying.
     * @param _oToken The option token we are exercising.
     * @param _amount The amount of oToken to exercise.
     * @param _receiveUnderlying Whether the user wants to receive WETH or underlying.
     * @param _profitSlippageAllowed Considers effect of TWAP vs spot pricing of options
     *  on profit outcomes.
     * @param _swapSlippageAllowed Slippage (really price impact) we allow while
     *  exercising.
     */
    function exercise(
        address _oToken,
        uint256 _amount,
        bool _receiveUnderlying,
        uint256 _profitSlippageAllowed,
        uint256 _swapSlippageAllowed
    ) external {
        // first person does the approvals for everyone else, what a nice person!
        _checkAllowance(_oToken);

        // check that slippage tolerance for profit is okay
        (
            uint256 wethNeeded,
            bool withinSlippageTolerance,
            ,
            ,

        ) = quoteExerciseProfit(_oToken, _amount, _profitSlippageAllowed);

        // revert if too much slippage
        if (!withinSlippageTolerance) {
            revert("Profit slippage higher than allowed");
        }

        // transfer option token to this contract
        _safeTransferFrom(_oToken, msg.sender, address(this), _amount);
        IERC20 oToken = IERC20(_oToken);

        // get our flash loan started
        _borrowPaymentToken(
            _oToken,
            oToken.balanceOf(address(this)),
            wethNeeded,
            _receiveUnderlying,
            _swapSlippageAllowed
        );

        // don't worry about price impact for remaining swaps, as they should be small
        //  enough for it to be negligible, and true slippage (🥪) protection isn't
        //  possible without an external price oracle

        // anything remaining in the helper is pure profit
        uint256 wethBalance = weth.balanceOf(address(this));
        uint256 wBLTBalance = wBLT.balanceOf(address(this));

        if (_receiveUnderlying) {
            // pull out our underlying token
            IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());

            // swap any leftover WETH to wBLT, unless dust, then send back as WETH
            if (wethBalance > 1e12) {
                // swap WETH to wBLT, then batch-swap all wBLT to underlying
                router.swapExactTokensForTokens(
                    wethBalance,
                    0,
                    wethToWblt,
                    address(this),
                    block.timestamp
                );
                wethBalance = weth.balanceOf(address(this));
                wBLTBalance = wBLT.balanceOf(address(this));
            }

            // convert any significant remaining wBLT to underlying
            if (wBLTBalance > 1e15) {
                bvmRouter.swapExactTokensForTokensSimple(
                    wBLTBalance,
                    0,
                    address(wBLT),
                    address(underlying),
                    false,
                    address(this),
                    block.timestamp
                );
            }

            // send underlying to user, no realistic way this is 0 so skip an if check
            _safeTransfer(
                address(underlying),
                msg.sender,
                underlying.balanceOf(address(this))
            );
        } else {
            // convert any significant remaining wBLT to WETH. also, swapping too
            //  small of an amount will revert here
            if (wBLTBalance > 1e15) {
                router.swapExactTokensForTokens(
                    wBLTBalance,
                    0,
                    wBltToWeth,
                    address(this),
                    block.timestamp
                );
                wethBalance = weth.balanceOf(address(this));
            }
        }

        wBLTBalance = wBLT.balanceOf(address(this));
        if (wBLTBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, wBLTBalance);
        }
        if (wethBalance > 0) {
            _safeTransfer(address(weth), msg.sender, wethBalance);
        }
    }

    /**
     * @notice Flash loan our WETH from Balancer.
     * @param _oToken The option token we are exercising.
     * @param _oTokenToExercise The amount of oToken we are exercising.
     * @param _wethNeeded The amount of WETH needed.
     * @param _receiveUnderlying Whether the user wants to receive WETH or underlying.
     * @param _slippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function _borrowPaymentToken(
        address _oToken,
        uint256 _oTokenToExercise,
        uint256 _wethNeeded,
        bool _receiveUnderlying,
        uint256 _slippageAllowed
    ) internal {
        // change our state
        flashEntered = true;

        // create our input args
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _wethNeeded;

        bytes memory userData = abi.encode(
            _oToken,
            _oTokenToExercise,
            _receiveUnderlying,
            _slippageAllowed
        );

        // call the flash loan
        balancerVault.flashLoan(address(this), tokens, amounts, userData);
    }

    /**
     * @notice Fallback function used during flash loans.
     * @dev May only be called by balancer vault as part of
     *  flash loan callback.
     * @param _tokens The tokens we are swapping (in our case, only WETH).
     * @param _amounts The amounts of said tokens.
     * @param _feeAmounts The fee amounts for said tokens.
     * @param _userData Useful data passed when calling our flash loan.
     */
    function receiveFlashLoan(
        address[] memory _tokens,
        uint256[] memory _amounts,
        uint256[] memory _feeAmounts,
        bytes memory _userData
    ) external {
        // only balancer vault may call this, during a flash loan
        if (msg.sender != address(balancerVault)) {
            revert("Only balancer vault can call");
        }
        if (!flashEntered) {
            revert("Flashloan not in progress");
        }

        // pull out info from the userData
        (
            address _oToken,
            uint256 _oTokenToExercise,
            bool _receiveUnderlying,
            uint256 _slippageAllowed
        ) = abi.decode(_userData, (address, uint256, bool, uint256));

        // pass our total WETH amount to make sure we get enough back
        uint256 payback = _amounts[0] + _feeAmounts[0];

        _exerciseAndSwap(
            _oToken,
            _oTokenToExercise,
            payback,
            _receiveUnderlying,
            _slippageAllowed
        );

        // repay our flash loan
        _safeTransfer(address(weth), address(balancerVault), payback);
        flashEntered = false;
    }

    /**
     * @notice Exercise our oToken, then swap some (or all) underlying to WETH.
     * @param _oToken The option token we are exercising.
     * @param _optionTokenAmount Amount of oToken to exercise.
     * @param _wethAmount Max amount of WETH we allow to be spent exercising, and how much
     *  we'll need back. Note this also includes any fees for flash loans.
     * @param _receiveUnderlying Whether the user wants to receive WETH or underlying.
     * @param _slippageAllowed Slippage (really price impact) we allow while exercising.
     */
    function _exerciseAndSwap(
        address _oToken,
        uint256 _optionTokenAmount,
        uint256 _wethAmount,
        bool _receiveUnderlying,
        uint256 _slippageAllowed
    ) internal {
        // use this to minimize issues with price impact, check price of 1 token
        uint256[] memory amounts = router.getAmountsOut(1e18, wethToWblt);
        uint256 minAmountOut = (_wethAmount *
            amounts[1] *
            (MAX_BPS - _slippageAllowed)) / (1e18 * MAX_BPS);

        // deposit our WETH to wBLT
        amounts = router.swapExactTokensForTokens(
            _wethAmount,
            minAmountOut,
            wethToWblt,
            address(this),
            block.timestamp
        );

        IoToken(_oToken).exercise(
            _optionTokenAmount,
            amounts[1],
            address(this)
        );
        IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());
        uint256 underlyingReceived = underlying.balanceOf(address(this));

        IRouter.Route[] memory underlyingToWeth = new IRouter.Route[](2);
        underlyingToWeth[0] = IRouter.Route(
            address(underlying),
            address(wBLT),
            false
        );
        underlyingToWeth[1] = IRouter.Route(
            address(wBLT),
            address(weth),
            false
        );

        // use this to minimize issues with slippage
        amounts = router.getAmountsOut(1e18, underlyingToWeth);
        uint256 wethPerToken = amounts[2];

        minAmountOut =
            (underlyingReceived * wethPerToken * (MAX_BPS - _slippageAllowed)) /
            (1e18 * MAX_BPS);

        // use this amount to calculate fees
        uint256 totalWeth;

        if (_receiveUnderlying) {
            // simulate our swap to calc WETH needed for fee + repay flashloan
            amounts = router.getAmountsOut(
                _optionTokenAmount,
                underlyingToWeth
            );
            totalWeth = amounts[2];
            uint256 feeAmount = (totalWeth * fee) / MAX_BPS;
            minAmountOut = feeAmount + _wethAmount;

            // calculate how much underlying we need to get at least this much WETH
            // first do our WETH -> wBLT step
            uint256 underlyingToSwap = router.quoteRedeemAmountBLT(
                address(weth),
                minAmountOut
            );

            // then do our wBLT -> underlying step
            address[] memory underlyingTowBLT = new address[](2);
            underlyingTowBLT[0] = address(underlying);
            underlyingTowBLT[1] = address(wBLT);
            amounts = getAmountsIn(underlyingToSwap, underlyingTowBLT);
            underlyingToSwap = amounts[0];

            // swap our underlying amount calculated above
            router.swapExactTokensForTokens(
                underlyingToSwap,
                0,
                underlyingToWeth,
                address(this),
                block.timestamp
            );

            // easier to enforce the minAmountOut after the swap due to rounding issues
            if (weth.balanceOf(address(this)) < minAmountOut) {
                revert("Not enough WETH out");
            }

            // take fees
            _takeFees(totalWeth);
        } else {
            // use our router to swap from underlying to WETH
            amounts = router.swapExactTokensForTokens(
                underlyingReceived,
                minAmountOut,
                underlyingToWeth,
                address(this),
                block.timestamp
            );
            totalWeth = amounts[2];

            // take fees normally since we're doing all to WETH
            _takeFees(totalWeth);
        }
    }

    /**
     * @notice Apply fees to our after-swap total.
     * @dev Default is 0.25% but this may be updated later.
     * @param _amount Amount to apply our fee to.
     */
    function _takeFees(uint256 _amount) internal {
        uint256 toSend = (_amount * fee) / MAX_BPS;
        _safeTransfer(address(weth), feeAddress, toSend);
    }

    /**
     * @notice Sweep out tokens accidentally sent here.
     * @dev May only be called by owner.
     * @param _tokenAddress Address of token to sweep.
     * @param _tokenAmount Amount of tokens to sweep.
     */
    function recoverERC20(
        address _tokenAddress,
        uint256 _tokenAmount
    ) external onlyOwner {
        _safeTransfer(_tokenAddress, owner(), _tokenAmount);
    }

    /**
     * @notice Update fee for oToken -> WETH conversion.
     * @param _recipient Fee recipient address.
     * @param _newFee New fee, out of 10,000.
     */
    function setFee(address _recipient, uint256 _newFee) external onlyOwner {
        if (_newFee > DISCOUNT_DENOMINATOR) {
            revert("setFee: Fee max is 1%");
        }
        fee = _newFee;
        feeAddress = _recipient;
    }

    /* ========== HELPER FUNCTIONS ========== */

    /**
     * @notice Given an output amount of an asset and pair reserves, returns a required
     *  input amount of the other asset.
     * @dev Pulls the fee correction dynamically from our pair factory.
     * @param _pair Address of the token pair we are checking on.
     * @param _amountOut Minimum amount we need to receive of _reserveOut token.
     * @param _reserveIn Pair reserve of our amountIn token.
     * @param _reserveOut Pair reserve of our _amountOut token.
     * @return amountIn Amount of _reserveIn to swap to receive _amountOut.
     */
    function _getAmountIn(
        address _pair,
        uint256 _amountOut,
        uint256 _reserveIn,
        uint256 _reserveOut
    ) internal view returns (uint256 amountIn) {
        if (_amountOut == 0) {
            revert("_getAmountIn: _amountOut must be >0");
        }
        if (_reserveIn == 0 || _reserveOut == 0) {
            revert("_getAmountIn: Reserves must be >0");
        }
        uint256 numerator = _reserveIn * _amountOut * 10_000;
        uint256 denominator = (_reserveOut - _amountOut) *
            (10_000 - pairFactory.getFee(_pair));
        amountIn = (numerator / denominator) + 1;
    }

    /**
     * @notice Performs chained _getAmountIn calculations on any number of pairs.
     * @dev Assumes only volatile pools.
     * @param _amountOut Minimum amount we need to receive of the final array token.
     * @param _path Array of addresses for our swap path, UniV2-style.
     * @return amounts Array of amounts for each token in our swap path.
     */
    function getAmountsIn(
        uint256 _amountOut,
        address[] memory _path
    ) public view returns (uint256[] memory amounts) {
        if (_path.length < 2) {
            revert("getAmountsIn: Path length must be >1");
        }
        amounts = new uint256[](_path.length);
        amounts[amounts.length - 1] = _amountOut;
        for (uint256 i = _path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = bvmRouter.getReserves(
                _path[i - 1],
                _path[i],
                false
            );
            address pair = pairFactory.getPair(_path[i - 1], _path[i], false);
            amounts[i - 1] = _getAmountIn(
                pair,
                amounts[i],
                reserveIn,
                reserveOut
            );
        }
    }

    /**
     * @notice Helper to approve new oTokens to spend tokens from this contract
     * @dev Will only approve on first call.
     * @param _oToken Address of oToken to check for.
     */
    function _checkAllowance(address _oToken) internal {
        if (wBLT.allowance(address(this), _oToken) == 0) {
            wBLT.approve(_oToken, type(uint256).max);
            weth.approve(_oToken, type(uint256).max);

            // approve router to spend underlying from this contract
            IERC20 underlying = IERC20(IoToken(_oToken).underlyingToken());
            underlying.approve(address(router), type(uint256).max);

            // approve BVM router to spend underlying & wBLT
            underlying.approve(address(bvmRouter), type(uint256).max);
            wBLT.approve(address(bvmRouter), type(uint256).max);
        }
    }

    /**
     * @notice Internal safeTransfer function. Transfer tokens to another address.
     * @param _token Address of token to transfer.
     * @param _to Address to send token to.
     * @param _value Amount of token to send.
     */
    function _safeTransfer(
        address _token,
        address _to,
        uint256 _value
    ) internal {
        require(_token.code.length > 0);
        (bool success, bytes memory data) = _token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, _to, _value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    /**
     * @notice Internal safeTransferFrom function. Transfer tokens from one address to
     *  another.
     * @dev From address must have approved sufficient allowance for this contract.
     * @param _token Address of token to transfer.
     * @param _from Address to send token from.
     * @param _to Address to send token to.
     * @param _value Amount of token to send.
     */
    function _safeTransferFrom(
        address _token,
        address _from,
        address _to,
        uint256 _value
    ) internal {
        require(_token.code.length > 0);
        (bool success, bytes memory data) = _token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                _from,
                _to,
                _value
            )
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
