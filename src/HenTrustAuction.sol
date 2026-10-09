// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { HenNFT } from "./HenNFT.sol";

/// @notice Transparent English auctions for Hens released from the Hen Trust.
contract HenTrustAuction is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    uint256 public constant MINIMUM_DURATION = 24 hours;
    uint256 public constant MAXIMUM_DURATION = 14 days;
    uint256 public constant EXTENSION_WINDOW = 10 minutes;

    struct Auction {
        uint64 startTime;
        uint64 endTime;
        uint128 reservePrice;
        uint128 highestBid;
        address highestBidder;
        address winningRecipient;
        bool settled;
        bool cancelled;
    }

    HenNFT public immutable hen;
    address public revenueSplitter;
    bool public configurationLocked;
    mapping(uint256 henId => Auction) public auctions;
    mapping(address bidder => uint256 amount) public refundable;

    event AuctionCreated(uint256 indexed henId, uint256 reservePrice, uint256 startTime, uint256 endTime);
    event BidPlaced(uint256 indexed henId, address indexed bidder, address indexed recipient, uint256 amount);
    event AuctionExtended(uint256 indexed henId, uint256 newEndTime);
    event AuctionCancelled(uint256 indexed henId);
    event AuctionSettled(uint256 indexed henId, address indexed winner, uint256 amount);
    event RefundWithdrawn(address indexed bidder, uint256 amount);
    event RevenueSplitterSet(address indexed splitter);
    event ConfigurationLocked();

    error InvalidConfiguration();
    error InvalidAuction();
    error AuctionNotActive();
    error BidTooLow();
    error AuctionNotEnded();
    error NotHighestBidder();
    error TransferFailed();
    error WrongCollection();
    error ConfigurationIsLocked();

    constructor(HenNFT hen_, address governanceTimelock_) Ownable(governanceTimelock_) {
        if (address(hen_) == address(0) || governanceTimelock_ == address(0)) {
            revert InvalidConfiguration();
        }
        hen = hen_;
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

    function createAuction(uint256 henId, uint128 reservePrice, uint64 startTime, uint64 duration)
        external
        onlyOwner
    {
        if (!configurationLocked) revert InvalidConfiguration();
        if (
            hen.ownerOf(henId) != address(this) || reservePrice == 0 || duration < MINIMUM_DURATION
                || duration > MAXIMUM_DURATION || startTime < block.timestamp
                || (auctions[henId].endTime != 0 && !auctions[henId].settled && !auctions[henId].cancelled)
        ) revert InvalidAuction();

        uint64 endTime = startTime + duration;
        auctions[henId] = Auction(startTime, endTime, reservePrice, 0, address(0), address(0), false, false);
        emit AuctionCreated(henId, reservePrice, startTime, endTime);
    }

    function bid(uint256 henId, address recipient) external payable nonReentrant {
        Auction storage auction = auctions[henId];
        if (
            recipient == address(0) || auction.cancelled || auction.settled
                || block.timestamp < auction.startTime || block.timestamp >= auction.endTime
        ) revert AuctionNotActive();
        if (msg.value < auction.reservePrice || msg.value <= auction.highestBid) revert BidTooLow();

        if (auction.highestBidder != address(0)) refundable[auction.highestBidder] += auction.highestBid;
        auction.highestBid = uint128(msg.value);
        auction.highestBidder = msg.sender;
        auction.winningRecipient = recipient;

        if (auction.endTime - block.timestamp <= EXTENSION_WINDOW) {
            auction.endTime = uint64(block.timestamp + EXTENSION_WINDOW);
            emit AuctionExtended(henId, auction.endTime);
        }
        emit BidPlaced(henId, msg.sender, recipient, msg.value);
    }

    function setWinningRecipient(uint256 henId, address recipient) external {
        Auction storage auction = auctions[henId];
        if (msg.sender != auction.highestBidder) revert NotHighestBidder();
        if (recipient == address(0) || auction.settled || auction.cancelled) revert InvalidAuction();
        auction.winningRecipient = recipient;
    }

    function cancelAuction(uint256 henId) external onlyOwner {
        Auction storage auction = auctions[henId];
        if (
            auction.endTime == 0 || auction.settled || auction.cancelled
                || auction.highestBidder != address(0)
        ) {
            revert InvalidAuction();
        }
        auction.cancelled = true;
        emit AuctionCancelled(henId);
    }

    /// @notice Anyone may settle. All proceeds go directly to the immutable protocol splitter.
    function settle(uint256 henId) external nonReentrant {
        Auction storage auction = auctions[henId];
        if (auction.endTime == 0 || auction.cancelled || auction.settled) revert InvalidAuction();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        auction.settled = true;

        if (auction.highestBidder == address(0)) {
            emit AuctionSettled(henId, address(0), 0);
            return;
        }

        uint256 proceeds = auction.highestBid;
        address recipient = auction.winningRecipient;
        hen.safeTransferFrom(address(this), recipient, henId);
        (bool success,) = revenueSplitter.call{ value: proceeds }("");
        if (!success) revert TransferFailed();
        emit AuctionSettled(henId, recipient, proceeds);
    }

    function withdrawRefund() external nonReentrant {
        uint256 amount = refundable[msg.sender];
        if (amount == 0) revert TransferFailed();
        refundable[msg.sender] = 0;
        (bool success,) = msg.sender.call{ value: amount }("");
        if (!success) revert TransferFailed();
        emit RefundWithdrawn(msg.sender, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(hen)) revert WrongCollection();
        return IERC721Receiver.onERC721Received.selector;
    }
}
