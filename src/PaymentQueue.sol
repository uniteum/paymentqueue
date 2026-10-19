// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";
import {IPrototype} from "iproto/IPrototype.sol";
import {Prototype} from "proto/Prototype.sol";
import {ReentrancyGuardTransient} from "reentrancy/ReentrancyGuardTransient.sol";
import {SafeERC20} from "erc20/SafeERC20.sol";

/**
 * @title PaymentQueue
 * @notice Idempotent ERC-20 payout queues, made by anyone for themselves. The owner submits each
 * payment under an id of its own choosing, so submitting the same payment again, after a lost
 * response or a retry, never pays twice. Each payment names a fee, which the queue keeps for the
 * owner when it pays.
 * @dev A Bitsy prototype (https://uniteum.one/bitsy/): the deployed contract is an inert factory with
 * no owner, and each queue is an EIP-1167 clone of it at a CREATE2 address derived from its owner and
 * token, so {made} can name a queue before it exists. The token may be given as an {IAddressLookup},
 * in which case the address is derived from the lookup and the queue pays in whatever it resolves to
 * on this chain. A queue's owner and token are set once, by {zzInit}, and never change.
 *
 * The line is a mapping walked by a head and a tail index. A settled entry is deleted as the head
 * passes it, so nothing is rescanned. Status is written before each transfer, and both entry points
 * are `nonReentrant`: a token with transfer hooks would otherwise let a recipient re-enter a sweep
 * partway through its own payment.
 *
 * Kept fees are counted in {fees} and left in the token balance, so the funds are what the queue holds
 * less that count. Paying draws a payment's whole amount from the funds: the recipient's share leaves
 * and the fee's share moves from funds to fees.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract PaymentQueue is IPaymentQueue, ReentrancyGuardTransient, Prototype {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;

    struct Entry {
        uint256 id;
        address recipient;
        uint256 amount;
        uint256 fee;
    }

    /**
     * @dev An id's status and the block it was set in, packed into one storage slot.
     */
    struct Record {
        Status status;
        uint64 blockNumber;
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    address public owner;

    /**
     * @inheritdoc IPaymentQueue
     */
    IERC20 public token;

    /**
     * @inheritdoc IPaymentQueue
     */
    uint256 public fees;

    mapping(uint256 id => Record) private _records;
    mapping(uint256 index => Entry) private _queue;
    uint256 private _head;
    uint256 private _tail;

    /**
     * @inheritdoc IPaymentQueue
     */
    function statusOf(uint256 id) external view returns (Status) {
        return _records[id].status;
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function blockOf(uint256 id) external view returns (uint256) {
        return _records[id].blockNumber;
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function queued() external view returns (uint256) {
        return _tail - _head;
    }

    /**
     * @inheritdoc IPaymentQueue
     * @dev Saturates rather than reverting should the balance ever fall below the fee count, which no
     * well-behaved token lets happen: a queue that cannot compute its funds cannot pay or sweep.
     */
    function funds() public view returns (uint256) {
        uint256 held = token.balanceOf(address(this));
        return held > fees ? held - fees : 0;
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function pay(uint256 id, address recipient, uint256 amount, uint256 feeBasisPoints)
        external
        nonReentrant
        returns (Status status)
    {
        if (msg.sender != owner) revert Unauthorized();
        status = _records[id].status;
        if (status != Status.Unknown) return status;
        if (feeBasisPoints > BASIS_POINTS) revert FeeTooHigh(feeBasisPoints);
        uint256 fee = amount * feeBasisPoints / BASIS_POINTS;
        if (_head == _tail && amount <= funds()) {
            status = _settle(id, recipient, amount, fee);
        } else {
            status = Status.Queued;
            _record(id, status);
            _queue[_tail++] = Entry({id: id, recipient: recipient, amount: amount, fee: fee});
            emit PaymentQueued(id, recipient, amount, fee);
        }
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function processPayments(uint256 limit) external nonReentrant returns (uint256 settled) {
        uint256 available = funds();
        uint256 head = _head;
        uint256 tail = _tail;
        while (settled < limit && head < tail) {
            Entry memory entry = _queue[head];
            if (entry.amount > available) break;
            delete _queue[head];
            _head = ++head;
            ++settled;
            if (_settle(entry.id, entry.recipient, entry.amount, entry.fee) == Status.Paid) available -= entry.amount;
        }
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function withdrawFunds(address to, uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        uint256 available = funds();
        if (amount > available) revert InsufficientFunds(available);
        token.safeTransfer(to, amount);
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function withdrawFees(address to, uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        if (amount > fees) revert InsufficientFees(fees);
        fees -= amount;
        token.safeTransfer(to, amount);
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function made(address owner_, address token_, uint256 variant)
        external
        view
        returns (bool exists, address home, bytes32 salt)
    {
        (exists, home, salt) = this.made(encode(owner_, token_), variant);
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function make(address token_, uint256 variant) external returns (IPaymentQueue queue) {
        (, address home,) = this.make(encode(msg.sender, token_), variant);
        queue = IPaymentQueue(home);
    }

    /**
     * @inheritdoc IPrototype
     * @dev Decodes `(owner, token)` into the new queue's storage, resolving the token through its
     * lookup when it was given as one.
     */
    function zzInit(bytes calldata args, uint256) external override onlyProto {
        (address owner_, address token_) = abi.decode(args, (address, address));
        owner = owner_;
        token = _resolve(token_);
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function encode(address owner_, address token_) public pure returns (bytes memory args) {
        args = abi.encode(owner_, token_);
    }

    /**
     * @dev The token behind `token_`. An {IAddressLookup} resolves to its `value()`; any other
     * deployed address is the token itself. Reverts with {UnmappedLookup} when `token_` has no code,
     * since an undeployed lookup or a stray account would otherwise be stored as the token, and when
     * a lookup resolves to `address(0)`, which is how a lookup says its token has not reached this
     * chain.
     */
    function _resolve(address token_) private view returns (IERC20) {
        if (token_.code.length == 0) revert UnmappedLookup(token_);
        try IAddressLookup(token_).value() returns (address resolved) {
            if (resolved == address(0)) revert UnmappedLookup(token_);
            return IERC20(resolved);
        } catch {
            return IERC20(token_);
        }
    }

    /**
     * @dev Transfer the amount less the fee, and record whether it happened; the fee accrues only when
     * it did. `trySafeTransfer` turns a refusal, by revert or by a false return, into `Failed` instead
     * of a revert, so one refused recipient cannot block the line.
     *
     * It cannot tell a refusal from running out of gas. EIP-150 keeps back 1/64 of this frame's gas
     * from the transfer, and for a costly enough token that remainder is enough to finish the call
     * without it, so a caller choosing the gas limit could otherwise starve a payable payment into
     * `Failed`. A failed transfer that leaves less than that remainder is taken as out of gas, and
     * reverts.
     */
    function _settle(uint256 id, address recipient, uint256 amount, uint256 fee) private returns (Status) {
        _record(id, Status.Paid);
        uint256 gasBefore = gasleft();
        if (token.trySafeTransfer(recipient, amount - fee)) {
            fees += fee;
            emit PaymentPaid(id, recipient, amount, fee);
            return Status.Paid;
        }
        if (gasleft() < gasBefore / 64) revert TransferOutOfGas(id);
        _record(id, Status.Failed);
        emit PaymentFailed(id, recipient, amount, fee);
        return Status.Failed;
    }

    /**
     * @dev Set `id`'s status, and the block it was set in, for {blockOf}.
     */
    function _record(uint256 id, Status status) private {
        _records[id] = Record({status: status, blockNumber: uint64(block.number)});
    }
}
