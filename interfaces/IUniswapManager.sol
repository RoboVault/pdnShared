// SPDX-License-Identifier: MIT
import "./ISwapRouter.sol";
import "./IUniswapV3Pool.sol";
import "./IUniswapV3PositionsNFT.sol";
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface IUniswapManager {
    struct positionParameters {
        address _token0;
        address _token1;
        uint256 _amount0;
        uint256 _amount1;
        uint24 _fee;
        uint24 _twapTime;
        int24 _tickRangeMultiplier;
        bool _balance;
    }

    function determineTicks(
        IUniswapV3Pool _pool,
        uint24 _twapTime,
        int24 tickRangeMultiplier
    ) external view returns (int24, int24);

    function getLiquidity(uint256 _tokenId)
        external
        view
        returns (uint128 _liquidity);

    function getLpReserves(uint256 _tokenId)
        external
        view
        returns (uint256 _token0, uint256 _token1);

    function getCurrentTick(uint256 _tokenId)
        external
        view
        returns (int24 tick);

    function getLowerTick(uint256 _tokenId) external view returns (int24 tick);

    function getUpperTick(uint256 _tokenId) external view returns (int24 tick);

    function getPool(
        address _token0,
        address _token1,
        uint24 _fee
    ) external view returns (IUniswapV3Pool);

    function getPriceAtTick(int24 tick) external view returns (uint256);

    function getSqrtTwapX96(IUniswapV3Pool uniswapV3Pool, uint32 twapInterval)
        external
        view
        returns (uint160 sqrtPriceX96);

    function getPriceX96FromSqrtPriceX96(uint160 sqrtPriceX96)
        external
        pure
        returns (uint256 priceX96);

    function getTwapPrice(IUniswapV3Pool _pool, uint32 _time)
        external
        view
        returns (uint256);

    function isUnbalanced(uint256 _tokenId)
        external
        view
        returns (bool _result);

    function setTwapTime(uint256 _tokenId, uint24 _twapTime) external;

    function setTickRangeMultiplier(
        uint256 _tokenId,
        int24 _tickRangeMultiplier
    ) external;

    function newPosition(positionParameters calldata _params)
        external
        returns (
            uint256 _tokenId,
            uint256 _refund0,
            uint256 _refund1
        );

    function deposit(
        uint256 _tokenId,
        uint256 _amount0,
        uint256 _amount1,
        bool _balance
    ) external returns (uint256 _refund0, uint256 _refund1);

    function rebalance(uint256 _currentId) external returns (uint256 _tokenId);

    function withdraw(uint256 _tokenId, uint128 _liquidity) external;

    function destroyPosition(uint256 _tokenId) external;

    function collectPositionFees(uint256 _tokenId) external;

    function sweepNFT(address _to, uint256 _tokenId) external;

    function exec(address _target, bytes memory _data) external;

    function changeAdmin(address _admin) external;

    function acceptAdmin() external;
}
