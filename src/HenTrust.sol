// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { HenNFT } from "./HenNFT.sol";
import { HenEmissionController } from "./HenEmissionController.sol";

/// @notice Restricted custody for the 20% trust allocation of unclaimed Hens.
contract HenTrust is Ownable2Step, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant RELEASE_DELAY = 7 days;

    struct Release {
        uint64 executableAt;
        bytes32 henIdsHash;
        bytes32 programHash;
        bool executed;
        bool cancelled;
    }

    HenNFT public immutable hen;
    HenEmissionController public immutable emissions;
    IERC20 public immutable hegg;
    address public revenueSplitter;
    address public immutable distributionModule;
    bool public configurationLocked;
    uint256 public releaseNonce;
    mapping(uint256 releaseId => Release) public releases;

    event ReleaseScheduled(
        uint256 indexed releaseId,
        bytes32 indexed henIdsHash,
        bytes32 indexed programHash,
        uint256 executableAt
    );
    event ReleaseCancelled(uint256 indexed releaseId);
    event ReleaseExecuted(uint256 indexed releaseId, uint256 count);
    event TrustEmissionsForwarded(uint256 amount);
    event RevenueSplitterSet(address indexed splitter);
    event ConfigurationLocked();

    error InvalidConfiguration();
    error InvalidRelease();
    error ReleaseNotReady();
    error WrongCollection();
    error ConfigurationIsLocked();

    constructor(
        HenNFT hen_,
        HenEmissionController emissions_,
        IERC20 hegg_,
        address distributionModule_,
        address governanceTimelock_
    ) Ownable(governanceTimelock_) {
        if (
            address(hen_) == address(0) || address(emissions_) == address(0) || address(hegg_) == address(0)
                || distributionModule_ == address(0) || governanceTimelock_ == address(0)
        ) revert InvalidConfiguration();
        hen = hen_;
        emissions = emissions_;
        hegg = hegg_;
        distributionModule = distributionModule_;
    }

    function setRevenueSplitter(address splitter) external onlyOwner {
        if (configurationLocked) revert ConfigurationIsLocked();
        if (splitter == address(0)) revert InvalidConfiguration();
        revenueSplitter = splitter;
        emit RevenueSplitterSet(splitter);
    }

    function lockConfiguration() external onlyOwner {
        if (revenueSplitter == address(0)) revert InvalidConfiguration();
        configurationLocked = true;
        emit ConfigurationLocked();
    }

    /// @notice Announces a release to the immutable distribution module at least seven days in advance.
    function scheduleRelease(uint256[] calldata henIds, bytes32 programHash)
        external
        onlyOwner
        returns (uint256 releaseId)
    {
        if (henIds.length == 0 || programHash == bytes32(0)) revert InvalidRelease();
        releaseId = ++releaseNonce;
        bytes32 idsHash = keccak256(abi.encode(henIds));
        uint64 executableAt = uint64(block.timestamp + RELEASE_DELAY);
        releases[releaseId] = Release(executableAt, idsHash, programHash, false, false);
        emit ReleaseScheduled(releaseId, idsHash, programHash, executableAt);
    }

    function cancelRelease(uint256 releaseId) external onlyOwner {
        Release storage release = releases[releaseId];
        if (release.executableAt == 0 || release.executed || release.cancelled) revert InvalidRelease();
        release.cancelled = true;
        emit ReleaseCancelled(releaseId);
    }

    /// @notice Anyone may execute a valid release after the public delay has elapsed.
    function executeRelease(uint256 releaseId, uint256[] calldata henIds) external {
        Release storage release = releases[releaseId];
        if (
            release.executableAt == 0 || release.executed || release.cancelled
                || release.henIdsHash != keccak256(abi.encode(henIds))
        ) revert InvalidRelease();
        if (block.timestamp < release.executableAt) revert ReleaseNotReady();
        release.executed = true;
        for (uint256 i; i < henIds.length; ++i) {
            hen.safeTransferFrom(address(this), distributionModule, henIds[i]);
        }
        emit ReleaseExecuted(releaseId, henIds.length);
    }

    /// @notice Claims Trust-Hen emissions and forwards all HEGG to the immutable protocol splitter.
    function claimAndForwardEmissions(uint256[] calldata henIds) external returns (uint256 amount) {
        if (!configurationLocked) revert InvalidConfiguration();
        emissions.claim(henIds);
        amount = hegg.balanceOf(address(this));
        if (amount != 0) hegg.safeTransfer(revenueSplitter, amount);
        emit TrustEmissionsForwarded(amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(hen)) revert WrongCollection();
        return IERC721Receiver.onERC721Received.selector;
    }
}
