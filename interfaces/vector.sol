// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity ^0.6.12;

interface IVectorChef {
    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function balanceOf(address _address) external view returns (uint256);

    function getReward() external;
}

interface IBaseRewardPool {
    function earned(address _account, address _token)
        external
        view
        returns (uint256);
}
