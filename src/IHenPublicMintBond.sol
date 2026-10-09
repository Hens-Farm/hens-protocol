// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IHenPublicMintBond {
    function claimController() external view returns (address);
    function lockStart() external view returns (uint64);
    function publicMintStart() external view returns (uint64);
    function consumeClaim(address account) external returns (uint32 allocationIndex);
}
