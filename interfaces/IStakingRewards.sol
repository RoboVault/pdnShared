// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

// 0xbB703E95348424FF9e94fbE4FB524f6d280331B8 -> for WETH/USDC

// Factory is at  https://polygonscan.com/address/0x8aaa5e259f74c8114e0a471d9f2adfc66bfe09ed#code

interface IStakingRewards {
    // Views
    function lastTimeRewardApplicable() external view returns (uint256);

    function rewardPerToken() external view returns (uint256);

    function earned(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    // Mutative

    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function getReward() external;

    function exit() external;
}
