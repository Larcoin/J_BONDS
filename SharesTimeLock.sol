// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./base/DelegationModule.sol";
import "./libraries/LowGasSafeMath.sol";
import "./interfaces/ISharesTimeLock.sol";


contract SharesTimeLock is ISharesTimeLock, DelegationModule, Ownable() {
  using LowGasSafeMath for uint256;
  using TransferHelper for address;

/** ========== Constants ==========  */

  /**
   * @Larcoin Token used for dividend payments and given to users for deposits.
   * Must be an ERC20DividendsOwned with this contract set as the owner.
   */
  address public immutable override dividendsToken;

  /**
   * @dev Minimum number of seconds shares can be locked for.
   */
  uint32 public immutable override minLockDuration;

  /**
   * @dev Maximum number of seconds shares can be locked for.
   */
  uint32 public immutable override maxLockDuration;

  /**
   * @dev Minimum early withdrawal fee added to every dynamic withdrawal fee.
   */
  uint256 public immutable override minEarlyWithdrawalFee;

  /**
   * @dev Base early withdrawal fee expressed as a fraction of 1e18.
   * This is the fee paid if tokens are withdrawn immediately after being locked.
   * It is multiplied by the dividend multiplier, and added to the minimum early withdrawal fee.
   */
  uint256 public immutable override baseEarlyWithdrawalFee;

  /**
   * @dev Maximum dividends multiplier for a lock duration of `maxLockDuration`
   */
  uint256 public immutable override maxDividendsBonusMultiplier;

/** ========== Storage ==========  */

  /**
   * @dev Array of token locks.
   */
  Lock[] public override locks;

  /**
   * @dev Account which receives fees taken for early withdrawals.
   */
  address public override feeRecipient;

  /**
   * @dev Minimum amount of tokens that can be deposited.
   * If zero, there is no minimum.
   */
  uint96 public override minimumDeposit;

  /**
   * @dev Accumulated early withdrawal fees.
   */
  uint96 public override pendingFees;

  /**
   * @dev Allows all locked tokens to be withdrawn with no fees.
   */
  bool public override emergencyUnlockTriggered;

/** ========== Queries ==========  */

  /**
   * @dev Returns the number of locks that have been created.
   */
  function getLocksLength() external view override returns (uint256) {
    return locks.length;
  }

  /**
   * @dev Returns the dividends multiplier for `duration` expressed as a fraction of 1e18.
   */
  function getDividendsMultiplier(uint256 duration) public view override returns (uint256 multiplier) {
    require(duration >= minLockDuration && duration <= maxLockDuration, "OOB");
    uint256 durationRange = maxLockDuration - minLockDuration;
    uint256 overMinimum = duration - minLockDuration;
    return uint256(1e18).add(
      maxDividendsBonusMultiplier.mul(overMinimum) / durationRange
    );
  }

  /**
   * @dev Returns the withdrawal fee and withdrawable shares for a withdrawal of a
   * lock created at `lockedAt` with a duration of `lockDuration`, if it was withdrawan
   * now.
   *
   * The early withdrawal fee is 0 if the full duration has passed or the emergency unlock
   * has been triggered; otherwise, it is calculated as the fraction of the total duration
   * that has not elapsed multiplied by the maximum base withdrawal fee and the dividends
   * multiplier, plus the minimum withdrawal fee.
   */
  function getWithdrawalParameters(
    uint256 amount,
    uint256 lockedAt,
    uint256 lockDuration
  )
    public
    view
    override
    returns (uint256 dividendShares, uint256 earlyWithdrawalFee)
  {
    uint256 multiplier = getDividendsMultiplier(lockDuration);
    dividendShares = amount.mul(multiplier) / uint256(1e18);
    uint256 unlockAt = lockedAt + lockDuration;
    if (block.timestamp >= unlockAt || emergencyUnlockTriggered) {
      earlyWithdrawalFee = 0;
    } else {
      uint256 timeRemaining = unlockAt - block.timestamp;
      uint256 minimumFee = amount.mul(minEarlyWithdrawalFee) / uint256(1e18);
      uint256 dynamicFee = amount.mul(
        baseEarlyWithdrawalFee.mul(timeRemaining).mul(multiplier)
      ) / uint256(1e36 * lockDuration);
      earlyWithdrawalFee = minimumFee.add(dynamicFee);
    }
  }

/** ========== Constructor ==========  */

  constructor(
    address depositToken_,
    address dividendsToken_,
    uint32 minLockDuration_,
    uint32 maxLockDuration_,
    uint256 minEarlyWithdrawalFee_,
    uint256 baseEarlyWithdrawalFee_,
    uint256 maxDividendsBonusMultiplier_
  ) DelegationModule(depositToken_) {
    dividendsToken = dividendsToken_;
    require(minLockDuration_ < maxLockDuration_, "min>=max");
    require(
      minEarlyWithdrawalFee_.add(baseEarlyWithdrawalFee_.mul(maxDividendsBonusMultiplier_)) <= 1e36,
      "maxFee"
    );
    minLockDuration = minLockDuration_;
    maxLockDuration = maxLockDuration_;
    maxDividendsBonusMultiplier = maxDividendsBonusMultiplier_;
    minEarlyWithdrawalFee = minEarlyWithdrawalFee_;
    baseEarlyWithdrawalFee = baseEarlyWithdrawalFee_;
  }

/** ========== Controls ==========  */

  /**
   * @dev Trigger an emergency unlock which allows all locked tokens to be withdrawn
   * with zero fees.
   */
  function triggerEmergencyUnlock() external override onlyOwner {
    require(!emergencyUnlockTriggered, "already triggered");
    emergencyUnlockTriggered = true;
    emit EmergencyUnlockTriggered();
  }

  /**
   * @dev Set the minimum deposit to `minimumDeposit_`. If it is 0, there will be no minimum.
   */
  function setMinimumDeposit(uint96 minimumDeposit_) external override onlyOwner {
    minimumDeposit = minimumDeposit_;
    emit MinimumDepositSet(minimumDeposit_);
  }

  /**
   * @dev Set the account which receives fees taken for early withdrawals.
   */
  function setFeeRecipient(address feeRecipient_) external override onlyOwner {
    feeRecipient = feeRecipient_;
    emit FeeRecipientSet(feeRecipient_);
  }

/** ========== Fees ==========  */

  /**
   * @dev Transfers accumulated early withdrawal fees to the fee recipient.
   */
  function distributeFees() external override {
    address recipient = feeRecipient;
    require(recipient != address(0), "no recipient");
    uint256 amount = pendingFees;
    require(amount > 0, "no fees");
    pendingFees = 0;
    depositToken.safeTransfer(recipient, amount);
    emit FeesTransferred(amount);
  }

/** ========== Locks ==========  */

  /**
   * @dev Lock `amount` of `depositToken` for `duration` seconds.
   *
   * Mints an amount of dividend tokens equal to the amount of tokens locked
   * times 1 + (duration-minDuration) / (maxDuration - minDuration).
   *
   * Uses transferFrom - caller must have approved the contract to spend `amount`
   * of `depositToken`.
   *
   * If the emergency unlock has been triggered, deposits will fail.
   *
   * `amount` must be greater than `minimumDeposit`.
   */
  function deposit(uint256 amount, uint32 duration) external override returns (uint256 lockId) {
    require(amount >= minimumDeposit, "min deposit");
    require(!emergencyUnlockTriggered, "deposits blocked");
    _depositToModule(msg.sender, amount);
    uint256 multiplier = getDividendsMultiplier(duration);
    uint256 dividendShares = amount.mul(multiplier) / 1e18;
    IERC20DividendsOwned(dividendsToken).mint(msg.sender, dividendShares);
    lockId = locks.length;
    locks.push(Lock({
      amount: amount,
      lockedAt: uint32(block.timestamp),
      lockDuration: duration,
      owner: msg.sender
    }));
    emit LockCreated(
      lockId,
      msg.sender,
      amount,
      dividendShares,
      duration
    );
  }

  /**
   * @dev Withdraw the tokens locked in `lockId`.
   * The caller will incur an early withdrawal fee if the lock duration has not elapsed.
   * All of the dividend tokens received when the lock was created will be burned from the
   * caller's account.
   * This can only be executed by the lock owner.
   */
  function destroyLock(uint256 lockId) external override {
    withdraw(lockId, locks[lockId].amount);
  }

  function withdraw(uint256 lockId, uint256 amount) public override {
    Lock storage lock = locks[lockId];
    require(msg.sender == lock.owner, "!owner");
    lock.amount = lock.amount.sub(amount, "insufficient locked tokens");
    (uint256 owed, uint256 dividendShares) = _withdraw(lock, amount);
    if (lock.amount == 0) {
      delete locks[lockId];
      emit LockDestroyed(lockId, msg.sender, owed, dividendShares);
    } else {
      emit PartialWithdrawal(lockId, msg.sender, owed, dividendShares);
    }
  }

  function _withdraw(Lock memory lock, uint256 amount) internal returns (uint256 owed, uint256 dividendShares) {
    uint256 earlyWithdrawalFee;
    (dividendShares, earlyWithdrawalFee) = getWithdrawalParameters(
      amount,
      uint256(lock.lockedAt),
      uint256(lock.lockDuration)
    );
    owed = amount.sub(earlyWithdrawalFee);

    IERC20DividendsOwned(dividendsToken).burn(msg.sender, dividendShares);
    if (earlyWithdrawalFee > 0) {
      _withdrawFromModule(msg.sender, address(this), amount);
      depositToken.safeTransfer(msg.sender, owed);
      pendingFees = safe96(uint256(pendingFees).add(earlyWithdrawalFee));
      emit FeesReceived(earlyWithdrawalFee);
    } else {
      _withdrawFromModule(msg.sender, msg.sender, amount);
    }
  }

  function safe96(uint256 n) internal pure returns (uint96) {
    require(n < 2**96, "amount exceeds 96 bits");
    return uint96(n);
  }

  /**
   * @dev Delegate all voting shares the caller has in its sub-delegation module
   * to `delegatee`.
   * This will revert if the sub-delegation module does not exist.
   */
  function delegate(address delegatee) external override {
    _delegateFromModule(msg.sender, delegatee);
  }
}


interface IERC20DividendsOwned {
  function mint(address to, uint256 amount) external;
  function burn(address from, uint256 amount) external;
  function distribute(uint256 amount) external;
}
