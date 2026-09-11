// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

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
 * response or a retry, never pays twice.
 * @dev A Bitsy prototype (https://uniteum.one/bitsy/): the deployed contract is an inert factory with
 * no owner, and each queue is an EIP-1167 clone of it at a CREATE2 address derived from its owner and
 * token, so {made} can name a queue before it exists. A queue's owner and token are set once, by
 * {zzInit}, and never change.
 *
 * The line is a mapping walked by a head and a tail index. A settled entry is deleted as the head
 * passes it, so nothing is rescanned. Status is written before each transfer, and both entry points
 * are `nonReentrant`: a token with transfer hooks would otherwise let a recipient re-enter a sweep
 * partway through its own payment.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract PaymentQueue is IPaymentQueue, ReentrancyGuardTransient, Prototype {
    using SafeERC20 for IERC20;

    struct Entry {
        uint256 id;
        address recipient;
        uint256 amount;
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
    mapping(uint256 id => Status) public statusOf;

    mapping(uint256 index => Entry) private _queue;
    uint256 private _head;
    uint256 private _tail;

    /**
     * @inheritdoc IPaymentQueue
     */
    function queued() external view returns (uint256) {
        return _tail - _head;
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function pay(uint256 id, address recipient, uint256 amount) external nonReentrant returns (Status status) {
        if (msg.sender != owner) revert Unauthorized();
        status = statusOf[id];
        if (status != Status.Unknown) return status;
        if (_head == _tail && amount <= token.balanceOf(address(this))) {
            status = _settle(id, recipient, amount);
        } else {
            status = Status.Queued;
            statusOf[id] = status;
            _queue[_tail++] = Entry({id: id, recipient: recipient, amount: amount});
            emit PaymentQueued(id, recipient, amount);
        }
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function processPayments(uint256 limit) external nonReentrant returns (uint256 settled) {
        uint256 balance = token.balanceOf(address(this));
        uint256 head = _head;
        uint256 tail = _tail;
        while (settled < limit && head < tail) {
            Entry memory entry = _queue[head];
            if (entry.amount > balance) break;
            delete _queue[head];
            _head = ++head;
            ++settled;
            if (_settle(entry.id, entry.recipient, entry.amount) == Status.Paid) balance -= entry.amount;
        }
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function withdraw(address to, uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        token.safeTransfer(to, amount);
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function made(address owner_, IERC20 token_, uint256 variant)
        external
        view
        returns (bool exists, address home, bytes32 salt)
    {
        (exists, home, salt) = this.made(encode(owner_, token_), variant);
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function make(IERC20 token_, uint256 variant) external returns (IPaymentQueue queue) {
        (, address home,) = this.make(encode(msg.sender, token_), variant);
        queue = IPaymentQueue(home);
    }

    /**
     * @inheritdoc IPrototype
     * @dev Decodes `(owner, token)` into the new queue's storage.
     */
    function zzInit(bytes calldata args, uint256) external override onlyProto {
        (owner, token) = abi.decode(args, (address, IERC20));
    }

    /**
     * @inheritdoc IPaymentQueue
     */
    function encode(address owner_, IERC20 token_) public pure returns (bytes memory args) {
        args = abi.encode(owner_, token_);
    }

    /**
     * @dev Transfer, and record whether it happened. `trySafeTransfer` turns a refusal, by revert or
     * by a false return, into `Failed` instead of a revert, so one refused recipient cannot block the
     * line.
     *
     * It cannot tell a refusal from running out of gas. EIP-150 keeps back 1/64 of this frame's gas
     * from the transfer, and for a costly enough token that remainder is enough to finish the call
     * without it, so a caller choosing the gas limit could otherwise starve a payable payment into
     * `Failed`. A failed transfer that leaves less than that remainder is taken as out of gas, and
     * reverts.
     */
    function _settle(uint256 id, address recipient, uint256 amount) private returns (Status) {
        statusOf[id] = Status.Paid;
        uint256 gasBefore = gasleft();
        if (token.trySafeTransfer(recipient, amount)) {
            emit PaymentPaid(id, recipient, amount);
            return Status.Paid;
        }
        if (gasleft() < gasBefore / 64) revert TransferOutOfGas(id);
        statusOf[id] = Status.Failed;
        emit PaymentFailed(id, recipient, amount);
        return Status.Failed;
    }
}
