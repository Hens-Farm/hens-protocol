// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { HenNFT } from "./HenNFT.sol";
import { IHenPublicMintBond } from "./IHenPublicMintBond.sol";

contract HenClaimController is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ALLOCATION_ROLE = keccak256("ALLOCATION_ROLE");
    uint64 public constant OG_CLAIM_DURATION = 12 days;
    uint64 public constant PUBLIC_MINT_DELAY = 1 days;

    HenNFT public hen;
    bytes32 public ogSnapshotRoot;
    bytes32 public allocationRoot;
    uint64 public claimStart;
    uint64 public claimEnd;
    uint64 public publicMintStart;
    uint32 public publicAllocationCount;
    uint32 public trustAllocationCount;
    uint32 public publicCursor;
    uint32 public ogClaimedCount;
    bool public allocationFinalized;

    mapping(uint256 chiknId => bool) public chiknClaimed;
    mapping(uint256 henId => bool) public henAllocated;
    mapping(address wallet => bool) public publicMinted;
    mapping(uint256 index => bool) public trustMinted;

    // Appended for storage-safe UUPS upgrade of the deployed controller.
    IHenPublicMintBond public publicMintBond;
    mapping(uint256 index => bool) public publicIndexMinted;

    event OgHenClaimed(address indexed account, uint256 indexed chiknId, uint256 indexed henId);
    event AllocationFinalized(bytes32 indexed root, uint256 publicCount, uint256 trustCount);
    event PublicHenMinted(address indexed account, uint256 indexed henId, uint256 indexed index);
    event TrustHenMinted(address indexed recipient, uint256 indexed henId, uint256 indexed index);
    event PublicMintBondConfigured(address indexed bond);

    error InvalidWindow();
    error ClaimClosed();
    error ClaimNotOpen();
    error PublicMintNotOpen();
    error InvalidProof();
    error AlreadyClaimed();
    error AlreadyPublicMinted();
    error LengthMismatch();
    error AllocationAlreadyFinalized();
    error AllocationNotFinalized();
    error InvalidAllocationIndex();
    error InvalidAllocationCounts();
    error InvalidBond();
    error BondAlreadyConfigured();
    error BondConfigurationClosed();
    error BondMintRequired();
    error BondNotConfigured();
    error PublicIndexAlreadyMinted();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        HenNFT hen_,
        bytes32 ogSnapshotRoot_,
        uint64 claimStart_,
        uint64 claimEnd_,
        uint64 publicMintStart_
    ) external initializer {
        if (
            claimStart_ <= block.timestamp || claimEnd_ != claimStart_ + OG_CLAIM_DURATION
                || publicMintStart_ != claimEnd_ + PUBLIC_MINT_DELAY
        ) {
            revert InvalidWindow();
        }
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(ALLOCATION_ROLE, admin);
        hen = hen_;
        ogSnapshotRoot = ogSnapshotRoot_;
        claimStart = claimStart_;
        claimEnd = claimEnd_;
        publicMintStart = publicMintStart_;
    }

    /// @notice Claims every supplied OG Chikn/Hen pair in one transaction.
    function claimAll(uint256[] calldata chiknIds, uint256[] calldata henIds, bytes32[][] calldata proofs)
        external
    {
        if (block.timestamp < claimStart) revert ClaimNotOpen();
        if (block.timestamp >= claimEnd) revert ClaimClosed();
        if (chiknIds.length != henIds.length || henIds.length != proofs.length) revert LengthMismatch();

        for (uint256 i; i < chiknIds.length; ++i) {
            uint256 chiknId = chiknIds[i];
            uint256 henId = henIds[i];
            if (chiknClaimed[chiknId] || henAllocated[henId]) revert AlreadyClaimed();
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, chiknId, henId))));
            if (!MerkleProof.verifyCalldata(proofs[i], ogSnapshotRoot, leaf)) revert InvalidProof();
            chiknClaimed[chiknId] = true;
            henAllocated[henId] = true;
            ++ogClaimedCount;
            hen.mint(msg.sender, henId, HenNFT.MintOrigin.OgClaim, chiknId);
            emit OgHenClaimed(msg.sender, chiknId, henId);
        }
    }

    /// @notice Locks the verifiable shuffle output after the OG claim window.
    function finalizeAllocation(bytes32 root, uint32 publicCount, uint32 trustCount)
        external
        onlyRole(ALLOCATION_ROLE)
    {
        if (block.timestamp < claimEnd) revert ClaimClosed();
        if (allocationFinalized) revert AllocationAlreadyFinalized();
        uint256 remaining = hen.MAX_SUPPLY() - ogClaimedCount;
        uint256 expectedTrust = remaining * 20 / 100;
        uint256 expectedPublic = remaining - expectedTrust;
        if (root == bytes32(0) || publicCount != expectedPublic || trustCount != expectedTrust) {
            revert InvalidAllocationCounts();
        }
        allocationFinalized = true;
        allocationRoot = root;
        publicAllocationCount = publicCount;
        trustAllocationCount = trustCount;
        emit AllocationFinalized(root, publicCount, trustCount);
    }

    /// @notice Mints the next Hen in the published shuffled public sequence.
    function publicMint(uint256 henId, bytes32[] calldata proof) external {
        if (address(publicMintBond) != address(0)) revert BondMintRequired();
        _publicMint(msg.sender, publicCursor, henId, proof);
    }

    /// @notice Mints through the HEGG qualification bond after atomically consuming eligibility.
    function publicMintBonded(uint256 henId, bytes32[] calldata proof) external {
        IHenPublicMintBond bond = publicMintBond;
        if (address(bond) == address(0)) revert BondNotConfigured();
        uint256 index = bond.consumeClaim(msg.sender);
        _publicMint(msg.sender, index, henId, proof);
    }

    /// @notice Permanently installs the bond gate. Must happen before that contract accepts deposits.
    function configurePublicMintBond(IHenPublicMintBond bond) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(publicMintBond) != address(0)) revert BondAlreadyConfigured();
        if (address(bond).code.length == 0 || bond.claimController() != address(this)) {
            revert InvalidBond();
        }
        if (bond.publicMintStart() != publicMintStart) revert InvalidBond();
        if (block.timestamp >= bond.lockStart()) revert BondConfigurationClosed();
        publicMintBond = bond;
        emit PublicMintBondConfigured(address(bond));
    }

    function _publicMint(address account, uint256 index, uint256 henId, bytes32[] calldata proof) internal {
        if (!allocationFinalized) revert AllocationNotFinalized();
        if (block.timestamp < publicMintStart) revert PublicMintNotOpen();
        if (publicMinted[account]) revert AlreadyPublicMinted();
        if (index >= publicAllocationCount) revert InvalidAllocationIndex();
        if (publicIndexMinted[index]) revert PublicIndexAlreadyMinted();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, henId, false))));
        if (!MerkleProof.verifyCalldata(proof, allocationRoot, leaf)) revert InvalidProof();
        if (henAllocated[henId]) revert AlreadyClaimed();
        publicMinted[account] = true;
        publicIndexMinted[index] = true;
        henAllocated[henId] = true;
        ++publicCursor;
        hen.mint(account, henId, HenNFT.MintOrigin.PublicMint, 0);
        emit PublicHenMinted(account, henId, index);
    }

    function mintTrust(uint256 index, uint256 henId, address recipient, bytes32[] calldata proof)
        external
        onlyRole(ALLOCATION_ROLE)
    {
        if (!allocationFinalized) revert AllocationNotFinalized();
        if (index >= trustAllocationCount || trustMinted[index]) revert InvalidAllocationIndex();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, henId, true))));
        if (!MerkleProof.verifyCalldata(proof, allocationRoot, leaf)) revert InvalidProof();
        if (henAllocated[henId]) revert AlreadyClaimed();
        trustMinted[index] = true;
        henAllocated[henId] = true;
        hen.mint(recipient, henId, HenNFT.MintOrigin.Trust, 0);
        emit TrustHenMinted(recipient, henId, index);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) { }
}
