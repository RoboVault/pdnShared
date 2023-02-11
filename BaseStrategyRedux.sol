// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

struct StrategyParams {
    uint256 performanceFee;
    uint256 activation;
    uint256 debtRatio;
    uint256 minDebtPerHarvest;
    uint256 maxDebtPerHarvest;
    uint256 lastReport;
    uint256 totalDebt;
    uint256 totalGain;
    uint256 totalLoss;
}

interface VaultAPI is IERC20 {
    function name() external view returns (string calldata);

    function symbol() external view returns (string calldata);

    function decimals() external view returns (uint256);

    function apiVersion() external pure returns (string memory);

    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 expiry,
        bytes calldata signature
    ) external returns (bool);

    function deposit() external returns (uint256);

    function deposit(uint256 amount) external returns (uint256);

    function deposit(uint256 amount, address recipient)
        external
        returns (uint256);

    function withdraw() external returns (uint256);

    function withdraw(uint256 maxShares) external returns (uint256);

    function withdraw(uint256 maxShares, address recipient)
        external
        returns (uint256);

    function token() external view returns (address);

    function strategies(address _strategy)
        external
        view
        returns (StrategyParams memory);

    function pricePerShare() external view returns (uint256);

    function totalAssets() external view returns (uint256);

    function depositLimit() external view returns (uint256);

    function maxAvailableShares() external view returns (uint256);

    function creditAvailable() external view returns (uint256);

    function debtOutstanding() external view returns (uint256);

    function expectedReturn() external view returns (uint256);

    function report(
        uint256 _gain,
        uint256 _loss,
        uint256 _debtPayment
    ) external returns (uint256);

    function revokeStrategy() external;

    function governance() external view returns (address);

    function management() external view returns (address);

    function guardian() external view returns (address);
}

interface StrategyAPI {
    function name() external view returns (string memory);

    function vault() external view returns (address);

    function want() external view returns (address);

    function apiVersion() external pure returns (string memory);

    function keeper() external view returns (address);

    function isActive() external view returns (bool);

    function delegatedAssets() external view returns (uint256);

    function estimatedTotalAssets() external view returns (uint256);

    function tendTrigger(uint256 callCost) external view returns (bool);

    function tend() external;

    function harvestTrigger(uint256 callCost) external view returns (bool);

    function harvest() external;

    event Harvested(
        uint256 profit,
        uint256 loss,
        uint256 debtPayment,
        uint256 debtOutstanding
    );
}

interface HealthCheck {
    function check(
        uint256 profit,
        uint256 loss,
        uint256 debtPayment,
        uint256 debtOutstanding,
        uint256 totalDebt
    ) external view returns (bool);
}

/**
 * @title BaseStrategyRedux
 * @author HeroBorg
 * @notice
 * This is an exact copy of BaseStrategy 0.4.3 from yearn, but i removed `ethToWant()` because we always override it and make it return 0
 * Also, I've removed some require error messages
 * This is a solution until we completely revamp the corestrat
 */

abstract contract BaseStrategyRedux {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    string public metadataURI;

    bool public doHealthCheck;
    address public healthCheck;

    function apiVersion() public pure returns (string memory) {
        return "0.4.3";
    }

    function name() external view virtual returns (string memory);

    function delegatedAssets() external view virtual returns (uint256) {
        return 0;
    }

    VaultAPI public vault;
    address public strategist;
    address public rewards;
    address public keeper;

    IERC20 public want;

    event Harvested(
        uint256 profit,
        uint256 loss,
        uint256 debtPayment,
        uint256 debtOutstanding
    );

    event UpdatedStrategist(address newStrategist);

    event UpdatedKeeper(address newKeeper);

    event UpdatedRewards(address rewards);

    event UpdatedMinReportDelay(uint256 delay);

    event UpdatedMaxReportDelay(uint256 delay);

    event UpdatedProfitFactor(uint256 profitFactor);

    event UpdatedDebtThreshold(uint256 debtThreshold);

    event EmergencyExitEnabled();

    event UpdatedMetadataURI(string metadataURI);

    uint256 public minReportDelay;

    uint256 public maxReportDelay;

    uint256 public profitFactor;

    uint256 public debtThreshold;

    bool public emergencyExit;

    modifier onlyAuthorized() {
        require(msg.sender == strategist || msg.sender == governance());
        _;
    }

    modifier onlyEmergencyAuthorized() {
        require(
            msg.sender == strategist ||
                msg.sender == governance() ||
                msg.sender == vault.guardian() ||
                msg.sender == vault.management()
        );
        _;
    }

    modifier onlyStrategist() {
        require(msg.sender == strategist);
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance());
        _;
    }

    modifier onlyKeepers() {
        require(
            msg.sender == keeper ||
                msg.sender == strategist ||
                msg.sender == governance() ||
                msg.sender == vault.guardian() ||
                msg.sender == vault.management()
        );
        _;
    }

    modifier onlyVaultManagers() {
        require(msg.sender == vault.management() || msg.sender == governance());
        _;
    }

    constructor(address _vault) public {
        _initialize(_vault, msg.sender, msg.sender, msg.sender);
    }

    function _initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) internal {
        //Already initialized
        require(address(want) == address(0));

        vault = VaultAPI(_vault);
        want = IERC20(vault.token());
        want.safeApprove(_vault, uint256(-1));
        strategist = _strategist;
        rewards = _rewards;
        keeper = _keeper;

        minReportDelay = 0;
        maxReportDelay = 86400;
        profitFactor = 100;
        debtThreshold = 0;

        vault.approve(rewards, uint256(-1));
    }

    function setHealthCheck(address _healthCheck) external onlyVaultManagers {
        healthCheck = _healthCheck;
    }

    function setDoHealthCheck(bool _doHealthCheck) external onlyVaultManagers {
        doHealthCheck = _doHealthCheck;
    }

    function setStrategist(address _strategist) external onlyAuthorized {
        require(_strategist != address(0));
        strategist = _strategist;
        emit UpdatedStrategist(_strategist);
    }

    function setKeeper(address _keeper) external onlyAuthorized {
        require(_keeper != address(0));
        keeper = _keeper;
        emit UpdatedKeeper(_keeper);
    }

    function setRewards(address _rewards) external onlyStrategist {
        require(_rewards != address(0));
        vault.approve(rewards, 0);
        rewards = _rewards;
        vault.approve(rewards, uint256(-1));
        emit UpdatedRewards(_rewards);
    }

    function setMinReportDelay(uint256 _delay) external onlyAuthorized {
        minReportDelay = _delay;
        emit UpdatedMinReportDelay(_delay);
    }

    function setMaxReportDelay(uint256 _delay) external onlyAuthorized {
        maxReportDelay = _delay;
        emit UpdatedMaxReportDelay(_delay);
    }

    function setProfitFactor(uint256 _profitFactor) external onlyAuthorized {
        profitFactor = _profitFactor;
        emit UpdatedProfitFactor(_profitFactor);
    }

    function setDebtThreshold(uint256 _debtThreshold) external onlyAuthorized {
        debtThreshold = _debtThreshold;
        emit UpdatedDebtThreshold(_debtThreshold);
    }

    function setMetadataURI(string calldata _metadataURI)
        external
        onlyAuthorized
    {
        metadataURI = _metadataURI;
        emit UpdatedMetadataURI(_metadataURI);
    }

    function governance() internal view returns (address) {
        return vault.governance();
    }

    // Removing ethToWant() because we always override it and put it to 0
    //function ethToWant(uint256 _amtInWei) public view virtual returns (uint256);

    function estimatedTotalAssets() public view virtual returns (uint256);

    function isActive() public view returns (bool) {
        return
            vault.strategies(address(this)).debtRatio > 0 ||
            estimatedTotalAssets() > 0;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        virtual
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        );

    function adjustPosition(uint256 _debtOutstanding) internal virtual;

    function liquidatePosition(uint256 _amountNeeded)
        internal
        virtual
        returns (uint256 _liquidatedAmount, uint256 _loss);

    function liquidateAllPositions()
        internal
        virtual
        returns (uint256 _amountFreed);

    function tendTrigger(uint256 callCostInWei)
        public
        view
        virtual
        returns (bool)
    {
        return false;
    }

    function tend() external onlyKeepers {
        adjustPosition(vault.debtOutstanding());
    }

    /// @notice the only change is that we set callCost to 0. The behaviour is exactly the same as before, since ethToWant always returned 0
    function harvestTrigger(uint256 callCostInWei)
        public
        view
        virtual
        returns (bool)
    {
        //OLD VERSION
        //uint256 callCost = ethToWant(callCostInWei);
        //NEW VERSION
        uint256 callCost = 0;
        StrategyParams memory params = vault.strategies(address(this));

        if (params.activation == 0) return false;

        if (block.timestamp.sub(params.lastReport) < minReportDelay)
            return false;

        if (block.timestamp.sub(params.lastReport) >= maxReportDelay)
            return true;

        uint256 outstanding = vault.debtOutstanding();
        if (outstanding > debtThreshold) return true;

        uint256 total = estimatedTotalAssets();

        if (total.add(debtThreshold) < params.totalDebt) return true;

        uint256 profit = 0;
        if (total > params.totalDebt) profit = total.sub(params.totalDebt);

        uint256 credit = vault.creditAvailable();
        return (profitFactor.mul(callCost) < credit.add(profit));
    }

    function harvest() external onlyKeepers {
        uint256 profit = 0;
        uint256 loss = 0;
        uint256 debtOutstanding = vault.debtOutstanding();
        uint256 debtPayment = 0;
        if (emergencyExit) {
            uint256 amountFreed = liquidateAllPositions();
            if (amountFreed < debtOutstanding) {
                loss = debtOutstanding.sub(amountFreed);
            } else if (amountFreed > debtOutstanding) {
                profit = amountFreed.sub(debtOutstanding);
            }
            debtPayment = debtOutstanding.sub(loss);
        } else {
            (profit, loss, debtPayment) = prepareReturn(debtOutstanding);
        }

        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        debtOutstanding = vault.report(profit, loss, debtPayment);

        adjustPosition(debtOutstanding);

        if (doHealthCheck && healthCheck != address(0)) {
            require(
                HealthCheck(healthCheck).check(
                    profit,
                    loss,
                    debtPayment,
                    debtOutstanding,
                    totalDebt
                ),
                "!h"
            );
        } else {
            doHealthCheck = true;
        }

        emit Harvested(profit, loss, debtPayment, debtOutstanding);
    }

    function withdraw(uint256 _amountNeeded) external returns (uint256 _loss) {
        require(msg.sender == address(vault));
        uint256 amountFreed;
        (amountFreed, _loss) = liquidatePosition(_amountNeeded);
        want.safeTransfer(msg.sender, amountFreed);
    }

    function prepareMigration(address _newStrategy) internal virtual;

    function migrate(address _newStrategy) external {
        require(msg.sender == address(vault));
        require(BaseStrategyRedux(_newStrategy).vault() == vault);
        prepareMigration(_newStrategy);
        want.safeTransfer(_newStrategy, want.balanceOf(address(this)));
    }

    function setEmergencyExit() external onlyEmergencyAuthorized {
        emergencyExit = true;
        vault.revokeStrategy();

        emit EmergencyExitEnabled();
    }

    function protectedTokens() internal view virtual returns (address[] memory);

    function sweep(address _token) external onlyGovernance {
        require(_token != address(want));
        require(_token != address(vault));

        address[] memory _protectedTokens = protectedTokens();
        for (uint256 i; i < _protectedTokens.length; i++)
            require(_token != _protectedTokens[i]);

        IERC20(_token).safeTransfer(
            governance(),
            IERC20(_token).balanceOf(address(this))
        );
    }
}

// NOTE: we do not use it, if you need it, just use the one from yearn
// abstract contract BaseStrategyInitializable is BaseStrategy {
//     bool public isOriginal = true;
//     event Cloned(address indexed clone);

//     constructor(address _vault) public BaseStrategy(_vault) {}

//     function initialize(
//         address _vault,
//         address _strategist,
//         address _rewards,
//         address _keeper
//     ) external virtual {
//         _initialize(_vault, _strategist, _rewards, _keeper);
//     }

//     function clone(address _vault) external returns (address) {
//         require(isOriginal, "!clone");
//         return this.clone(_vault, msg.sender, msg.sender, msg.sender);
//     }

//     function clone(
//         address _vault,
//         address _strategist,
//         address _rewards,
//         address _keeper
//     ) external returns (address newStrategy) {
//         bytes20 addressBytes = bytes20(address(this));

//         assembly {
//             let clone_code := mload(0x40)
//             mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
//             mstore(add(clone_code, 0x14), addressBytes)
//             mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
//             newStrategy := create(0, clone_code, 0x37)
//         }

//         BaseStrategyInitializable(newStrategy).initialize(_vault, _strategist, _rewards, _keeper);

//         emit Cloned(newStrategy);
//     }
// }
