// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IPaymentQueue} from "ipaymentqueue/IPaymentQueue.sol";
import {IReceiver} from "./Tokens.sol";

/**
 * @notice A recipient that tries to sweep the queue again from inside its own payment, and swallows
 * the failure so its own transfer still goes through.
 */
contract ReentrantRecipient is IReceiver {
    IPaymentQueue public immutable queue;

    constructor(IPaymentQueue queue_) {
        queue = queue_;
    }

    function received(address, uint256) external {
        try queue.processPayments(10) {} catch {}
    }
}
