// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

struct miniFarmInfo {
    uint256 amount; // How many LP tokens the user has provided.
    uint256 rewardDebt; // Reward debt.
}

interface IMiniChefV2 {
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address to
    ) external;

    function withdraw(
        uint256 _pid,
        uint256 _amount,
        address to
    ) external;

    function userInfo(uint256 _pid, address user)
        external
        view
        returns (miniFarmInfo calldata);

    function pendingSushi(uint256 _pid, address _user)
        external
        view
        returns (uint256 pending);

    function pendingTokens(uint256 _pid, address _user)
        external
        view
        returns (uint256 pending);

    function harvest(uint256 _pid, address _to) external;
}
