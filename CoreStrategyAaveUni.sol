// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "./BaseStrategyRedux.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "./interfaces/uniswap.sol";
import "./interfaces/aave/IAToken.sol";
import "./interfaces/aave/IVariableDebtToken.sol";
import "./interfaces/aave/IPool.sol";
import "./interfaces/aave/IAaveOracle.sol";
import "./interfaces/farm.sol";
import "./interfaces/uniswap.sol";
import "./interfaces/IUniswapManager.sol";
import {IStrategyInsurance} from "./StrategyInsurance.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./libraries/FixedPoint96.sol";
import "./libraries/FullMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/PoolAddress.sol";
import "./interfaces/ISwapRouter.sol";
import "./libraries/LiquidityAmounts.sol";

struct CoreStrategyAaveUniConfig {
    // A portion of want token is depoisited into a lending platform to be used as
    // collateral. Short token is borrowed and compined with the remaining want token
    // and deposited into LP and farmed.
    address want;
    address short;
    /*****************************/
    /*        Money Market       */
    /*****************************/
    // Base token cToken @ MM
    address aToken;
    address variableDebtToken;
    // Short token cToken @ MM
    address poolAddressesProvider;
    /*****************************/
    /*            AMM            */
    /*****************************/
    // Liquidity pool address for base <-> short tokens @ the AMM.
    // @note: the AMM router address does not need to be the same
    // AMM as the farm, in fact the most liquid AMM is prefered to
    // minimise slippage.
    uint256 minDeploy;
    address manager;
    address uniFactory;
    uint24 poolFee;
    int24 tickRangeMultiplier;
    uint24 twapTime;
    address router;
}

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

abstract contract CoreStrategyAaveUni is BaseStrategyRedux {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using SafeMath for uint8;

    event DebtRebalance(
        uint256 indexed debtRatio,
        uint256 indexed swapAmount,
        uint256 indexed slippage
    );
    event CollatRebalance(
        uint256 indexed collatRatio,
        uint256 indexed adjAmount
    );
    event ExecutionResult(bool success, bytes result);
    event UniswapRebalance();

    uint256 public collatUpper = 6700;
    uint256 public collatTarget = 6000;
    uint256 public collatLower = 5300;
    uint256 public debtUpper = 10190;
    uint256 public debtLower = 9810;
    uint256 public rebalancePercent = 10000; // 100% (how far does rebalance of debt move towards 100% from threshold)

    // protocal limits & upper, target and lower thresholds for ratio of debt to collateral
    uint256 public collatLimit = 7500;

    bool public doPriceCheck = true;

    // ERC20 Tokens;
    IERC20 public short;
    uint8 wantDecimals;
    uint8 shortDecimals;
    IUniswapV3Pool public wantShortLP; // This is public because it helps with unit testing
    // Contract Interfaces
    IStrategyInsurance public insurance;
    IPool pool;
    IAToken aToken;
    IVariableDebtToken debtToken;
    IAaveOracle public oracle;

    uint256 public slippageAdj = 9800; // 98%

    uint256 constant BASIS_PRECISION = 10000;
    uint256 public priceSourceDiffKeeper = 500; // 5% Default
    uint256 public priceSourceDiffUser = 200; // 2% Default  TODO: change back to default

    uint256 constant STD_PRECISION = 1e18;
    address weth;
    uint256 public minDeploy;

    IUniswapManager public manager;
    uint256 public tokenId;
    address uniFactory;
    uint24 public poolFee;
    uint24 twapTime;
    int24 tickRangeMultiplier;
    ISwapRouter router;

    constructor(address _vault, CoreStrategyAaveUniConfig memory _config)
        public
        BaseStrategyRedux(_vault)
    {
        // config = _config;

        // initialise token interfaces

        short = IERC20(_config.short);
        wantDecimals = IERC20Extended(_config.want).decimals();
        shortDecimals = IERC20Extended(_config.short).decimals();
        IPoolAddressesProvider provider =
            IPoolAddressesProvider(_config.poolAddressesProvider);
        pool = IPool(provider.getPool());
        oracle = IAaveOracle(provider.getPriceOracle());
        aToken = IAToken(_config.aToken);
        debtToken = IVariableDebtToken(_config.variableDebtToken);
        maxReportDelay = 21600;
        minReportDelay = 14400;
        profitFactor = 1500;
        minDeploy = _config.minDeploy;
        manager = IUniswapManager(_config.manager);
        uniFactory = _config.uniFactory;
        router = ISwapRouter(_config.router);
        weth = router.WETH9();
        poolFee = _config.poolFee;
        twapTime = _config.twapTime;
        tickRangeMultiplier = _config.tickRangeMultiplier;
        wantShortLP = IUniswapV3Pool(
            PoolAddress.computeAddress(
                uniFactory,
                PoolAddress.getPoolKey(address(want), address(short), poolFee)
            )
        );
        _setup();

        approveContracts();
    }

    function _setup() internal virtual {
        // For additional setup -> initialize custom contracts addresses
    }

    function name() external view override returns (string memory) {
        return "StrategyHedgedFarmingAaveUniV1";
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();
        if (totalAssets > totalDebt) {
            _profit = totalAssets.sub(totalDebt);
            (uint256 amountFreed, ) = _withdraw(_debtOutstanding.add(_profit));
            if (_debtOutstanding > amountFreed) {
                _debtPayment = amountFreed;
                _profit = 0;
            } else {
                _debtPayment = _debtOutstanding;
                _profit = amountFreed.sub(_debtOutstanding);
            }
        } else {
            _withdraw(_debtOutstanding);
            _debtPayment = balanceOfWant();
            _loss = totalDebt.sub(totalAssets);
        }

        _profit += _harvestInternal();

        // Check if we're net loss or net profit
        if (_loss >= _profit) {
            _loss = _loss.sub(_profit);
            _profit = 0;
            _loss = _loss.sub(insurance.reportLoss(totalDebt, _loss));
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
            (uint256 insurancePayment, uint256 compensation) =
                insurance.reportProfit(totalDebt, _profit);
            _profit = _profit.sub(insurancePayment).add(compensation);

            // double check insurance isn't asking for too much or zero
            if (insurancePayment > 0 && insurancePayment < _profit) {
                SafeERC20.safeTransfer(
                    want,
                    address(insurance),
                    insurancePayment
                );
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();
        if (_debtOutstanding >= _wantAvailable) {
            return;
        }
        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);

        if (toInvest > 0) {
            _deploy(toInvest);
        }
    }

    function prepareMigration(address _newStrategy) internal override {
        liquidateAllPositionsInternal();
    }

    function approveContracts() internal {
        want.safeApprove(address(manager), uint256(-1));
        short.safeApprove(address(manager), uint256(-1));
        want.safeApprove(address(router), uint256(-1));
        short.safeApprove(address(router), uint256(-1));
        want.safeApprove(address(pool), uint256(-1));
        short.safeApprove(address(pool), uint256(-1));
    }

    function setSlippageConfig(
        uint256 _slippageAdj,
        uint256 _priceSourceDiffUser,
        uint256 _priceSourceDiffKeeper,
        bool _doPriceCheck
    ) external onlyAuthorized {
        slippageAdj = _slippageAdj;
        priceSourceDiffKeeper = _priceSourceDiffKeeper;
        priceSourceDiffUser = _priceSourceDiffUser;
        doPriceCheck = _doPriceCheck;
    }

    function setInsurance(address _insurance) external onlyAuthorized {
        require(address(insurance) == address(0));
        insurance = IStrategyInsurance(_insurance);
    }

    function migrateInsurance(address _newInsurance) external onlyGovernance {
        require(address(_newInsurance) == address(0));
        insurance.migrateInsurance(_newInsurance);
        insurance = IStrategyInsurance(_newInsurance);
    }

    function setDebtThresholds(
        uint256 _lower,
        uint256 _upper,
        uint256 _rebalancePercent
    ) external onlyAuthorized {
        require(_lower <= BASIS_PRECISION);
        require(_rebalancePercent <= BASIS_PRECISION);
        require(_upper >= BASIS_PRECISION);
        rebalancePercent = _rebalancePercent;
        debtUpper = _upper;
        debtLower = _lower;
    }

    function setCollateralThresholds(
        uint256 _lower,
        uint256 _target,
        uint256 _upper,
        uint256 _limit
    ) external onlyAuthorized {
        require(_limit <= BASIS_PRECISION);
        collatLimit = _limit;
        require(collatLimit > _upper);
        require(_upper >= _target);
        require(_target >= _lower);
        collatUpper = _upper;
        collatTarget = _target;
        collatLower = _lower;
    }

    function setTickRangeMultiplier(int24 _tickRangeMultiplier)
        external
        onlyAuthorized
    {
        manager.setTickRangeMultiplier(tokenId, _tickRangeMultiplier); // Just for good measure!
        tickRangeMultiplier = _tickRangeMultiplier;
    }

    function liquidatePositionAuth(uint256 _amount) external onlyAuthorized {
        liquidatePosition(_amount);
    }

    function liquidateAllToLend() internal {
        _removeAllLp();
        _lendWant(balanceOfWant());
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidateAllPositionsInternal();
    }

    function liquidateAllPositionsInternal()
        internal
        returns (uint256 _amountFreed, uint256 _loss)
    {
        _removeAllLp();

        uint256 debtInShort = balanceDebtInShortCurrent();
        uint256 balShort = balanceShort();
        if (balShort >= debtInShort) {
            _repayDebt();
            if (balanceShortWantEq() > 0) {
                (, _loss) = _swapExactShortWant(short.balanceOf(address(this)));
            }
        } else {
            uint256 debtDifference = debtInShort.sub(balShort);
            if (convertShortToWantLP(debtDifference) > 0) {
                (_loss) = _swapWantShortExact(debtDifference);
            } else {
                _swapExactWantShort(uint256(1));
            }
            _repayDebt();
        }

        _redeemWant(balanceLend());
        _amountFreed = balanceOfWant();
    }

    /// rebalances RoboVault strat position to within target collateral range
    function rebalanceCollateral() external onlyKeepers {
        // ratio of amount borrowed to collateral
        uint256 collatRatio = calcCollateral();
        require(collatRatio <= collatLower || collatRatio >= collatUpper);
        _rebalanceCollateralInternal();
    }

    /// rebalances RoboVault holding of short token vs LP to within target collateral range
    function rebalanceDebt() external onlyKeepers {
        uint256 debtRatio = calcDebtRatio();
        require(debtRatio < debtLower || debtRatio > debtUpper);
        require(_testPriceSource(priceSourceDiffKeeper));
        _rebalanceDebtInternal();
    }

    /// rebalances Uniswap position to current price
    function rebalanceUniswap() external onlyKeepers {
        tokenId = manager.rebalance(tokenId);
        emit UniswapRebalance();
    }

    function claimHarvest() internal virtual;

    /// called by keeper to harvest rewards and either repay debt

    function _harvestInternal() internal returns (uint256 _wantHarvested) {
        if (tokenId == 0) return 0;
        uint256 wantBefore = balanceOfWant();
        uint256 harvestBefore = short.balanceOf(address(this));
        /// harvest from farm & wantd on amt borrowed vs LP value either -> repay some debt or add to collateral
        claimHarvest();
        uint256 harvestBalance = short.balanceOf(address(this));
        if (harvestBalance.sub(harvestBefore) > 1000) {
            _swapExactShortWant(harvestBalance.sub(harvestBefore));
        }
        _wantHarvested = balanceOfWant().sub(wantBefore);
    }

    function _rebalanceCollateralInternal() internal {
        uint256 collatRatio = calcCollateral();
        uint256 shortPos = balanceDebt();
        uint256 lendPos = balanceLend();

        if (collatRatio > collatTarget) {
            uint256 adjAmount =
                (shortPos.sub(lendPos.mul(collatTarget).div(BASIS_PRECISION)))
                    .mul(BASIS_PRECISION)
                    .div(BASIS_PRECISION.add(collatTarget));
            /// remove some LP use 50% of withdrawn LP to repay debt and half to add to collateral
            _withdrawLpRebalanceCollateral(adjAmount.mul(2));
            emit CollatRebalance(collatRatio, adjAmount);
        } else if (collatRatio < collatTarget) {
            uint256 adjAmount =
                ((lendPos.mul(collatTarget).div(BASIS_PRECISION)).sub(shortPos))
                    .mul(BASIS_PRECISION)
                    .div(BASIS_PRECISION.add(collatTarget));
            uint256 borrowAmt = _borrowWantEq(adjAmount);
            _redeemWant(adjAmount);
            _addToLP(borrowAmt);
            emit CollatRebalance(collatRatio, adjAmount);
        }
    }

    // deploy assets according to vault strategy
    function _deploy(uint256 _amount) internal {
        if (_amount < minDeploy) {
            return;
        }
        uint256 oPrice = getOraclePrice();
        uint256 lpPrice = getLpPrice();
        uint256 borrow =
            collatTarget.mul(_amount).mul(1e18).div(
                BASIS_PRECISION.mul(
                    (collatTarget.mul(lpPrice).div(BASIS_PRECISION).add(oPrice))
                )
            );

        uint256 debtAllocation = borrow.mul(lpPrice).div(1e18);
        uint256 lendNeeded = _amount.sub(debtAllocation);
        _lendWant(lendNeeded);
        if (shortDecimals < 18) {
            borrow = borrow.div(uint256(10)**(uint256(18).sub(shortDecimals)));
        }
        _borrow(borrow);
        _addToLP(borrow);
    }

    function getLpPrice() public view returns (uint256) {
        if (wantShortLP.token1() == address(want)) {
            return manager.getTwapPrice(wantShortLP, 0);
        } else {
            return
                (uint256(10)**(wantDecimals.add(shortDecimals))).div(
                    manager.getTwapPrice(wantShortLP, 0)
                );
        }
    }

    function getOraclePrice() public view returns (uint256) {
        uint256 shortOPrice = oracle.getAssetPrice(address(short));
        uint256 wantOPrice = oracle.getAssetPrice(address(want));
        if (wantDecimals < 18) {
            return
                shortOPrice
                    .mul(10**(wantDecimals.add(18).sub(shortDecimals)))
                    .div(wantOPrice);
        } else {
            return shortOPrice.mul(uint256(10)**(wantDecimals)).div(wantOPrice);
        }
    }

    /**
     * @notice
     *  Reverts if the difference in the price sources are >  priceDiff
     */
    function _testPriceSource(uint256 priceDiff) internal view returns (bool) {
        if (doPriceCheck) {
            uint256 oPrice = getOraclePrice();
            uint256 lpPrice = getLpPrice();
            uint256 priceSourceRatio = oPrice.mul(BASIS_PRECISION).div(lpPrice);
            return (priceSourceRatio > BASIS_PRECISION.sub(priceDiff) &&
                priceSourceRatio < BASIS_PRECISION.add(priceDiff));
        }
        return true;
    }

    /**
     * @notice
     *  Assumes all balance is in Lend outside of a small amount of debt and short. Deploys
     *  capital maintaining the collatRatioTarget
     *
     * @dev
     *  Some crafty maths here:
     *  B: borrow amount in short (Not total debt!)
     *  L: Lend in want
     *  Cr: Collateral Target
     *  Po: Oracle price (short * Po = want)
     *  Plp: LP Price
     *  Di: Initial Debt in short
     *  Si: Initial short balance
     *
     *  We want:
     *  Cr = BPo / L
     *  T = L + Plp(B + 2Si - Di)
     *
     *  Solving this for L finds:
     *  B = (TCr - Cr*Plp(2Si-Di)) / (Po + Cr*Plp)
     */
    function _calcDeployment(uint256 _amount)
        internal
        returns (uint256 _lendNeeded, uint256 _borrow)
    {
        uint256 oPrice = getOraclePrice();
        uint256 lpPrice = getLpPrice();
        uint256 Si2 = balanceShort().mul(2);
        uint256 Di = balanceDebtInShort();
        uint256 CrPlp = collatTarget.mul(lpPrice);
        uint256 numerator;

        // NOTE: may throw if _amount * CrPlp > 1e70
        if (Di > Si2) {
            numerator = (
                collatTarget.mul(_amount).mul(1e18).add(CrPlp.mul(Di.sub(Si2)))
            )
                .sub(oPrice.mul(BASIS_PRECISION).mul(Di));
        } else {
            numerator = (
                collatTarget.mul(_amount).mul(1e18).sub(CrPlp.mul(Si2.sub(Di)))
            )
                .sub(oPrice.mul(BASIS_PRECISION).mul(Di));
        }

        _borrow = numerator.div(
            BASIS_PRECISION.mul(oPrice.add(CrPlp.div(BASIS_PRECISION)))
        );
        _lendNeeded = _amount.sub(
            (_borrow.add(Si2).sub(Di)).mul(lpPrice).div(1e18)
        );
    }

    function _deployFromLend(uint256 _amount) internal {
        (uint256 _lendNeeded, uint256 _borrowAmt) = _calcDeployment(_amount);
        _redeemWant(balanceLend().sub(_lendNeeded));
        if (shortDecimals < 18) {
            _borrowAmt = _borrowAmt.div(
                uint256(10)**(uint8(18).sub(shortDecimals))
            );
        }
        _borrow(_borrowAmt);
        _addToLP(balanceShort());
    }

    function _rebalanceDebtInternal() internal {
        uint256 swapAmountWant;
        uint256 slippage;
        uint256 debtRatio = calcDebtRatio();

        // Liquidate all the lend, leaving some in debt or as short
        liquidateAllToLend();

        uint256 debtInShort = balanceDebtInShort();
        uint256 balShort = balanceShort();

        if (debtInShort > balShort) {
            uint256 debt = convertShortToWantLP(debtInShort.sub(balShort));
            // If there's excess debt, we swap some want to repay a portion of the debt
            swapAmountWant = debt.mul(rebalancePercent).div(BASIS_PRECISION);
            _redeemWant(swapAmountWant);
            slippage = _swapExactWantShort(swapAmountWant);
        } else {
            uint256 excessShort = balShort - debtInShort;
            // If there's excess short, we swap some to want which will be used
            // to create lp in _deployFromLend()
            (swapAmountWant, slippage) = _swapExactShortWant(
                excessShort.mul(rebalancePercent).div(BASIS_PRECISION)
            );
        }
        _repayDebt();
        _deployFromLend(estimatedTotalAssets());
        emit DebtRebalance(debtRatio, swapAmountWant, slippage);
    }

    function _getTotalDebt() internal view returns (uint256) {
        return vault.strategies(address(this)).totalDebt;
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balanceWant = balanceOfWant();
        uint256 totalAssets = estimatedTotalAssets();

        // if estimatedTotalAssets is less than params.debtRatio it means there's
        // been a loss (ignores pending harvests). This type of loss is calculated
        // proportionally
        // This stops a run-on-the-bank if there's IL between harvests.
        uint256 newAmount = _amountNeeded;
        uint256 totalDebt = _getTotalDebt();
        if (totalDebt > totalAssets) {
            uint256 ratio = totalAssets.mul(STD_PRECISION).div(totalDebt);
            newAmount = _amountNeeded.mul(ratio).div(STD_PRECISION);
            _loss = _amountNeeded.sub(newAmount);
        }

        // Liquidate the amount needed
        (, uint256 _slippage) = _withdraw(newAmount);
        _loss = _loss.add(_slippage);

        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        _liquidatedAmount = balanceOfWant();
        if (_liquidatedAmount.add(_loss) > _amountNeeded) {
            _liquidatedAmount = _amountNeeded.sub(_loss);
        } else {
            _loss = _amountNeeded.sub(_liquidatedAmount);
        }
    }

    /**
     * function to remove funds from strategy when users withdraws funds in excess of reserves
     *
     * withdraw takes the following steps:
     * 1. Removes _amountNeeded worth of LP from the farms and pool
     * 2. Uses the short removed to repay debt (Swaps short or base for large withdrawals)
     * 3. Redeems the
     * @param _amountNeeded `want` amount to liquidate
     */
    function _withdraw(uint256 _amountNeeded)
        internal
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        require(_testPriceSource(priceSourceDiffUser));
        uint256 balanceWant = balanceOfWant();
        if (_amountNeeded <= balanceWant) {
            return (_amountNeeded, 0);
        }

        uint256 balanceDeployed = balanceDeployed();

        // stratPercent: Percentage of the deployed capital we want to liquidate.
        uint256 stratPercent =
            _amountNeeded.sub(balanceWant).mul(BASIS_PRECISION).div(
                balanceDeployed
            );

        if (stratPercent > 9500) {
            // If this happened, we just undeploy the lot
            // and it'll be redeployed during the next harvest.
            (_liquidatedAmount, _loss) = liquidateAllPositionsInternal();
        } else {
            // liquidate all to lend
            liquidateAllToLend();
            // Only rebalance if more than 5% is being liquidated
            // to save on gas
            uint256 slippage = 0;
            if (stratPercent > 500) {
                // swap to ensure the debt ratio isn't negatively affected
                uint256 shortInShort = balanceShort();
                uint256 debtInShort = balanceDebtInShort();
                if (debtInShort > shortInShort) {
                    uint256 debt =
                        convertShortToWantLP(debtInShort.sub(shortInShort));
                    uint256 swapAmountWant =
                        debt.mul(stratPercent).div(BASIS_PRECISION);
                    _redeemWant(swapAmountWant);
                    slippage = _swapExactWantShort(swapAmountWant);
                } else {
                    (, slippage) = _swapExactShortWant(
                        (shortInShort.sub(debtInShort)).mul(stratPercent).div(
                            BASIS_PRECISION
                        )
                    );
                }
            }
            _repayDebt();

            // Redeploy the strat
            _deployFromLend(balanceDeployed.sub(_amountNeeded).add(slippage));
            _liquidatedAmount = balanceOfWant().sub(balanceWant);
            _loss = slippage;
        }
    }

    // calculate total value of vault assets
    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceDeployed());
    }

    // calculate total value of vault assets
    function balanceDeployed() public view returns (uint256) {
        return
            balanceLend().add(balanceLp()).add(balanceShortWantEq()).sub(
                balanceDebt()
            );
    }

    // debt ratio - used to trigger rebalancing of debt
    function calcDebtRatio() public view returns (uint256) {
        //return (balanceDebt().mul(BASIS_PRECISION).mul(2).div(balanceLp()));
        (, uint256 shortInLp) = getLpReserves();
        return
            balanceDebt().mul(BASIS_PRECISION).div(
                convertShortToWantLP(shortInLp)
            );
    }

    // calculate debt / collateral - used to trigger rebalancing of debt & collateral
    function calcCollateral() public view returns (uint256) {
        return balanceDebtOracle().mul(BASIS_PRECISION).div(balanceLend());
    }

    function getLpReserves()
        public
        view
        returns (uint256 _wantInLp, uint256 _shortInLp)
    {
        if (tokenId == 0) return (0, 0);

        (uint256 reserves0, uint256 reserves1) = manager.getLpReserves(tokenId);
        if (wantShortLP.token0() == address(want)) {
            _wantInLp = reserves0;
            _shortInLp = reserves1;
        } else {
            _wantInLp = reserves1;
            _shortInLp = reserves0;
        }
    }

    function convertShortToWantLP(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        return _amountShort.mul(getLpPrice()).div(uint256(10)**shortDecimals);
    }

    function convertShortToWantOracle(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        return
            _amountShort.mul(getOraclePrice()).div(uint256(10)**shortDecimals);
    }

    function convertWantToShortLP(uint256 _amountWant)
        internal
        view
        returns (uint256)
    {
        return _amountWant.mul(uint256(10)**shortDecimals).div(getLpPrice());
        //return (_amountWant.div(getLpPrice())).mul(wantDecimals); // TODO: Are we multiplying or dividing?
    }

    /// get value of all LP in want currency
    function balanceLp() public view returns (uint256) {
        (uint256 amountWant, uint256 amountShort) = getLpReserves();
        return amountWant.add(convertShortToWantLP(amountShort));
    }

    // value of borrowed tokens in value of want tokens
    function balanceDebtInShort() public view returns (uint256) {
        // Each debtToken is pegged 1:1 with the short token
        return debtToken.balanceOf(address(this));
    }

    // value of borrowed tokens in value of debt tokens
    // Uses current exchange price, not stored
    function balanceDebtInShortCurrent() internal returns (uint256) {
        return debtToken.balanceOf(address(this));
    }

    // value of borrowed tokens in value of want tokens
    function balanceDebt() public view returns (uint256) {
        return convertShortToWantLP(balanceDebtInShort());
    }

    /**
     * Debt balance using price oracle
     */
    function balanceDebtOracle() public view returns (uint256) {
        // TODO: PUBLIC
        return convertShortToWantOracle(balanceDebtInShort());
    }

    // reserves
    function balanceOfWant() public view returns (uint256) {
        return (want.balanceOf(address(this)));
    }

    function balanceShort() public view returns (uint256) {
        return (short.balanceOf(address(this)));
    }

    function balanceShortWantEq() public view returns (uint256) {
        return (convertShortToWantLP(short.balanceOf(address(this))));
    }

    function balanceLend() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    // Strategy specific
    function countLpPooled() internal view virtual returns (uint256);

    // lend want tokens to lending platform
    function _lendWant(uint256 amount) internal {
        pool.deposit(address(want), amount, address(this), 0);
    }

    // borrow tokens woth _amount of want tokens
    function _borrowWantEq(uint256 _amount)
        internal
        returns (uint256 _borrowamount)
    {
        _borrowamount = convertWantToShortLP(_amount);
        //_borrowamount = _borrowamount.mul(10010).div(10000);
        _borrow(_borrowamount);
    }

    function _borrow(uint256 borrowAmount) internal {
        pool.borrow(address(short), borrowAmount, 2, 0, address(this));
    }

    // automatically repays debt using any short tokens held in wallet up to total debt value
    function _repayDebt() internal {
        uint256 _bal = short.balanceOf(address(this));
        if (_bal == 0) return;

        uint256 _debt = balanceDebtInShort();
        if (_bal < _debt) {
            pool.repay(address(short), _bal, 2, address(this));
        } else {
            pool.repay(address(short), _debt, 2, address(this));
        }
    }

    /*
    function _getHarvestInHarvestLp() internal view returns (uint256) {
        uint256 harvest_lp = farmToken.balanceOf(address(farmTokenLP));
        return harvest_lp;
    }
    

    function _getShortInHarvestLp() internal view returns (uint256) {
        uint256 shortToken_lp = short.balanceOf(address(farmTokenLP));
        return shortToken_lp;
    }
    */

    function _redeemWant(uint256 _redeem_amount) internal {
        pool.withdraw(address(want), _redeem_amount, address(this));
    }

    //TODO: internal
    function _getLpReq(uint256 _amount) internal view returns (uint256 _lpReq) {
        uint256 lp = uint256(countLpPooled());
        uint256 balance = balanceLp();
        uint256 percent = ((_amount.mul(BASIS_PRECISION)).div(balance)).add(10); // Add 0.1% because this is not an exact measure
        _lpReq = (lp.mul(percent)).div(BASIS_PRECISION);
    }

    //  withdraws some LP worth _amount, uses withdrawn LP to add to collateral & repay debt
    function _withdrawLpRebalanceCollateral(uint256 _amount) internal {
        uint256 lpPooled = countLpPooled();
        uint256 lpReq = _getLpReq(_amount);

        uint256 lpWithdraw;
        if (lpReq < lpPooled) {
            lpWithdraw = lpReq;
        } else {
            lpWithdraw = lpPooled;
        }
        _withdrawSomeLp(lpWithdraw);
        uint256 wantBal = balanceOfWant();
        if (_amount.div(2) <= wantBal) {
            _lendWant(_amount.div(2));
        } else {
            _lendWant(wantBal);
        }
        _repayDebt();
    }

    function _addToLP(uint256 _amountShort) internal {
        uint256 _amountWant = convertShortToWantLP(_amountShort);

        uint256 balWant = want.balanceOf(address(this));
        if (balWant < _amountWant) {
            _amountWant = balWant;
        }
        //uint256 _amountWant = want.balanceOf(address(this));
        if (tokenId != 0) {
            if (wantShortLP.token0() == address(want)) {
                manager.deposit(tokenId, _amountWant, _amountShort, false); // TODO: BALANCE param was false REEVALUATE
            } else {
                manager.deposit(tokenId, _amountShort, _amountWant, false);
            }
        } else {
            if (wantShortLP.token0() == address(want)) {
                (tokenId, , ) = manager.newPosition(
                    IUniswapManager.positionParameters(
                        address(want),
                        address(short),
                        _amountWant,
                        _amountShort,
                        poolFee,
                        twapTime,
                        tickRangeMultiplier,
                        false
                    )
                );
            } else {
                (tokenId, , ) = manager.newPosition(
                    IUniswapManager.positionParameters(
                        address(short),
                        address(want),
                        _amountShort,
                        _amountWant,
                        poolFee,
                        twapTime,
                        tickRangeMultiplier,
                        false
                    )
                );
            }
        }
    }

    // Farm-specific methods
    /*
    function _depositLp() internal virtual;

    function _withdrawFarm(uint256 _amount) internal virtual;
    */

    //TODO: internal
    function _withdrawSomeLp(uint256 _amount) internal {
        //require(_amount <= countLpPooled());
        manager.withdraw(tokenId, uint128(_amount));
    }

    // all LP currently not in Farm is removed.
    function _removeAllLp() internal {
        if (tokenId == 0) {
            return;
        }
        manager.destroyPosition(tokenId);
        tokenId = 0;
    }

    /**
     * @notice
     *  Swaps _amount of want for short
     *
     * @param _amount The amount of want to swap
     *
     * @return slippageWant Returns the cost of fees + slippage in want
     */
    function _swapExactWantShort(uint256 _amount)
        internal
        returns (uint256 slippageWant)
    {
        uint256 desired = convertWantToShortLP(_amount);
        uint256 amountOutMin = (desired.mul(slippageAdj).div(BASIS_PRECISION));
        //.add(10);
        if (amountOutMin < 1000) {
            return 0;
        }
        uint256 amountOut =
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(want),
                    tokenOut: address(short),
                    fee: poolFee,
                    recipient: address(this),
                    amountIn: _amount,
                    amountOutMinimum: //amountOutMinimum: amountOutMin, // TODO: No slippage?
                    0,
                    sqrtPriceLimitX96: 0
                })
            );
        if (convertShortToWantLP(amountOut) < convertShortToWantLP(desired)) {
            return
                convertShortToWantLP(desired).sub(
                    convertShortToWantLP(amountOut)
                );
        } else {
            return 0;
        }
    }

    function _swapWantShortExact(uint256 _amountOut)
        internal
        returns (uint256 _slippageWant)
    {
        uint256 amountInWant = convertShortToWantLP(_amountOut);
        uint256 amountInMax =
            (amountInWant.mul(BASIS_PRECISION).div(slippageAdj)).add(10); // add 1 to make up for rounding down
        uint256 realIn =
            router.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: address(want),
                    tokenOut: address(short),
                    fee: poolFee,
                    recipient: address(this),
                    amountOut: _amountOut,
                    amountInMaximum: amountInMax,
                    sqrtPriceLimitX96: 0
                })
            );
        if (realIn > amountInWant) {
            _slippageWant = realIn.sub(amountInWant);
        }
    }

    /**
     * @notice
     *  Swaps _amount of short for want
     *
     * @param _amountShort The amount of short to swap
     *
     * @return _amountWant Returns the want amount minus fees
     * @return _slippageWant Returns the cost of fees + slippage in want
     */

    function _swapExactShortWant(uint256 _amountShort)
        internal
        returns (uint256 _amountWant, uint256 _slippageWant)
    {
        uint256 desired = convertShortToWantLP(_amountShort);
        /*
        uint256 amountOutMin =
            (
                desired.mul(slippageAdj).div(
                    BASIS_PRECISION
                )
            );
                //.add(10);
        */

        _amountWant = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(short),
                tokenOut: address(want),
                fee: poolFee,
                recipient: address(this),
                amountIn: _amountShort,
                amountOutMinimum: //amountOutMinimum: amountOutMin, //TODO: revist
                0,
                sqrtPriceLimitX96: 0
            })
        );
        if (desired > _amountWant) _slippageWant = desired.sub(_amountWant);
    }

    // This has been put into the contract in the unlikely event of a breaking change in uniswap.
    // To be used if sweepNFT doesnt do the trick.
    function exec(address _target, bytes memory _data) external onlyGovernance {
        // Make the function call
        (bool success, bytes memory result) = _target.call(_data);

        // success is false if the call reverts, true otherwise
        require(success, "Call failed");

        // result contains whatever has returned the function
        emit ExecutionResult(success, result);
    }

    function sweepNFT(address _to) external onlyGovernance {
        manager.sweepNFT(_to, tokenId);
    }

    /**
     * @notice
     *  Intentionally not implmenting this. The justification being:
     *   1. It doesn't actually add any additional security because gov
     *      has the powers to do the same thing with addStrategy already
     *   2. Being able to sweep tokens from a strategy could be helpful
     *      incase of an unexpected catastropic failure.
     */
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
}
