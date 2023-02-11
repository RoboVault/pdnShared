// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

// Gauge for Velodrome rewards
// https://github.com/code-423n4/2022-05-velodrome/blob/main/contracts/contracts/Gauge.sol
// Gauges are used to incentivize pools, they emit reward tokens every 7 days for staked LP tokens

interface IGauge {
    function depositAll(uint256 tokenId) external;

    function withdrawAll() external;

    function withdraw(uint256 amount) external;

    function getReward(address account, address[] memory tokens) external;

    function earned(address token, address account)
        external
        view
        returns (uint256);

    function balanceOf(address) external view returns (uint256);
}
