// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseTest} from "./Base.t.sol";
import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";
import {TestToken} from "./Tokens.sol";

/**
 * @notice The Hardhat suite of the v1 contract this replaces, one test per case, same fixture: the
 * queue holds 500 of a 1000 supply. v1 separated adding a payment from processing it; v2 pays at
 * once when it can, so each case now asserts after the call that pays. One case comes out the other
 * way, and says so.
 */
contract PaymentQueueUpstreamTest is BaseTest {
    TestToken internal token;
    IPaymentQueue internal queue;

    function setUp() public override {
        super.setUp();
        token = new TestToken("MTK");
        queue = deploy(token);
        token.mint(address(this), 1000 * USDC);
        assertTrue(token.transfer(address(queue), 500 * USDC), "queue funded");
    }

    /**
     * @notice "should add payments idempotently".
     */
    function test_Upstream_AddsPaymentsIdempotently() public {
        owner.pay(queue, 1, alice, 100 * USDC);
        owner.pay(queue, 1, alice, 100 * USDC);

        assertEq(token.balanceOf(alice), 100 * USDC, "paid once");
    }

    /**
     * @notice "should process payments correctly".
     */
    function test_Upstream_ProcessesPaymentsCorrectly() public {
        owner.pay(queue, 1, alice, 100 * USDC);
        owner.pay(queue, 2, bob, 200 * USDC);
        stranger.processPayments(queue, 2);

        assertEq(token.balanceOf(alice), 100 * USDC, "alice paid");
        assertEq(token.balanceOf(bob), 200 * USDC, "bob paid");
        assertStatus(queue, 1, IPaymentQueue.Status.Paid, "1 paid");
        assertStatus(queue, 2, IPaymentQueue.Status.Paid, "2 paid");
    }

    /**
     * @notice "should skip payments with insufficient funds". **Reversed in v2.** v1 dropped the
     * unaffordable payment and paid the one behind it. v2 keeps the line: both wait until the float
     * covers the first, so neither is lost and neither is paid out of order.
     */
    function test_Upstream_HoldsTheLineWithInsufficientFunds() public {
        owner.pay(queue, 1, alice, 600 * USDC);
        owner.pay(queue, 2, bob, 100 * USDC);
        stranger.processPayments(queue, 2);

        assertEq(token.balanceOf(alice), 0, "alice waits for float");
        assertEq(token.balanceOf(bob), 0, "bob waits behind alice, not skipped ahead");
        assertStatus(queue, 1, IPaymentQueue.Status.Queued, "1 kept, not dropped");
        assertStatus(queue, 2, IPaymentQueue.Status.Queued, "2 kept");
    }

    /**
     * @notice "should handle duplicate payment IDs gracefully".
     */
    function test_Upstream_HandlesDuplicateIdsGracefully() public {
        owner.pay(queue, 1, alice, 100 * USDC);
        owner.pay(queue, 1, bob, 200 * USDC);
        stranger.processPayments(queue, 2);

        assertEq(token.balanceOf(alice), 100 * USDC, "first call paid");
        assertEq(token.balanceOf(bob), 0, "duplicate ignored");
        assertStatus(queue, 1, IPaymentQueue.Status.Paid, "1 paid");
    }
}
