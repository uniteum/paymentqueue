// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseTest} from "./Base.t.sol";
import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";
import {IPrototype} from "iproto/IPrototype.sol";
import {BlacklistToken, CostlyToken, FalseToken, HookToken, TestToken} from "./Tokens.sol";
import {ReentrantRecipient} from "./Recipients.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Behaviour of a {PaymentQueue} queue against a well-behaved token. Where v1 of the contract
 * got a behaviour wrong, the test's natspec says what v1 did.
 */
contract PaymentQueueTest is BaseTest {
    TestToken internal token;
    IPaymentQueue internal queue;

    function setUp() public override {
        super.setUp();
        token = new TestToken("USDC");
        queue = deploy(token);
    }

    /**
     * @notice With nothing waiting and float to cover it, {pay} transfers at once.
     */
    function test_Pay_FundedPaysAtOnce() public {
        token.mint(address(queue), 100 * USDC);

        vm.expectEmit(address(queue));
        emit IPaymentQueue.PaymentPaid(1, alice, 10 * USDC);
        IPaymentQueue.Status status = owner.pay(queue, 1, alice, 10 * USDC);

        assertStatus(status, IPaymentQueue.Status.Paid, "returned status");
        assertStatus(queue, 1, IPaymentQueue.Status.Paid, "recorded status");
        assertEq(token.balanceOf(alice), 10 * USDC, "alice paid");
        assertEq(token.balanceOf(address(queue)), 90 * USDC, "float spent");
        assertEq(queue.queued(), 0, "nothing waiting");
    }

    /**
     * @notice Without float, {pay} keeps the payment waiting. v1 dropped it.
     */
    function test_Pay_UnfundedQueues() public {
        vm.expectEmit(address(queue));
        emit IPaymentQueue.PaymentQueued(1, alice, 10 * USDC);
        IPaymentQueue.Status status = owner.pay(queue, 1, alice, 10 * USDC);

        assertStatus(status, IPaymentQueue.Status.Queued, "returned status");
        assertStatus(queue, 1, IPaymentQueue.Status.Queued, "recorded status");
        assertEq(queue.queued(), 1, "one waiting");
        assertEq(token.balanceOf(alice), 0, "alice unpaid");
    }

    /**
     * @notice A new payment the float could cover still waits behind one it cannot.
     */
    function test_Pay_DoesNotJumpTheLine() public {
        token.mint(address(queue), 20 * USDC);
        owner.pay(queue, 1, alice, 30 * USDC);

        IPaymentQueue.Status status = owner.pay(queue, 2, bob, 5 * USDC);

        assertStatus(status, IPaymentQueue.Status.Queued, "bob waits behind alice");
        assertEq(token.balanceOf(bob), 0, "bob unpaid");
        assertEq(queue.queued(), 2, "both waiting");
    }

    /**
     * @notice Repeating {pay} for a waiting id adds no second entry. v1 queued a duplicate.
     */
    function test_Pay_RepeatWhileQueuedIsNoOp() public {
        owner.pay(queue, 1, alice, 10 * USDC);

        vm.recordLogs();
        IPaymentQueue.Status status = owner.pay(queue, 1, alice, 10 * USDC);

        assertStatus(status, IPaymentQueue.Status.Queued, "still waiting");
        assertEq(queue.queued(), 1, "no second entry");
        assertEq(queueEvents(vm.getRecordedLogs()), 0, "no event for the repeat");
    }

    /**
     * @notice Repeating {pay} for a paid id pays nothing more, whatever float is left.
     */
    function test_Pay_RepeatAfterPaidIsNoOp() public {
        token.mint(address(queue), 100 * USDC);
        owner.pay(queue, 1, alice, 10 * USDC);

        vm.recordLogs();
        IPaymentQueue.Status status = owner.pay(queue, 1, alice, 10 * USDC);

        assertStatus(status, IPaymentQueue.Status.Paid, "still paid");
        assertEq(token.balanceOf(alice), 10 * USDC, "alice paid once");
        assertEq(queueEvents(vm.getRecordedLogs()), 0, "no event for the repeat");
    }

    /**
     * @notice The first {pay} for an id fixes its recipient and amount; a later one naming others is
     * ignored. v1 queued the second as a separate entry.
     */
    function test_Pay_FirstCallFixesRecipientAndAmount() public {
        owner.pay(queue, 1, alice, 10 * USDC);
        owner.pay(queue, 1, bob, 7 * USDC);
        token.mint(address(queue), 100 * USDC);

        stranger.processPayments(queue, 10);

        assertEq(token.balanceOf(alice), 10 * USDC, "alice paid the first amount");
        assertEq(token.balanceOf(bob), 0, "bob paid nothing");
    }

    /**
     * @notice However many times one id is submitted, with whatever amounts and recipients, and
     * whatever funding and sweeps in between, it is paid at most once: the first amount, to the first
     * recipient.
     */
    function testFuzz_Pay_OneIdPaysAtMostOnce(uint256 id, uint64[6] memory amounts, uint64[6] memory funding) public {
        uint256 first = bound(amounts[0], 1, 100 * USDC);
        for (uint256 i = 0; i < 6; i++) {
            token.mint(address(queue), bound(funding[i], 0, 50 * USDC));
            if (i == 0) owner.pay(queue, id, alice, first);
            else owner.pay(queue, id, bob, bound(amounts[i], 1, 100 * USDC));
            stranger.processPayments(queue, 10);
        }

        assertEq(token.balanceOf(bob), 0, "later calls paid nothing");
        assertLe(queue.queued(), 1, "never more than one entry");
        if (queue.statusOf(id) == IPaymentQueue.Status.Paid) {
            assertEq(token.balanceOf(alice), first, "the first amount, once");
        } else {
            assertStatus(queue, id, IPaymentQueue.Status.Queued, "otherwise still waiting");
            assertEq(token.balanceOf(alice), 0, "and unpaid");
        }
    }

    /**
     * @notice Only the owner can submit payments.
     */
    function test_Pay_OwnerOnly() public {
        token.mint(address(queue), 100 * USDC);

        vm.expectRevert(IPrototype.Unauthorized.selector);
        stranger.pay(queue, 1, alice, 10 * USDC);
    }

    /**
     * @notice An id is keyed on all 256 bits, so a caller can use a hash, such as a sha256 digest
     * read as a `uint256`, as the id.
     */
    function test_Pay_IdIsFullWidth() public {
        token.mint(address(queue), 100 * USDC);
        uint256 id = uint256(sha256("payment 1"));

        owner.pay(queue, id, alice, 10 * USDC);

        assertStatus(queue, id, IPaymentQueue.Status.Paid, "paid under the full-width id");
        assertStatus(queue, id & type(uint128).max, IPaymentQueue.Status.Unknown, "its low half is a different id");
    }

    /**
     * @notice Funding the queue and sweeping pays a waiting payment. v1 had already dropped it.
     */
    function test_Process_PaysOnceFunded() public {
        owner.pay(queue, 1, alice, 10 * USDC);
        token.mint(address(queue), 10 * USDC);

        vm.expectEmit(address(queue));
        emit IPaymentQueue.PaymentPaid(1, alice, 10 * USDC);
        uint256 settled = stranger.processPayments(queue, 10);

        assertEq(settled, 1, "settled count");
        assertStatus(queue, 1, IPaymentQueue.Status.Paid, "recorded status");
        assertEq(token.balanceOf(alice), 10 * USDC, "alice paid");
        assertEq(queue.queued(), 0, "nothing waiting");
    }

    /**
     * @notice A sweep stops at the first payment the float cannot cover and leaves it, and everything
     * behind it, waiting. Settling nothing, it returns 0, which is what a simulated sweep reports.
     */
    function test_Process_StopsAtUncoveredHead() public {
        owner.pay(queue, 1, alice, 30 * USDC);
        owner.pay(queue, 2, bob, 5 * USDC);
        token.mint(address(queue), 20 * USDC);

        uint256 settled = stranger.processPayments(queue, 10);

        assertEq(settled, 0, "nothing settled");
        assertEq(queue.queued(), 2, "both still waiting");
        assertEq(token.balanceOf(bob), 0, "bob not paid ahead of alice");
        assertStatus(queue, 1, IPaymentQueue.Status.Queued, "alice waiting");
        assertStatus(queue, 2, IPaymentQueue.Status.Queued, "bob waiting");
    }

    /**
     * @notice Once the float covers the head, the line pays out in the order it was joined.
     */
    function test_Process_PaysInOrder() public {
        owner.pay(queue, 1, alice, 30 * USDC);
        owner.pay(queue, 2, bob, 5 * USDC);
        token.mint(address(queue), 20 * USDC);
        stranger.processPayments(queue, 10);
        token.mint(address(queue), 15 * USDC);

        vm.expectEmit(address(queue));
        emit IPaymentQueue.PaymentPaid(1, alice, 30 * USDC);
        vm.expectEmit(address(queue));
        emit IPaymentQueue.PaymentPaid(2, bob, 5 * USDC);
        uint256 settled = stranger.processPayments(queue, 10);

        assertEq(settled, 2, "both settled");
        assertEq(token.balanceOf(alice), 30 * USDC, "alice paid");
        assertEq(token.balanceOf(bob), 5 * USDC, "bob paid");
        assertEq(token.balanceOf(address(queue)), 0, "float spent exactly");
    }

    /**
     * @notice A sweep settles no more than `limit`, so its gas is bounded by the caller.
     */
    function test_Process_RespectsLimit() public {
        owner.pay(queue, 1, alice, 1 * USDC);
        owner.pay(queue, 2, bob, 1 * USDC);
        owner.pay(queue, 3, carol, 1 * USDC);
        token.mint(address(queue), 3 * USDC);

        assertEq(stranger.processPayments(queue, 2), 2, "first sweep settles two");
        assertEq(queue.queued(), 1, "one left");
        assertEq(token.balanceOf(carol), 0, "carol not yet paid");

        assertEq(stranger.processPayments(queue, 2), 1, "second sweep settles the last");
        assertEq(token.balanceOf(carol), 1 * USDC, "carol paid");
    }

    /**
     * @notice A sweep of an empty line does nothing and reports it.
     */
    function test_Process_EmptyReturnsZero() public {
        token.mint(address(queue), 100 * USDC);

        assertEq(stranger.processPayments(queue, 10), 0, "nothing to settle");
    }

    /**
     * @notice After the line drains, the next funded payment is paid at once again: settled entries
     * leave nothing behind for {pay} to wait on or a sweep to rescan. v1 rescanned them on every
     * sweep.
     */
    function test_Process_DrainedLinePaysAtOnceAgain() public {
        owner.pay(queue, 1, alice, 10 * USDC);
        token.mint(address(queue), 100 * USDC);
        stranger.processPayments(queue, 10);

        IPaymentQueue.Status status = owner.pay(queue, 2, bob, 10 * USDC);

        assertStatus(status, IPaymentQueue.Status.Paid, "paid without waiting");
        assertEq(token.balanceOf(bob), 10 * USDC, "bob paid");
        assertEq(stranger.processPayments(queue, 10), 0, "nothing left to rescan");
    }

    /**
     * @notice A transfer the token refuses, as USDC refuses a blacklisted recipient, is marked
     * `Failed` and the sweep carries on to the payment behind it, which the refused amount, still in
     * the float, pays for. In v1 the refusal reverted every sweep from then on.
     */
    function test_Refused_SweepMarksFailedAndCarriesOn() public {
        BlacklistToken blk = new BlacklistToken();
        IPaymentQueue q = deploy(blk);
        blk.blacklist(carol);
        owner.pay(q, 1, carol, 10 * USDC);
        owner.pay(q, 2, alice, 10 * USDC);
        blk.mint(address(q), 10 * USDC);

        vm.expectEmit(address(q));
        emit IPaymentQueue.PaymentFailed(1, carol, 10 * USDC);
        vm.expectEmit(address(q));
        emit IPaymentQueue.PaymentPaid(2, alice, 10 * USDC);
        uint256 settled = stranger.processPayments(q, 10);

        assertEq(settled, 2, "both left the line");
        assertStatus(q, 1, IPaymentQueue.Status.Failed, "carol failed");
        assertStatus(q, 2, IPaymentQueue.Status.Paid, "alice paid");
        assertEq(blk.balanceOf(alice), 10 * USDC, "alice received");
        assertEq(blk.balanceOf(address(q)), 0, "carol's refused amount paid alice");
    }

    /**
     * @notice A refusal on the immediate path is marked `Failed` too, and {pay} does not revert.
     */
    function test_Refused_PayMarksFailed() public {
        BlacklistToken blk = new BlacklistToken();
        IPaymentQueue q = deploy(blk);
        blk.blacklist(carol);
        blk.mint(address(q), 20 * USDC);

        vm.expectEmit(address(q));
        emit IPaymentQueue.PaymentFailed(1, carol, 10 * USDC);
        IPaymentQueue.Status status = owner.pay(q, 1, carol, 10 * USDC);

        assertStatus(status, IPaymentQueue.Status.Failed, "returned status");
        assertStatus(q, 1, IPaymentQueue.Status.Failed, "recorded status");
        assertEq(blk.balanceOf(address(q)), 20 * USDC, "float untouched");
        assertEq(q.queued(), 0, "not left waiting");
    }

    /**
     * @notice A failed id is spent: submitting it again, even to a recipient the token accepts, pays
     * nothing.
     */
    function test_Refused_FailedIdIsSpent() public {
        BlacklistToken blk = new BlacklistToken();
        IPaymentQueue q = deploy(blk);
        blk.blacklist(carol);
        blk.mint(address(q), 20 * USDC);
        owner.pay(q, 1, carol, 10 * USDC);

        IPaymentQueue.Status status = owner.pay(q, 1, alice, 10 * USDC);

        assertStatus(status, IPaymentQueue.Status.Failed, "still failed");
        assertEq(blk.balanceOf(alice), 0, "alice paid nothing");
    }

    /**
     * @notice A token that reports failure by returning false is `Failed`, not `Paid`. v1 recorded
     * such a payment as made.
     */
    function test_Refused_FalseReturnIsNotPaid() public {
        FalseToken fls = new FalseToken();
        IPaymentQueue q = deploy(fls);
        fls.mint(address(q), 20 * USDC);

        IPaymentQueue.Status status = owner.pay(q, 1, alice, 10 * USDC);

        assertStatus(status, IPaymentQueue.Status.Failed, "returned status");
        assertStatus(q, 1, IPaymentQueue.Status.Failed, "recorded status");
    }

    /**
     * @notice A sweep sent with too little gas for the transfer fails as a whole and leaves the
     * payment waiting; it never records the starved transfer as the token refusing it. Scanned across
     * gas limits with a token whose transfer costs 150k gas, above the ~140k at which the 1/64 of gas
     * a call keeps back (EIP-150) is enough for the sweep to finish without the transfer.
     */
    function test_Process_StarvedSweepNeverRecordsARefusal() public {
        CostlyToken costly = new CostlyToken(150_000);
        IPaymentQueue q = deploy(costly);
        owner.pay(q, 1, alice, 10 * USDC);
        costly.mint(address(q), 10 * USDC);
        uint256 before = vm.snapshotState();

        uint256 completed;
        for (uint256 gas = 100_000; gas <= 300_000; gas += 1_000) {
            bool ok = stranger.processPaymentsWithGas(q, 1, gas);
            IPaymentQueue.Status want = ok ? IPaymentQueue.Status.Paid : IPaymentQueue.Status.Queued;
            assertStatus(q, 1, want, string.concat("status after a sweep with gas ", vm.toString(gas)));
            if (ok) completed++;
            vm.revertToState(before);
        }
        assertGt(completed, 0, "some sweeps had enough gas to pay");
    }

    /**
     * @notice The owner can recover float. v1 had no way to.
     */
    function test_Withdraw_OwnerRecoversFloat() public {
        token.mint(address(queue), 100 * USDC);

        owner.withdraw(queue, bob, 40 * USDC);

        assertEq(token.balanceOf(bob), 40 * USDC, "bob received");
        assertEq(token.balanceOf(address(queue)), 60 * USDC, "float reduced");
    }

    /**
     * @notice Only the owner can withdraw float.
     */
    function test_Withdraw_OwnerOnly() public {
        token.mint(address(queue), 100 * USDC);

        vm.expectRevert(IPrototype.Unauthorized.selector);
        stranger.withdraw(queue, address(stranger), 40 * USDC);
    }

    /**
     * @notice Native currency sent to the queue is refused rather than stranded. v1 accepted it and
     * could never send it back out.
     */
    function test_Native_Refused() public {
        vm.deal(address(stranger), 1 ether);

        bool ok = stranger.sendValue(address(queue), 1 ether);

        assertFalse(ok, "ether refused");
        assertEq(address(queue).balance, 0, "nothing stranded");
    }

    /**
     * @notice A recipient that re-enters the sweep from inside its own transfer cannot make the
     * sweep act twice: exactly its payment and the one behind it are made, in order, once each.
     * Without the guard, the outer sweep resumed at a slot the inner sweep had already settled and
     * recorded a phantom id 0 as `Failed`.
     */
    function test_Reentrancy_SweepActsOnce() public {
        HookToken hook = new HookToken();
        IPaymentQueue q = deploy(hook);
        ReentrantRecipient mallory = new ReentrantRecipient(q);
        hook.hook(address(mallory));
        owner.pay(q, 1, address(mallory), 10 * USDC);
        owner.pay(q, 2, alice, 10 * USDC);
        hook.mint(address(q), 30 * USDC);

        vm.recordLogs();
        uint256 settled = stranger.processPayments(q, 10);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(settled, 2, "settled count");
        assertEq(hook.balanceOf(address(mallory)), 10 * USDC, "mallory paid once");
        assertEq(hook.balanceOf(alice), 10 * USDC, "alice paid once");
        assertEq(hook.balanceOf(address(q)), 10 * USDC, "the rest of the float kept");
        assertStatus(q, 0, IPaymentQueue.Status.Unknown, "no phantom id 0");
        assertPaidInOrder(logs, address(q), 1, 2);
    }

    /**
     * @notice The queue emitted exactly two payment events, `PaymentPaid` for `first` then `second`.
     */
    function assertPaidInOrder(Vm.Log[] memory logs, address emitter, uint256 first, uint256 second) internal pure {
        uint256[2] memory want = [first, second];
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != emitter) continue;
            assertLt(seen, 2, "no more than two payment events");
            assertEq(logs[i].topics[0], IPaymentQueue.PaymentPaid.selector, "a PaymentPaid event");
            assertEq(uint256(logs[i].topics[1]), want[seen], "in order");
            seen++;
        }
        assertEq(seen, 2, "two payment events");
    }

    /**
     * @notice Count the queue's own payment events among `logs`.
     */
    function queueEvents(Vm.Log[] memory logs) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 topic = logs[i].topics[0];
            if (
                logs[i].emitter == address(queue)
                    && (topic == IPaymentQueue.PaymentQueued.selector
                        || topic == IPaymentQueue.PaymentPaid.selector
                        || topic == IPaymentQueue.PaymentFailed.selector)
            ) {
                count++;
            }
        }
    }
}
