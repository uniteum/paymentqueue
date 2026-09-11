// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC20} from "ierc20/IERC20.sol";
import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";
import {PaymentQueue} from "../src/PaymentQueue.sol";
import {PaymentQueueUser} from "./PaymentQueueUser.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @notice Accounts and helpers shared by the queue's tests. Amounts are in USDC's base units.
 */
abstract contract BaseTest is Test {
    uint256 internal constant USDC = 1e6;

    /**
     * @notice The Bitsy prototype every queue under test is a clone of.
     */
    PaymentQueue internal proto;

    /**
     * @notice Makes, and so owns, the queues under test.
     */
    PaymentQueueUser internal owner;

    /**
     * @notice Anyone at all: sweeps the queue, and is refused where only the owner may act.
     */
    PaymentQueueUser internal stranger;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        proto = new PaymentQueue();
        owner = new PaymentQueueUser("owner");
        stranger = new PaymentQueueUser("stranger");
    }

    /**
     * @notice The owner's queue for `token_`.
     */
    function deploy(IERC20 token_) internal returns (IPaymentQueue queue) {
        queue = owner.make(proto, token_, 0);
    }

    function assertStatus(IPaymentQueue queue, uint256 id, IPaymentQueue.Status want, string memory why) internal view {
        assertEq(uint8(queue.statusOf(id)), uint8(want), why);
    }

    function assertStatus(IPaymentQueue.Status got, IPaymentQueue.Status want, string memory why) internal pure {
        assertEq(uint8(got), uint8(want), why);
    }
}
