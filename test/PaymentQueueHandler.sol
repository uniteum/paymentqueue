// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BlacklistToken} from "./Tokens.sol";
import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";
import {PaymentQueueUser} from "./PaymentQueueUser.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @notice Drives a queue through random sequences of payments, funding, sweeps and withdrawals,
 * keeping its own record of what should have happened for the invariants to check against.
 * @dev Each id has its own recipient, so a recipient's balance says whether and how often its id was
 * paid. Repeat submissions name decoy recipients that must never receive anything. Every fifth
 * id's recipient is blacklisted, so refusals are part of every run.
 */
contract PaymentQueueHandler is Test {
    uint256 internal constant USDC = 1e6;
    uint256 public constant IDS = 16;
    uint256 public constant DECOYS = 4;

    IPaymentQueue public immutable queue;
    BlacklistToken public immutable token;
    PaymentQueueUser public immutable owner;
    PaymentQueueUser public immutable sweeper;
    address public immutable sink = makeAddr("sink");

    address[IDS] internal recipients;
    address[DECOYS] internal decoys;

    /**
     * @notice Ids in the order of their first submission.
     */
    uint256[] public submitted;
    mapping(uint256 id => bool) public known;
    mapping(uint256 id => uint256) public amountOf;
    uint256 public funded;

    /**
     * @notice Set if a sweep ever stopped short of its limit while the float covered the next payment.
     */
    bool public stalled;

    constructor(IPaymentQueue queue_, BlacklistToken token_, PaymentQueueUser owner_, PaymentQueueUser sweeper_) {
        queue = queue_;
        token = token_;
        owner = owner_;
        sweeper = sweeper_;
        for (uint256 id = 0; id < IDS; id++) {
            recipients[id] = makeAddr(string.concat("recipient", vm.toString(id)));
            if (id % 5 == 4) token.blacklist(recipients[id]);
        }
        for (uint256 seed = 0; seed < DECOYS; seed++) {
            decoys[seed] = makeAddr(string.concat("decoy", vm.toString(seed)));
        }
    }

    function pay(uint256 idSeed, uint256 amount, uint256 decoySeed) external {
        uint256 id = idSeed % IDS;
        amount = bound(amount, 1, 30 * USDC);
        if (known[id]) {
            owner.pay(queue, id, decoyOf(decoySeed), amount);
            return;
        }
        known[id] = true;
        amountOf[id] = amount;
        submitted.push(id);
        owner.pay(queue, id, recipientOf(id), amount);
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 0, 40 * USDC);
        token.mint(address(queue), amount);
        funded += amount;
    }

    function sweep(uint256 limit) external {
        limit = bound(limit, 0, 5);
        uint256 settled = sweeper.processPayments(queue, limit);
        if (settled < limit && queue.queued() > 0 && amountOf[firstQueued()] <= token.balanceOf(address(queue))) {
            stalled = true;
        }
    }

    function withdraw(uint256 amount) external {
        amount = bound(amount, 0, token.balanceOf(address(queue)));
        owner.withdraw(queue, sink, amount);
    }

    function submittedCount() external view returns (uint256) {
        return submitted.length;
    }

    /**
     * @notice The id waiting at the head of the line, by this handler's record.
     */
    function firstQueued() public view returns (uint256) {
        for (uint256 i = 0; i < submitted.length; i++) {
            if (queue.statusOf(submitted[i]) == IPaymentQueue.Status.Queued) return submitted[i];
        }
        revert("nothing queued");
    }

    function recipientOf(uint256 id) public view returns (address) {
        return recipients[id];
    }

    function decoyOf(uint256 seed) public view returns (address) {
        return decoys[seed % DECOYS];
    }
}
