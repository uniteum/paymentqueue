// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";
import {Test, console} from "forge-std/Test.sol";

/**
 * @notice An account that calls the queue: its owner, a sweeper, a stranger. Each is a real contract
 * with its own address, standing in for an EOA, so no test needs `vm.prank`.
 */
contract PaymentQueueUser is Test {
    string public name;

    constructor(string memory name_) {
        name = name_;
    }

    /**
     * @notice Make this account's queue for `token`, a token or a lookup, checking that
     * {IPaymentQueue.made} predicted the address {IPaymentQueue.make} returned.
     */
    function make(IPaymentQueue factory, address token, uint256 variant) public returns (IPaymentQueue queue) {
        (, address predicted,) = factory.made(address(this), token, variant);
        queue = factory.make(token, variant);
        assertEq(address(queue), predicted, "make != made");
        console.log("%s make queue %s", name, address(queue));
    }

    /**
     * @notice Pay with no fee, which is how most tests pay: the queue's behaviour is the same as it was
     * before fees existed.
     */
    function pay(IPaymentQueue queue, uint256 id, address recipient, uint256 amount)
        public
        returns (IPaymentQueue.Status status)
    {
        status = pay(queue, id, recipient, amount, 0);
    }

    function pay(IPaymentQueue queue, uint256 id, address recipient, uint256 amount, uint256 feeBasisPoints)
        public
        returns (IPaymentQueue.Status status)
    {
        console.log("%s pay %s to %s, fee in basis points:", name, amount, recipient);
        console.log("  %s", feeBasisPoints);
        status = queue.pay(id, recipient, amount, feeBasisPoints);
    }

    function processPayments(IPaymentQueue queue, uint256 limit) public returns (uint256 settled) {
        settled = queue.processPayments(limit);
        console.log("%s processPayments settled %s", name, settled);
    }

    /**
     * @notice Sweep with a fixed gas allowance, reporting whether the call completed rather than
     * reverting with it.
     */
    function processPaymentsWithGas(IPaymentQueue queue, uint256 limit, uint256 gas) public returns (bool ok) {
        (ok,) = address(queue).call{gas: gas}(abi.encodeCall(IPaymentQueue.processPayments, (limit)));
        console.log("%s processPayments with %s gas: %s", name, gas, ok);
    }

    function withdrawFunds(IPaymentQueue queue, address to, uint256 amount) public {
        console.log("%s withdrawFunds %s to %s", name, amount, to);
        queue.withdrawFunds(to, amount);
    }

    function withdrawFees(IPaymentQueue queue, address to, uint256 amount) public {
        console.log("%s withdrawFees %s to %s", name, amount, to);
        queue.withdrawFees(to, amount);
    }

    /**
     * @notice Send native currency to `to`, reporting whether it was accepted.
     */
    function sendValue(address to, uint256 value) public returns (bool ok) {
        (ok,) = to.call{value: value}("");
        console.log("%s send %s wei: %s", name, value, ok);
    }
}
