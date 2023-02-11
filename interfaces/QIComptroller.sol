// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/// @notice Got the methods from https://github.com/Benqi-fi/BENQI-Smart-Contracts/blob/master/Comptroller.sol
interface QIComptroller {
    function claimReward(uint8 rewardType, address payable holder) external;

    function enterMarkets(address[] memory qiTokens)
        external
        returns (uint256[] memory);
}
