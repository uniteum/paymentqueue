// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";

/**
 * @notice An {IAddressLookup} fixed at construction, standing in for a chain-local token lookup.
 * `address(0)` says the token has not reached this chain.
 */
contract TestLookup is IAddressLookup {
    address private immutable _value;

    constructor(address value_) {
        _value = value_;
    }

    function value() external view returns (address) {
        return _value;
    }
}
