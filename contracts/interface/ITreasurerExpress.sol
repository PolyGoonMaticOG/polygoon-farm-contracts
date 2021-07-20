// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import './ITreasurer.sol';

// ITreasurer extension to allow express claim
interface ITreasurerExpress is ITreasurer {
  // Allows user to claim reward in an express way
  function claimRewardExpress(uint256[]  calldata _weeksToClaim) external;
}