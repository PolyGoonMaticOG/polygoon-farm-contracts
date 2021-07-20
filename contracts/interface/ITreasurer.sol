// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// Rewards manager
interface ITreasurer {
  // Assigns reward to user
  function rewardUser(address _user, uint256 _amount) external;
  // Allows user to claim reward
  function claimReward(uint256[]  calldata _weeksToClaim) external;
}