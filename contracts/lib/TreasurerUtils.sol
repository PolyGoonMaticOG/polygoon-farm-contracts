// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library TreasurerUtils {
  // Converts a week number into a timestamp.
  function weekToTimestamp(uint256 week) internal pure returns (uint256) {
    return week * 7 days + 4 days;
  }

  // Converts a UNIX timestamp to its week number since 1970-01-01
  // Will not work for timestamps below 4 days, but it does not matter,
  // since no time machine has been created so far.
  function timestampToWeek(uint256 timestamp) internal pure returns (uint256) {
    return (timestamp - 4 days) / 7 days;
  }
}
