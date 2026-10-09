// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice Standard fixed-supply HEGG. Official-pool trade fees are enforced by HeggV4TaxHook.
contract HeggToken is ERC20, ERC20Burnable {
    error ZeroAddress();

    constructor(uint256 fixedSupply, address supplyRecipient) ERC20("Hen Egg", "HEGG") {
        if (supplyRecipient == address(0)) revert ZeroAddress();
        _mint(supplyRecipient, fixedSupply);
    }
}
