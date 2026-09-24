// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseTest} from "./Base.t.sol";
import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";
import {IPrototype} from "iproto/IPrototype.sol";
import {TestLookup} from "./Lookups.sol";
import {TestToken} from "./Tokens.sol";

/**
 * @notice How queues are made: one per owner and token, owned by whoever made it. The clone
 * machinery itself belongs to `Prototype` and is not retested here.
 */
contract PaymentQueueMakeTest is BaseTest {
    TestToken internal token;

    function setUp() public override {
        super.setUp();
        token = new TestToken("USDC");
    }

    /**
     * @notice The account that calls {make} owns the queue it gets, for the token it named.
     */
    function test_Make_MakerOwnsTheQueue() public {
        IPaymentQueue queue = stranger.make(proto, address(token), 0);

        assertEq(queue.owner(), address(stranger), "owner is the maker");
        assertEq(address(queue.token()), address(token), "token as named");
    }

    /**
     * @notice {made} gives a queue's address before it exists, and reports when it does.
     */
    function test_Make_PredictsBeforeMaking() public {
        (bool before, address home,) = proto.made(address(owner), address(token), 0);

        IPaymentQueue queue = owner.make(proto, address(token), 0);
        (bool afterwards,,) = proto.made(address(owner), address(token), 0);

        assertFalse(before, "not made yet");
        assertEq(address(queue), home, "made where predicted");
        assertTrue(afterwards, "made now");
    }

    /**
     * @notice Making a queue again returns the same one, with its state intact.
     */
    function test_Make_RepeatReturnsTheSameQueue() public {
        IPaymentQueue first = deploy(token);
        owner.pay(first, 1, alice, 10 * USDC);

        IPaymentQueue again = deploy(token);

        assertEq(address(again), address(first), "same queue");
        assertEq(again.owner(), address(owner), "same owner");
        assertStatus(again, 1, IPaymentQueue.Status.Queued, "its payment still waiting");
    }

    /**
     * @notice Each owner and token has its own queue, and a payment in one is unknown to the others.
     */
    function test_Make_OneQueuePerOwnerAndToken() public {
        TestToken other = new TestToken("EURC");
        IPaymentQueue mine = deploy(token);
        IPaymentQueue mineOther = deploy(other);
        IPaymentQueue theirs = stranger.make(proto, address(token), 0);
        owner.pay(mine, 1, alice, 10 * USDC);

        assertTrue(address(mine) != address(mineOther), "another token, another queue");
        assertTrue(address(mine) != address(theirs), "another owner, another queue");
        assertStatus(mineOther, 1, IPaymentQueue.Status.Unknown, "not in the other token's queue");
        assertStatus(theirs, 1, IPaymentQueue.Status.Unknown, "not in the other owner's queue");
    }

    /**
     * @notice Calling {make} on an existing queue makes the caller's own queue, not one for the queue's
     * owner.
     */
    function test_Make_OnAQueueMakesTheCallersQueue() public {
        IPaymentQueue ownersQueue = deploy(token);

        IPaymentQueue viaQueue = stranger.make(ownersQueue, address(token), 0);

        assertEq(viaQueue.owner(), address(stranger), "the caller owns it");
        assertEq(
            address(viaQueue), address(stranger.make(proto, address(token), 0)), "the same as made on the prototype"
        );
    }

    /**
     * @notice A token given as a lookup is resolved when the queue is made: the queue pays in the token
     * the lookup names, at an address derived from the lookup rather than from that token.
     */
    function test_Make_ResolvesALookup() public {
        TestLookup lookup = new TestLookup(address(token));
        (, address direct,) = proto.made(address(owner), address(token), 0);

        IPaymentQueue queue = owner.make(proto, address(lookup), 0);

        assertEq(address(queue.token()), address(token), "pays in the token the lookup names");
        assertTrue(address(queue) != direct, "keyed by the lookup, not by the token");
    }

    /**
     * @notice A lookup that resolves to `address(0)` says the token has not reached this chain, and no
     * queue is made for it.
     */
    function test_Make_RefusesAnUnmappedLookup() public {
        TestLookup lookup = new TestLookup(address(0));

        vm.expectRevert(abi.encodeWithSelector(IPaymentQueue.UnmappedLookup.selector, address(lookup)));
        owner.make(proto, address(lookup), 0);
    }

    /**
     * @notice An address with no code, an undeployed lookup or a stray account, is refused rather than
     * stored as the token.
     */
    function test_Make_RefusesAnUndeployedToken() public {
        address ghost = makeAddr("ghost");

        vm.expectRevert(abi.encodeWithSelector(IPaymentQueue.UnmappedLookup.selector, ghost));
        owner.make(proto, ghost, 0);
    }

    /**
     * @notice Only the prototype can initialise a queue, so nobody can re-point a live queue's owner or
     * token.
     */
    function test_ZzInit_OnlyTheProto() public {
        IPaymentQueue queue = deploy(token);
        bytes memory args = proto.encode(address(stranger), address(token));

        vm.expectRevert(IPrototype.Unauthorized.selector);
        IPrototype(address(queue)).zzInit(args, 0);

        assertEq(queue.owner(), address(owner), "owner unchanged");
    }

    /**
     * @notice The prototype has no owner, so it cannot be used as a queue.
     */
    function test_Proto_HasNoOwner() public {
        assertEq(proto.owner(), address(0), "no owner");

        vm.expectRevert(IPrototype.Unauthorized.selector);
        owner.pay(proto, 1, alice, 10 * USDC);
    }
}
