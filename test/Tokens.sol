// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20} from "erc20/ERC20.sol";

/**
 * @notice A six-decimal token anyone can mint, standing in for USDC.
 */
contract TestToken is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/**
 * @notice Refuses transfers to blacklisted accounts with USDC's own revert reason.
 */
contract BlacklistToken is TestToken {
    mapping(address account => bool) public blacklisted;

    constructor() TestToken("BLK") {}

    function blacklist(address account) external {
        blacklisted[account] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
    }
}

/**
 * @notice Reports failure by returning false without moving anything, as pre-2020 tokens did.
 */
contract FalseToken is TestToken {
    constructor() TestToken("FALSE") {}

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/**
 * @notice Calls a registered recipient back after it receives tokens, as ERC-777 and ERC-1363
 * tokens can.
 */
contract HookToken is TestToken {
    mapping(address account => bool) public hooked;

    constructor() TestToken("HOOK") {}

    function hook(address account) external {
        hooked[account] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hooked[to]) IReceiver(to).received(from, value);
    }
}

/**
 * @notice Spends `cost` gas on every transfer before moving anything, and runs out of gas like any
 * other contract when given less.
 */
contract CostlyToken is TestToken {
    uint256 public immutable cost;

    constructor(uint256 cost_) TestToken("COST") {
        cost = cost_;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 start = gasleft();
        uint256 until = start > cost ? start - cost : 0;
        while (gasleft() > until) {}
        super._update(from, to, value);
    }
}

/**
 * @notice The callback {HookToken} makes on a registered recipient.
 */
interface IReceiver {
    function received(address from, uint256 value) external;
}
