// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../../CoreStrategyAaveUni.sol";
import "../../interfaces/IStakingDualRewards.sol";
import "../../interfaces/aave/IAaveOracle.sol";
//import "../../interfaces/miniFarmV2.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// Pool address -> 0x794a61358d6845594f94dc1db02a252b5b4814ad
// AAVE addresses: https://docs.aave.com/developers/deployed-contracts/v3-mainnet/polygon
contract WETHUSDCAAVEUNI is CoreStrategyAaveUni {
    using SafeERC20 for IERC20;

    constructor(address _vault, address _manager)
        public
        CoreStrategyAaveUni(
            _vault,
            CoreStrategyAaveUniConfig(
                0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, // want -> WETH
                0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8, // short -> USDC
                0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8, // aToken
                0xFCCf3cAbbe80101232d343252614b6A3eE81C989, // variableDebtToken
                0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb, // PoolAddressesProvider
                1e4, // mindeploy
                _manager, // manager
                0x1F98431c8aD98523631AE4a59f267346ea31F984, // uniFactory;
                500, // poolFee
                500, // tickRangeMultiplier
                0, // twapTime
                0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45 // router
            )
        )
    {}

    function claimHarvest() internal override {
        if (tokenId != 0) IUniswapManager(manager).collectPositionFees(tokenId);
    }

    function countLpPooled() internal view override returns (uint256) {
        return manager.getLiquidity(tokenId);
    }
}
