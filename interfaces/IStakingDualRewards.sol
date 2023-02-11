// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

// https://polygonscan.com/address/0x14977e7E263FF79c4c3159F497D9551fbE769625#code -> for USDC/WMATIC

// Factory is at  0x9Dd12421C637689c3Fc6e661C9e2f02C2F61b3Eb

interface IStakingDualRewards {
    // Views
    function lastTimeRewardApplicable() external view returns (uint256);

    function rewardPerTokenA() external view returns (uint256);

    function rewardPerTokenB() external view returns (uint256);

    function earnedA(address account) external view returns (uint256);

    function earnedB(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    // Mutative

    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function getReward() external;

    function exit() external;
}
