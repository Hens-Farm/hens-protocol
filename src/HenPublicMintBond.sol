// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IHenPublicMintAllocation {
    function allocationFinalized() external view returns (bool);
    function publicAllocationCount() external view returns (uint32);
}

/// @notice Holds one refundable HEGG bond per public-mint entrant and selects winners on-chain.
/// @dev There is deliberately no owner withdrawal or bond-seizure path. A deployment is one mint round.
contract HenPublicMintBond is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant QUALIFICATION_PERIOD = 120 minutes;
    uint64 public constant CLAIM_WINDOW = 24 hours;
    uint64 public constant WINNER_REFUND_DELAY = 2 hours;
    uint32 public constant MAX_ENTROPY_DELAY_BLOCKS = 200;

    struct Entry {
        uint64 ticket;
        uint64 claimedAt;
        bool locked;
    }

    IERC20 public immutable hegg;
    address public immutable claimController;
    uint256 public immutable bondAmount;
    uint64 public immutable lockStart;
    uint64 public immutable lockCutoff;
    uint64 public immutable publicMintStart;
    uint64 public immutable claimDeadline;
    bytes32 public immutable entropyCommitment;
    uint32 public immutable entropyDelayBlocks;

    uint64 public entrantCount;
    uint64 public winnerCount;
    uint64 public entropyBlock;
    uint256 public totalLocked;
    bytes32 public capturedBlockHash;
    bytes32 public selectionSeed;
    uint64 public permutationMultiplier;
    uint64 public permutationOffset;
    bool public selectionRequested;
    bool public selectionFinalized;

    mapping(address account => Entry) public entries;

    event BondLocked(address indexed account, uint256 amount, uint256 indexed ticket);
    event SelectionRequested(uint256 entrantCount, uint256 winnerCount, uint256 entropyBlock);
    event EntropyCaptured(uint256 indexed entropyBlock, bytes32 blockHash);
    event SelectionFinalized(bytes32 indexed seed, uint256 winnerCount, uint256 multiplier, uint256 offset);
    event ClaimConsumed(
        address indexed account,
        uint256 indexed ticket,
        uint256 indexed allocationIndex,
        uint256 refundAvailableAt
    );
    event BondWithdrawn(address indexed account, uint256 amount);

    error ZeroAddress();
    error InvalidAmount();
    error InvalidSchedule();
    error InvalidCommitment();
    error InvalidEntropyDelay();
    error LockNotOpen();
    error LockClosed();
    error AlreadyEntered();
    error UnexpectedTransferAmount();
    error AllocationNotFinalized();
    error SelectionAlreadyRequested();
    error SelectionNotRequested();
    error SelectionAlreadyFinalized();
    error SelectionWindowClosed();
    error EntropyNotReady();
    error EntropyExpired();
    error EntropyAlreadyCaptured();
    error InvalidEntropyReveal();
    error SelectionNotFinalized();
    error NotClaimController();
    error ClaimNotOpen();
    error ClaimClosed();
    error NotEntered();
    error NotSelected();
    error AlreadyClaimed();
    error RefundNotAvailable();

    constructor(
        IERC20 hegg_,
        address claimController_,
        uint256 bondAmount_,
        uint64 lockStart_,
        uint64 publicMintStart_,
        bytes32 entropyCommitment_,
        uint32 entropyDelayBlocks_
    ) {
        if (address(hegg_) == address(0) || claimController_ == address(0)) {
            revert ZeroAddress();
        }
        if (bondAmount_ == 0) revert InvalidAmount();
        if (publicMintStart_ <= QUALIFICATION_PERIOD || lockStart_ >= publicMintStart_ - QUALIFICATION_PERIOD)
        {
            revert InvalidSchedule();
        }
        if (entropyCommitment_ == bytes32(0)) revert InvalidCommitment();
        if (entropyDelayBlocks_ == 0 || entropyDelayBlocks_ > MAX_ENTROPY_DELAY_BLOCKS) {
            revert InvalidEntropyDelay();
        }

        hegg = hegg_;
        claimController = claimController_;
        bondAmount = bondAmount_;
        lockStart = lockStart_;
        lockCutoff = publicMintStart_ - QUALIFICATION_PERIOD;
        publicMintStart = publicMintStart_;
        claimDeadline = publicMintStart_ + CLAIM_WINDOW;
        entropyCommitment = entropyCommitment_;
        entropyDelayBlocks = entropyDelayBlocks_;
    }

    /// @notice Locks exactly one bond and assigns the caller one immutable ticket.
    function lock() external nonReentrant {
        if (block.timestamp < lockStart) revert LockNotOpen();
        if (block.timestamp >= lockCutoff) revert LockClosed();
        if (entries[msg.sender].locked) revert AlreadyEntered();

        uint64 ticket = entrantCount;
        entries[msg.sender] = Entry({ ticket: ticket, claimedAt: 0, locked: true });
        entrantCount = ticket + 1;
        totalLocked += bondAmount;

        uint256 balanceBefore = hegg.balanceOf(address(this));
        hegg.safeTransferFrom(msg.sender, address(this), bondAmount);
        if (hegg.balanceOf(address(this)) - balanceBefore != bondAmount) {
            revert UnexpectedTransferAmount();
        }
        emit BondLocked(msg.sender, bondAmount, ticket);
    }

    /// @notice Freezes the entrant count and obtains the public Hen supply from the mint controller.
    /// @dev Anyone may call this after the cutoff. Under-subscribed rounds finalize immediately.
    function requestSelection() external {
        if (block.timestamp < lockCutoff) revert LockNotOpen();
        if (block.timestamp >= publicMintStart) revert SelectionWindowClosed();
        if (selectionRequested) revert SelectionAlreadyRequested();
        IHenPublicMintAllocation controller = IHenPublicMintAllocation(claimController);
        if (!controller.allocationFinalized()) revert AllocationNotFinalized();

        uint64 available = uint64(controller.publicAllocationCount());
        uint64 selected = entrantCount < available ? entrantCount : available;
        selectionRequested = true;
        winnerCount = selected;

        if (selected == entrantCount || selected == 0) {
            selectionFinalized = true;
            emit SelectionRequested(entrantCount, selected, 0);
            emit SelectionFinalized(bytes32(0), selected, 0, 0);
            return;
        }

        entropyBlock = uint64(block.number + entropyDelayBlocks);
        emit SelectionRequested(entrantCount, selected, entropyBlock);
    }

    /// @notice Stores the committed future block hash before the EVM's 256-block lookup window expires.
    function captureEntropy() external {
        if (!selectionRequested) revert SelectionNotRequested();
        if (selectionFinalized) revert SelectionAlreadyFinalized();
        if (block.timestamp >= publicMintStart) revert SelectionWindowClosed();
        if (capturedBlockHash != bytes32(0)) revert EntropyAlreadyCaptured();
        if (block.number <= entropyBlock) revert EntropyNotReady();
        if (block.number > uint256(entropyBlock) + 256) revert EntropyExpired();

        bytes32 entropy = blockhash(entropyBlock);
        if (entropy == bytes32(0)) revert EntropyExpired();
        capturedBlockHash = entropy;
        emit EntropyCaptured(entropyBlock, entropy);
    }

    /// @notice Reveals the precommitted secret and finalizes a deterministic on-chain permutation.
    /// @dev The secret cannot be changed after deployment, and the future block hash was unknown then.
    function finalizeSelection(bytes32 secret) external {
        if (!selectionRequested) revert SelectionNotRequested();
        if (selectionFinalized) revert SelectionAlreadyFinalized();
        if (block.timestamp >= publicMintStart) revert SelectionWindowClosed();
        if (capturedBlockHash == bytes32(0)) revert EntropyNotReady();
        if (keccak256(abi.encodePacked(secret)) != entropyCommitment) revert InvalidEntropyReveal();

        bytes32 seed = keccak256(
            abi.encode(secret, capturedBlockHash, block.chainid, address(this), entrantCount, winnerCount)
        );
        uint64 multiplier = _coprimeMultiplier(uint256(seed), entrantCount);
        uint64 offset = uint64(uint256(keccak256(abi.encode(seed, "HENS_OFFSET"))) % entrantCount);

        selectionSeed = seed;
        permutationMultiplier = multiplier;
        permutationOffset = offset;
        selectionFinalized = true;
        emit SelectionFinalized(seed, winnerCount, multiplier, offset);
    }

    /// @notice Called atomically by the mint controller immediately before minting a selected wallet's Hen.
    function consumeClaim(address account) external returns (uint32 allocationIndex_) {
        if (msg.sender != claimController) revert NotClaimController();
        if (!selectionFinalized) revert SelectionNotFinalized();
        if (block.timestamp < publicMintStart) revert ClaimNotOpen();
        if (block.timestamp >= claimDeadline) revert ClaimClosed();

        Entry storage entry = entries[account];
        if (!entry.locked) revert NotEntered();
        if (entry.claimedAt != 0) revert AlreadyClaimed();
        if (!_isWinningTicket(entry.ticket)) revert NotSelected();

        entry.claimedAt = uint64(block.timestamp);
        allocationIndex_ = uint32(_allocationIndex(entry.ticket));
        emit ClaimConsumed(account, entry.ticket, allocationIndex_, block.timestamp + WINNER_REFUND_DELAY);
    }

    /// @notice Returns the full bond. Losers may withdraw after selection; winners unlock two hours
    /// after claiming, or at the end of the 24-hour claim window if they never claim.
    function withdraw() external nonReentrant {
        Entry storage entry = entries[msg.sender];
        if (!entry.locked) revert NotEntered();

        bool available;
        if (!selectionFinalized) {
            available = block.timestamp >= publicMintStart;
        } else if (entry.claimedAt != 0) {
            available = block.timestamp >= uint256(entry.claimedAt) + WINNER_REFUND_DELAY;
        } else if (!_isWinningTicket(entry.ticket)) {
            available = true;
        } else {
            available = block.timestamp >= claimDeadline;
        }
        if (!available) revert RefundNotAvailable();

        entry.locked = false;
        totalLocked -= bondAmount;
        hegg.safeTransfer(msg.sender, bondAmount);
        emit BondWithdrawn(msg.sender, bondAmount);
    }

    function isSelected(address account) external view returns (bool) {
        Entry memory entry = entries[account];
        return selectionFinalized && entry.locked && _isWinningTicket(entry.ticket);
    }

    function refundAvailableAt(address account) external view returns (uint256) {
        Entry memory entry = entries[account];
        if (!entry.locked) return 0;
        if (!selectionFinalized) return publicMintStart;
        if (entry.claimedAt != 0) return uint256(entry.claimedAt) + WINNER_REFUND_DELAY;
        if (!_isWinningTicket(entry.ticket)) return block.timestamp;
        return claimDeadline;
    }

    function permutedTicket(uint256 ticket) external view returns (uint256) {
        if (!selectionFinalized) revert SelectionNotFinalized();
        if (ticket >= entrantCount) revert NotEntered();
        return _permutedTicket(ticket);
    }

    /// @notice The winner's unique index in the published public-Hen allocation tree.
    function allocationIndex(address account) external view returns (uint256) {
        if (!selectionFinalized) revert SelectionNotFinalized();
        Entry memory entry = entries[account];
        if (!entry.locked) revert NotEntered();
        if (!_isWinningTicket(entry.ticket)) revert NotSelected();
        return _allocationIndex(entry.ticket);
    }

    function _isWinningTicket(uint256 ticket) internal view returns (bool) {
        if (winnerCount == entrantCount) return true;
        return _permutedTicket(ticket) < winnerCount;
    }

    function _allocationIndex(uint256 ticket) internal view returns (uint256) {
        if (winnerCount == entrantCount) return ticket;
        return _permutedTicket(ticket);
    }

    function _permutedTicket(uint256 ticket) internal view returns (uint256) {
        return addmod(mulmod(permutationMultiplier, ticket, entrantCount), permutationOffset, entrantCount);
    }

    function _coprimeMultiplier(uint256 seed, uint64 modulus) internal pure returns (uint64) {
        if (modulus <= 1) return 0;
        uint64 candidate = uint64(seed % modulus);
        if (candidate == 0) candidate = 1;
        while (_gcd(candidate, modulus) != 1) {
            candidate = candidate == modulus - 1 ? 1 : candidate + 1;
        }
        return candidate;
    }

    function _gcd(uint64 a, uint64 b) internal pure returns (uint64) {
        while (b != 0) {
            (a, b) = (b, a % b);
        }
        return a;
    }
}
