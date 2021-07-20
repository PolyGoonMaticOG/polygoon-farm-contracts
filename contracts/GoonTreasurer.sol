// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import './interface/ITreasurerExpress.sol';
import './GoonToken.sol';

import './lib/TreasurerUtils.sol';

import 'hardhat/console.sol';

contract GoonTreasurer is ITreasurerExpress, Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.UintSet;

  modifier onlyMaster {
    require(msg.sender == master, "GoonTreasurer: caller is not the master");
    _;
  }

  // User informations to keep track of what is still to pay.
  struct UserInfo {
    // Keeps track of all the weeks that have unclaimed rewards for this user.
    EnumerableSet.UintSet weeksToPay;
    // Record of the amount of reward due per week.
    mapping(uint256 => uint256) rewardsPerWeek;
  }

  uint256 public constant MIN_LOCKUP_WEEKS = 4;
  uint256 public constant MAX_LOCKUP_WEEKS = 24;

  // The GOON token
  PolyGoonToken public immutable goon;
  // MasterGoon address
  address public master;

  // The informations of each user
  mapping(address => UserInfo) private userInfo;
  // The total amount of GOON that still needs to be paid. Must be less or equal
  // to this contract's GOON balance.
  uint256 public totalLocked = 0;

  // Part of a reward that will be locked up.
  uint256 public lockedRewardsBP;
  // Part of a locked up reward that will be burnt in an express withdrawal
  uint256 public expressClaimBurnBP;
  // Lockup time in weeks
  uint256 public lockupTimeW;
  // Moment of the week when new unlocks happen, in seconds
  uint256 public unlockMoment = 0;

  event Claim(address indexed user, uint256 amount);
  event LockUp(address indexed user, uint256 amount, uint256 time);
  event ExpressClaim(address indexed user, uint256 amountClaimed, uint256 amountBurnt);

  constructor(
    address _master,
    PolyGoonToken _goon,
    uint256 _lockedRewardsBP,
    uint256 _expressClaimBurnBP,
    uint256 _lockupTimeW
  ) {
    master = _master;
    goon = _goon;
    require(
      _lockedRewardsBP <= 10000,
      "GoonTreasurer: lockedRewardsBP must be <= 10000 BP (100%)"
    );
    lockedRewardsBP = _lockedRewardsBP;
    require(
      _expressClaimBurnBP <= 10000,
      "GoonTreasurer: expressClaimBurnBP must be <= 10000 BP (100%)"
    );
    expressClaimBurnBP = _expressClaimBurnBP;
    require(
      _lockupTimeW >= MIN_LOCKUP_WEEKS && _lockupTimeW <= MAX_LOCKUP_WEEKS,
      "GoonTreasurer: lockupTimeW must be inbetween 4 and 24 weeks"
    );
    lockupTimeW =  _lockupTimeW;
  }

  // Updates master address
  function updateMaster(address _newMaster) public onlyOwner {
    master = _newMaster;
  }

  // Updates lockedRewardsBP value
  function updateLockedRewardsBP(uint256 _newLockedRewardsBP) public onlyOwner {
    require(
      _newLockedRewardsBP <= 10000,
      "GoonTreasurer: lockedRewardsBP must be <= 10000 BP (100%)"
    );
    lockedRewardsBP = _newLockedRewardsBP;
  }

    // Updates expressClaimBurnBP value
  function updateExpressClaimBurnBP(uint256 _newExpressClaimBurnBP) public onlyOwner {
    require(
      _newExpressClaimBurnBP <= 10000,
      "GoonTreasurer: expressClaimBurnBP must be <= 10000 BP (100%)"
    );
    expressClaimBurnBP = _newExpressClaimBurnBP;
  }

  // Update the amount of weeks to lock rewards for
  function updateLockupTimeW(uint256 _newLockupTimeW) public onlyOwner {
    require(
      lockupTimeW >= MIN_LOCKUP_WEEKS && lockupTimeW <= MAX_LOCKUP_WEEKS,
      "GoonTreasurer: lockupTimeW must be inbetween 4 and 24 weeks"
    );
    lockupTimeW = _newLockupTimeW;
  }

  // Update the moment of the week when unlocking becomes possible
  function updateUnlockMoment(uint256 _newMoment) public onlyOwner {
    require(_newMoment < 7 days, "GoonTreasurer: moment must be less than a week");
    unlockMoment = _newMoment;
  }

  // Returns the next claimable week, that is the first week rewards locked
  // right now would be available for claiming.
  function nextClaimableWeek() public view returns (uint256) {
    return TreasurerUtils.timestampToWeek(block.timestamp) + lockupTimeW;
  }

  // Locks up an amount of reward for a specified user
  function _lockupReward(address _user, uint256 _amount) internal onlyMaster {
    require(
      totalLocked + _amount <= goon.balanceOf(address(this)),
      "GoonTreasurer: no GOON left to reward this user"
    );
    UserInfo storage user = userInfo[_user];
    uint256 nextClaimWeek = nextClaimableWeek();
    user.weeksToPay.add(nextClaimWeek);
    user.rewardsPerWeek[nextClaimWeek] += _amount;
    totalLocked += _amount;
    emit LockUp(_user, _amount, lockupTimeW);
  }

  // Rewards a user using this contract's funds. Sends instant rewards and
  // locks the rest.
  function rewardUser(
    address _user,
    uint256 _amount
  ) public override onlyMaster nonReentrant {
    if (_amount == 0) {
      return;
    }
    require(
      totalLocked + _amount <= goon.balanceOf(address(this)),
      "GoonTreasurer: no GOON left to reward this user"
    );

    uint256 lockedAmount = (lockedRewardsBP * _amount) / 1e4;
    uint256 instantReward = _amount - lockedAmount;

    if (lockedAmount > 0) {
      _lockupReward(_user, lockedAmount);
    }
    _safeGoonTransfer(_user, instantReward);
  }

  function _maxClaimableWeek() internal view returns (uint256) {
    return TreasurerUtils.timestampToWeek(
      block.timestamp - unlockMoment
    );
  }

  // Claims all rewards for specified weeks.
  function claimReward(
    uint256[] calldata _weeksToClaim
  ) public override nonReentrant {
    UserInfo storage user = userInfo[msg.sender];

    uint256 claimableReward = 0;
    uint256 maxClaimableWeek = _maxClaimableWeek();

    uint256 length = _weeksToClaim.length;
    for (uint256 i = 0; i < length; i++) {
      uint256 week = _weeksToClaim[i];
      if (!user.weeksToPay.contains(week) || week > maxClaimableWeek) {
        continue;
      }
      claimableReward += user.rewardsPerWeek[week];
      user.rewardsPerWeek[week] = 0;
      user.weeksToPay.remove(week);
    }
    if (claimableReward > 0) {
      totalLocked -= claimableReward;
      _safeGoonTransfer(msg.sender, claimableReward);
      emit Claim(msg.sender, claimableReward);
    }
  }

  // Claims all rewards for specified weeks.
  // If week is not claimable, burns part of its content.
  function claimRewardExpress(
    uint256[] calldata _weeksToClaim
  ) public override nonReentrant {
    UserInfo storage user = userInfo[msg.sender];
    
    uint256 claimableRewardCompounded = 0;
    uint256 rewardToBurnCompounded = 0;
    uint256 maxClaimableWeek = _maxClaimableWeek();

    uint256 length = _weeksToClaim.length;
    for (uint256 i = 0; i < length; i++) {
      uint256 week = _weeksToClaim[i];
      if (!user.weeksToPay.contains(week)) {
        continue;
      }
      if (week > maxClaimableWeek) {
        uint256 weekReward = user.rewardsPerWeek[week];
        uint256 rewardToBurn = (expressClaimBurnBP * weekReward) / 1e4;
        rewardToBurnCompounded += rewardToBurn;
        claimableRewardCompounded += weekReward - rewardToBurn;
      }
      else {
        claimableRewardCompounded += user.rewardsPerWeek[week];
      }
      user.rewardsPerWeek[week] = 0;
      user.weeksToPay.remove(week);
    }

    if (rewardToBurnCompounded > 0) {
      totalLocked -= rewardToBurnCompounded;
      goon.burn(rewardToBurnCompounded);
    }
    if (claimableRewardCompounded > 0) {
      totalLocked -= claimableRewardCompounded;
      _safeGoonTransfer(msg.sender, claimableRewardCompounded);
    }
    if (claimableRewardCompounded > 0 || rewardToBurnCompounded > 0) {
      emit ExpressClaim(msg.sender, claimableRewardCompounded, rewardToBurnCompounded);
    }
  }

  // Returns a list of weeks with rewards for user
  function weeksToPay(address _user) public view returns (uint256[] memory) {
    EnumerableSet.UintSet storage _weeksToPay = userInfo[_user].weeksToPay;
    uint256 length = _weeksToPay.length();
    uint256[] memory weeksList = new uint256[](length);
    for (uint256 i = 0; i < length; i++) {
      weeksList[i] = _weeksToPay.at(i);
    }
    return weeksList;
  }

    // Returns a list of weeks with rewards that are claimable for user
  function claimableWeeksToPay(address _user) public view returns (uint256[] memory) {
    EnumerableSet.UintSet storage _weeksToPay = userInfo[_user].weeksToPay;
    uint256 length = _weeksToPay.length();
    uint256 outLength = 0;
    uint256 maxClaimableWeek = _maxClaimableWeek();

    uint256[] memory claimableWeeksExtended = new uint256[](length);
    for (uint256 i = 0; i < length; i++) {
      uint256 week = _weeksToPay.at(i);
      if (week > maxClaimableWeek) {
        continue;
      }
      claimableWeeksExtended[outLength] = _weeksToPay.at(i);
      outLength++;
    }
    
    uint256[] memory claimableWeeks = new uint256[](outLength);
    for (uint i = 0; i < outLength; i++) {
      claimableWeeks[i] = claimableWeeksExtended[i];
    }
    return claimableWeeks;
  }

  function getRewardForWeek( address _user, uint256 _week) public view returns (uint256) {
    return userInfo[_user].rewardsPerWeek[_week];
  }

  // Returns the total locked rewards for user
  function lockedRewards(address _user) external view returns (uint256) {
    mapping(uint256 => uint256) storage _rewardsPerWeek =
      userInfo[_user].rewardsPerWeek;
    uint256[] memory _weeksToPay = weeksToPay(_user);
    uint256 length = _weeksToPay.length;
    uint256 total = 0;
    for (uint256 i = 0; i < length; i++) {
      total += _rewardsPerWeek[_weeksToPay[i]];
    }
    return total;
  }

  // Returns the total claimable rewards for user
  function claimableRewards(address _user) external view returns (uint256) {
    mapping(uint256 => uint256) storage _rewardsPerWeek =
      userInfo[_user].rewardsPerWeek;
    uint256[] memory _weeksToPay = claimableWeeksToPay(_user);
    uint256 length = _weeksToPay.length;
    uint256 total = 0;
    for (uint256 i = 0; i < length; i++) {
      total += _rewardsPerWeek[_weeksToPay[i]];
    }
    return total;
  }

  // Safe goon transfer function, in case a rounding error causes
  // GoonTreasurer to not have enough GOON ready.
  function _safeGoonTransfer(address _to, uint256 _amount) internal {
    uint256 goonBal = goon.balanceOf(address(this));
    if (_amount > goonBal) {
        require(
          goon.transfer(_to, goonBal),
          "GoonTreasurer: Goon transfer did not succeed"
        );
    } else {
        require(
          goon.transfer(_to, _amount),
          "GoonTreasurer: Goon transfer did not succeed"
        );
    }
  }
}