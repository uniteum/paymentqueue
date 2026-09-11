// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseTest} from "./Base.t.sol";
import {BlacklistToken} from "./Tokens.sol";
import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";
import {PaymentQueueHandler} from "./PaymentQueueHandler.sol";

/**
 * @notice What holds for {PaymentQueue} after any sequence of payments, repeats, funding, sweeps,
 * withdrawals and refused transfers.
 */
contract PaymentQueueInvariantTest is BaseTest {
    BlacklistToken internal token;
    IPaymentQueue internal queue;
    PaymentQueueHandler internal handler;

    function setUp() public override {
        super.setUp();
        token = new BlacklistToken();
        queue = deploy(token);
        handler = new PaymentQueueHandler(queue, token, owner, stranger);
        targetContract(address(handler));
    }

    /**
     * @notice Each run submitted payments. A handler whose calls all revert would satisfy every
     * invariant below without testing anything.
     */
    function afterInvariant() public view {
        assertGt(handler.submittedCount(), 0, "no payment was submitted");
    }

    /**
     * @notice A paid id's recipient holds exactly the first amount submitted for it; any other id's
     * recipient holds nothing.
     */
    function invariant_EachIdPaidAtMostOnce() public view {
        for (uint256 i = 0; i < handler.submittedCount(); i++) {
            uint256 id = handler.submitted(i);
            uint256 held = token.balanceOf(handler.recipientOf(id));
            if (queue.statusOf(id) == IPaymentQueue.Status.Paid) {
                assertEq(held, handler.amountOf(id), "paid id: first amount, once");
            } else {
                assertEq(held, 0, "unpaid id: nothing");
            }
        }
    }

    /**
     * @notice A repeat submission's recipient is never paid.
     */
    function invariant_RepeatsPayNothing() public view {
        for (uint256 seed = 0; seed < handler.DECOYS(); seed++) {
            assertEq(token.balanceOf(handler.decoyOf(seed)), 0, "decoy paid");
        }
    }

    /**
     * @notice Every token funded is in the float, with a paid recipient, or withdrawn.
     */
    function invariant_TokensConserved() public view {
        uint256 paid;
        for (uint256 i = 0; i < handler.submittedCount(); i++) {
            paid += token.balanceOf(handler.recipientOf(handler.submitted(i)));
        }
        uint256 held = token.balanceOf(address(queue));
        assertEq(handler.funded(), held + paid + token.balanceOf(handler.sink()), "tokens unaccounted for");
    }

    /**
     * @notice The count of waiting payments matches the ids whose status is `Queued`, and every
     * submitted id has a status.
     */
    function invariant_QueuedMatchesStatuses() public view {
        uint256 waiting;
        for (uint256 i = 0; i < handler.submittedCount(); i++) {
            IPaymentQueue.Status status = queue.statusOf(handler.submitted(i));
            assertTrue(status != IPaymentQueue.Status.Unknown, "submitted id has no status");
            if (status == IPaymentQueue.Status.Queued) waiting++;
        }
        assertEq(queue.queued(), waiting, "queued() disagrees with statuses");
    }

    /**
     * @notice Ids that were never submitted stay `Unknown`.
     */
    function invariant_UnsubmittedIdsUnknown() public view {
        for (uint256 id = 0; id < handler.IDS(); id++) {
            if (!handler.known(id)) {
                assertTrue(queue.statusOf(id) == IPaymentQueue.Status.Unknown, "unsubmitted id has a status");
            }
        }
    }

    /**
     * @notice Payments settle in the order they were first submitted: once one is waiting, every
     * later one is waiting too.
     */
    function invariant_SettlesInOrder() public view {
        bool waiting;
        for (uint256 i = 0; i < handler.submittedCount(); i++) {
            bool queued = queue.statusOf(handler.submitted(i)) == IPaymentQueue.Status.Queued;
            assertTrue(queued || !waiting, "settled ahead of an earlier waiting payment");
            waiting = waiting || queued;
        }
    }

    /**
     * @notice A sweep only stops short of its limit when the float cannot cover the next payment.
     */
    function invariant_SweepsStopOnlyForFloat() public view {
        assertFalse(handler.stalled(), "a sweep stopped while it could pay");
    }
}
