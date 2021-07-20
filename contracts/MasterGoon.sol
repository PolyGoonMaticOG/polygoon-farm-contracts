// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';

import './interface/ITreasurer.sol';
import './GoonToken.sol';

import 'hardhat/console.sol';

// MasterGoon is the master of Goon. He manages Goon and is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once GOON is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug free.
contract MasterGoon is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  modifier onlyDev {
    require(msg.sender == dev, "MasterGoon Dev: caller is not the dev");
    _;
  }

  modifier onlyFeeCollector {
    require(
      msg.sender == feeCollector,
      "MasterGoon Fee Collector: caller is not the fee collector"
    );
    _;
  }

  // Category informations
  struct CatInfo {
    // Allocation points assigned to this category
    uint256 allocPoints;
    // Total pool allocation points. Must be at all time equal to the sum of all
    // pool allocation points in this category.
    uint256 totalPoolAllocPoints;
    // Name of this category
    string name;
  }

  // User informations
  struct UserInfo {
    // Amount of tokens deposited
    uint256 amount;
    // Reward debt.
    //
    // We do some fancy math here. Basically, any point in time, the amount of SUSHIs
    // entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.amount * pool.accSushiPerShare) - user.rewardDebt
    //
    // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
    //   1. The pool's `accSushiPerShare` (and `lastRewardBlock`) gets updated.
    //   2. User receives the pending reward sent to his/her address.
    //   3. User's `amount` gets updated.
    //   4. User's `rewardDebt` gets updated.
    uint256 rewardDebt;
    // Time at which user can harvest this pool again
    uint256 nextHarvestTime;
    // Reward that will be unlockable when nextHarvestTime is reached
    uint256 lockedReward;
  }

  // Pool informations
  struct PoolInfo {
    // Address of this pool's token
    IERC20 token;
    //Category ID of this pool
    uint256 catId;
    // Allocation points assigned to this pool
    uint256 allocPoints;
    // Last block where GOON was distributed.
    uint256 lastRewardBlock;
    // Accumulated GOON per share, times 1e18. Used for rewardDebt calculations.
    uint256 accGoonPerShare;
    // Deposit fee for this pool, in basis points (from 0 to 10000)
    uint256 depositFeeBP;
    // Harvest interval for this pool, in seconds
    uint256 harvestInterval;
  }

  // The following limits exist to ensure that the owner of MasterGoon will
  // only modify the contract's settings in a specific range of value, that
  // the users can see by themselves at any time.

  // Maximum harvest interval that can be set
  uint256 public constant MAX_HARVEST_INTERVAL = 24 hours;
  // Maximum deposit fee that can be set
  uint256 public constant MAX_DEPOSIT_FEE_BP = 400;
  // Maximum goon reward per block that can be set
  uint256 public constant MAX_GOON_PER_BLOCK = 1e18;

  // The informations of each category
  CatInfo[] public catInfo;
  // The pools in each category. Used in front.
  mapping(uint256 => uint256[]) public catPools;
  // Total category allocation points. Must be at all time equal to the sum of
  // all category allocation points.
  uint256 public totalCatAllocPoints = 0;

  // The informations of each pool
  PoolInfo[] public poolInfo;
  // Mapping to keep track of which token has been added, and its index in the
  // array.
  mapping(address => uint256) public tokensAdded;
  // The informations of each user, per pool
  mapping(uint256 => mapping(address => UserInfo)) public userInfo;

  // The GOON token
  PolyGoonToken public immutable goon;
  // The Treasurer. Handles rewards.
  ITreasurer public immutable treasurer;
  // GOON minted to devs
  uint256 public devGoonPerBlock;
  // GOON minted as rewards
  uint256 public rewardGoonPerBlock;
  // The address to send dev funds to
  address public dev;
  // The address to send fees to
  address public feeCollector;
  // Launch block
  uint256 public startBlock;
  // Farming duration, in blocks
  uint256 public farmingDuration;

  event CategoryCreate(uint256 id, string indexed name, uint256 allocPoints);
  event CategoryEdit(uint256 id, uint256 allocPoints);

  event PoolCreate(
    address indexed token,
    uint256 indexed catId,
    uint256 allocPoints,
    uint256 depositFeeBP,
    uint256 harvestInterval
  );
  event PoolEdit(
    address indexed token,
    uint256 indexed catId,
    uint256 allocPoints,
    uint256 depositFeeBP,
    uint256 harvestInterval
  );

  event Deposit(
    address indexed user,
    uint256 indexed pid,
    uint256 amount,
    uint256 fee
  );
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event EmergencyWithdraw(
    address indexed user,
    uint256 indexed pid,
    uint256 amount
  );

  constructor(
    PolyGoonToken _goon,
    ITreasurer _treasurer,
    address _dev,
    address _feeCollector,
    uint256 _initGoonPerBlock,
    uint256 _startBlock,
    uint256 _farmingDuration
  ) {
    goon = _goon;
    treasurer = _treasurer;
    require(
      _initGoonPerBlock <= MAX_GOON_PER_BLOCK,
      "MasterGoon: too high goon reward"
    );
    devGoonPerBlock = _initGoonPerBlock / 10;
    rewardGoonPerBlock = _initGoonPerBlock - devGoonPerBlock;
    require(
      _dev != address(0),
      "MasterGoon Dev: null address not permitted"
    );
    dev = _dev;
    require(
      _feeCollector != address(0),
      "MasterGoon Fee Collector: null address not permitted"
    );
    feeCollector = _feeCollector;
    startBlock = _startBlock;
    if (startBlock < block.number) {
      startBlock = block.number;
    }
    require(
      _farmingDuration * MAX_GOON_PER_BLOCK <= _goon.maxSupply() - _goon.totalMinted(),
      "MasterGoon: farming could go above GOON's max supply"
    );
    farmingDuration = _farmingDuration;
  }

  // Update the starting block. Can only be called by the owner.
  // Can only be called before current starting block.
  // Can only be called if there is no pool registered.
  function updateStartBlock(uint256 _newStartBlock) external onlyOwner {
    require(
      block.number < startBlock,
      'MasterGoon: Cannot change startBlock after farming has already started.'
    );
    require(
      poolInfo.length == 0,
      'MasterGoon: Cannot change startBlock after a pool has been registered.'
    );
    require(
      _newStartBlock > block.number,
      'MasterGoon: Cannot change startBlock with a past block.'
    );
    startBlock = _newStartBlock;
  }

  // Update the dev address. Can only be called by the dev.
  function updateDev(address _newDev) onlyDev public {
    require(
      _newDev != address(0),
      "MasterGoon Dev: null address not permitted"
    );
    dev = _newDev;
  }

  // Update the fee address. Can only be called by the fee collector.
  function updateFeeCollector(address _newFeeCollector) onlyFeeCollector public {
    require(
      _newFeeCollector != address(0),
      "MasterGoon Fee Collector: null address not permitted"
    );
    feeCollector = _newFeeCollector;
  }

  // Update the goon per block reward. Can only be called by the owner.
  function updateGoonPerBlock(uint256 _newGoonPerBlock, bool _withUpdate) onlyOwner public {
    require(
      _newGoonPerBlock <= MAX_GOON_PER_BLOCK,
      "MasterGoon: too high goon reward"
    );

    if (_withUpdate) {
      massUpdatePools();
    }
    devGoonPerBlock = _newGoonPerBlock / 10;
    rewardGoonPerBlock = _newGoonPerBlock - devGoonPerBlock;
  }

  // View function to check the total goon generated every block
  function goonPerBlock() public view returns (uint256) {
    return devGoonPerBlock + rewardGoonPerBlock;
  }

  // View function to check if user can harvest pool
  function canHarvest(
    uint256 _poolId,
    address _user
   ) public view returns (bool) {
    return block.timestamp >= userInfo[_poolId][_user].nextHarvestTime;
  }

  // Create a new pool category. Can only be called by the owner.
  function createCategory(
    string calldata _name,
    uint256 _allocPoints,
    bool _withUpdate
  ) public onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }
    
    totalCatAllocPoints += _allocPoints;
    
    catInfo.push(CatInfo({
      name: _name,
      allocPoints: _allocPoints,
      totalPoolAllocPoints: 0
    }));
    
    emit CategoryCreate(catInfo.length - 1, _name, _allocPoints);
  }

  // Edit a pool category. Can only be called by the owner.
  function editCategory(
    uint256 _catId,
    uint256 _allocPoints,
    bool _withUpdate
  ) public onlyOwner {
    require(_catId < catInfo.length, "MasterGoon: category does not exist");
    
    if (_withUpdate) {
      massUpdatePools();
    }
    
    totalCatAllocPoints =
      totalCatAllocPoints - catInfo[_catId].allocPoints + _allocPoints;
    catInfo[_catId].allocPoints = _allocPoints;
    
    emit CategoryEdit(_catId, _allocPoints);
  }

  // Create a new token pool, after checking that it doesn't already exist.
  // Can only be called by owner.
  function createPool(
    uint256 _catId,
    IERC20 _token,
    uint256 _allocPoints,
    uint256 _depositFeeBP,
    uint256 _harvestInterval,
    bool _withUpdate
  ) public onlyOwner {
    require(_catId < catInfo.length, "MasterGoon: category does not exist");
    require(
      _harvestInterval <= MAX_HARVEST_INTERVAL,
      "MasterGoon: too high harvest interval"
    );
    require(
      _depositFeeBP <= MAX_DEPOSIT_FEE_BP,
      "MasterGoon: too high deposit fee"
    );

    address tokenAddress = address(_token);
    require(tokensAdded[tokenAddress] == 0, "MasterGoon: token already registered");
    
    if (_withUpdate) {
      massUpdatePools();
    }

    uint256 lastRewardBlock =
      block.number > startBlock ? block.number : startBlock;
    
    catInfo[_catId].totalPoolAllocPoints += _allocPoints;
    
    tokensAdded[tokenAddress] = poolInfo.length + 1;
    poolInfo.push(PoolInfo({
      catId: _catId,
      token: _token,
      allocPoints: _allocPoints,
      lastRewardBlock: lastRewardBlock,
      accGoonPerShare: 0,
      depositFeeBP: _depositFeeBP,
      harvestInterval: _harvestInterval
    }));
    catPools[_catId].push(poolInfo.length - 1);
    
    emit PoolCreate(
      tokenAddress,
      _catId,
      _allocPoints,
      _depositFeeBP,
      _harvestInterval
    );
  }

  // Edits a new token pool. Can only be called by owner.
  function editPool(
    uint256 _poolId,
    uint256 _allocPoints,
    uint256 _depositFeeBP,
    uint256 _harvestInterval,
    bool _withUpdate
  ) public onlyOwner {
    require(_poolId < poolInfo.length, "MasterGoon: pool does not exist");
    require(
      _harvestInterval <= MAX_HARVEST_INTERVAL,
      "MasterGoon: too high harvest interval"
    );
    require(
      _depositFeeBP <= MAX_DEPOSIT_FEE_BP,
      "MasterGoon: too high deposit fee"
    );

    if (_withUpdate) {
      massUpdatePools();
    }
    
    uint256 catId = poolInfo[_poolId].catId;
    
    catInfo[catId].totalPoolAllocPoints =
      catInfo[catId].totalPoolAllocPoints - poolInfo[_poolId].allocPoints + _allocPoints;
    poolInfo[_poolId].allocPoints = _allocPoints;
    poolInfo[_poolId].depositFeeBP = _depositFeeBP;
    poolInfo[_poolId].harvestInterval = _harvestInterval;
    
    emit PoolEdit(
      address(poolInfo[_poolId].token),
      poolInfo[_poolId].catId,
      _allocPoints,
      _depositFeeBP,
      _harvestInterval
    );
  }

  function getMultiplier(
    uint256 _from,
    uint256 _to
  ) public view returns (uint256) {
    uint256 _endBlock = endBlock();
    if (_from >= _endBlock) {
      return 0;
    }
    if (_to > _endBlock) {
      return _endBlock - _from;
    }
    return _to - _from;
  }

  // Internal function to dispatch pool reward for sender.
  // Does one of two things:
  // - Reward the user through treasurer
  // - Lock up rewards for later harvest
  function _dispatchReward(uint256 _poolId) internal {
    PoolInfo storage pool = poolInfo[_poolId];
    UserInfo storage user = userInfo[_poolId][msg.sender];

    if (user.nextHarvestTime == 0) {
      user.nextHarvestTime = block.timestamp + pool.harvestInterval;
    }

    uint256 pending =
      user.amount * pool.accGoonPerShare / 1e18 - user.rewardDebt;
    if (block.timestamp >= user.nextHarvestTime) {
      if (pending > 0 || user.lockedReward > 0) {
        uint256 totalReward = pending + user.lockedReward;

        user.lockedReward = 0;
        user.nextHarvestTime = block.timestamp + pool.harvestInterval;

        treasurer.rewardUser(msg.sender, totalReward);
      }
    } else if (pending > 0) {
      user.lockedReward += pending;
    }
  }

  // Deposits tokens into a pool.
  function deposit(uint256 _poolId, uint256 _amount) public nonReentrant {
    PoolInfo storage pool = poolInfo[_poolId];
    require(pool.allocPoints != 0, "MasterGoon Deposit: pool is disabled");
    require(
      catInfo[pool.catId].allocPoints != 0,
      "MasterGoon Deposit: category is disabled"
    );
    UserInfo storage user = userInfo[_poolId][msg.sender];

    updatePool(_poolId);
    _dispatchReward(_poolId);

    uint256 depositFee = _amount * pool.depositFeeBP / 1e4;
    if (_amount > 0) {
      pool.token.safeTransferFrom(
        msg.sender,
        address(this),
        _amount
      );

      if (pool.depositFeeBP > 0) {
        pool.token.safeTransfer(feeCollector, depositFee);
        user.amount += _amount - depositFee;
      }
      else {
        user.amount += _amount;
      }
      user.nextHarvestTime = block.timestamp + pool.harvestInterval;
    }
    user.rewardDebt = user.amount * pool.accGoonPerShare / 1e18;

    emit Deposit(msg.sender, _poolId, _amount, depositFee);
  }

  // Withdraw tokens from a pool.
  function withdraw(uint256 _poolId, uint256 _amount) public nonReentrant {
    PoolInfo storage pool = poolInfo[_poolId];
    UserInfo storage user = userInfo[_poolId][msg.sender];
    
    require(user.amount >= _amount, "MasterGoon: bad withdrawal");
    updatePool(_poolId);
    _dispatchReward(_poolId);

    user.amount -= _amount;
    user.rewardDebt = user.amount * pool.accGoonPerShare / 1e18;
    
    if (_amount > 0) {
      pool.token.safeTransfer(msg.sender, _amount);
    }

    emit Withdraw(msg.sender, _poolId, _amount);
  }

  // EMERGENCY ONLY. Withdraw tokens, give rewards up.
  function emergencyWithdraw(uint256 _poolId) public nonReentrant {
    PoolInfo storage pool = poolInfo[_poolId];
    UserInfo storage user = userInfo[_poolId][msg.sender];

    pool.token.safeTransfer(address(msg.sender), user.amount);
    emit EmergencyWithdraw(msg.sender, _poolId, user.amount);
    user.amount = 0;
    user.rewardDebt = 0;
    user.lockedReward = 0;
    user.nextHarvestTime = 0;
  }

  // Update all pool at ones. Watch gas spendings.
  function massUpdatePools() public {
    uint256 length = poolInfo.length;
    for (uint256 poolId = 0; poolId < length; poolId++) {
      updatePool(poolId);
    }
  }

  // Update a single pool's reward variables, and mints rewards.
  // If the pool has no tokenSupply, then the reward will be fully sent to the
  // dev fund. This is done so that the amount of tokens minted every block
  // is stable, and the end of farming is predictable and only impacted by
  // updateGoonPerBlock.
  function updatePool(uint256 _poolId) public {
    PoolInfo storage pool = poolInfo[_poolId];
    if (block.number <= pool.lastRewardBlock
      || pool.allocPoints == 0
      || catInfo[pool.catId].allocPoints == 0
    ) {
      return;
    }
    uint256 tokenSupply = pool.token.balanceOf(address(this));
    if (tokenSupply == 0) {
      pool.lastRewardBlock = block.number;
      return;
    }
    uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
    if (multiplier == 0) {
      pool.lastRewardBlock = block.number;
      return;
    }
    CatInfo storage cat = catInfo[pool.catId];
    uint256 userReward = multiplier * rewardGoonPerBlock
      * pool.allocPoints / cat.totalPoolAllocPoints
      * cat.allocPoints / totalCatAllocPoints;
    uint256 devReward = multiplier * devGoonPerBlock
      * pool.allocPoints / cat.totalPoolAllocPoints
      * cat.allocPoints / totalCatAllocPoints;
    pool.lastRewardBlock = block.number;
    pool.accGoonPerShare += userReward * 1e18 / tokenSupply;
    goon.mint(dev, devReward);
    goon.mint(address(treasurer), userReward);
  }

  function pendingReward(
    uint256 _poolId,
    address _user
  ) external view returns(uint256) {
    PoolInfo storage pool = poolInfo[_poolId];
    UserInfo storage user = userInfo[_poolId][_user];
    CatInfo storage cat = catInfo[pool.catId];
    uint256 accGoonPerShare = pool.accGoonPerShare;
    uint256 tokenSupply = pool.token.balanceOf(address(this));

    if (block.number > pool.lastRewardBlock && tokenSupply != 0) {
      uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
      if (multiplier != 0) {
        uint256 userReward = multiplier * rewardGoonPerBlock
          * pool.allocPoints / cat.totalPoolAllocPoints
          * cat.allocPoints / totalCatAllocPoints;
        accGoonPerShare += userReward * 1e18 / tokenSupply;  
      }
    }
    return user.amount * accGoonPerShare / 1e18 - user.rewardDebt
      + user.lockedReward;
  }

  function poolsLength() external view returns(uint256) {
    return poolInfo.length;
  }

  function categoriesLength() external view returns(uint256) {
    return catInfo.length;
  }

  function poolsInCategory(uint256 _catId) external view returns(uint256[] memory) {
    return catPools[_catId];
  }

  function endBlock() public view returns(uint256) {
    return startBlock + farmingDuration;
  }
}