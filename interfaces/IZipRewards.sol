// SPDX-License-Identifier: MIT
// based on MiniChefV2 from Sushiswap, fixed some bugs and added possibility of zapping out

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

struct ZipUserInfo {
    uint256 amount; // How many LP tokens the user has provided.
    uint256 rewardDebt; // Reward debt.
}

interface IZipRewards {
    function pendingReward(uint256 _pid, address _user)
        external
        view
        returns (uint256 pending);

    function deposit(
        uint256 pid,
        uint128 amount,
        address to
    ) external;

    function withdraw(
        uint256 pid,
        uint128 amount,
        address to
    ) external;

    function harvest(uint256 pid, address to) external returns (uint256);

    function userInfo(uint256 _pid, address user)
        external
        view
        returns (ZipUserInfo calldata);
}
