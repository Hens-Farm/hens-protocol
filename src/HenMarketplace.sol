// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { HenNFT } from "./HenNFT.sol";

/// @notice Non-custodial fixed-price marketplace for the canonical Hen collection.
/// @dev Enforces the approved 2.5% fee and is also the sole floor-support purchase adapter.
contract HenMarketplace is ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint256 public constant MARKETPLACE_FEE_BPS = 250;

    struct Listing {
        address seller;
        uint128 price;
        uint64 expiry;
        uint64 nonce;
    }

    HenNFT public immutable hen;
    address public immutable revenueSplitter;

    mapping(uint256 henId => Listing) public listings;
    mapping(uint256 henId => uint64 nonce) public listingNonce;
    mapping(address seller => uint256 amount) public pendingProceeds;

    event HenListed(
        uint256 indexed henId, address indexed seller, uint256 price, uint256 expiry, uint256 nonce
    );
    event ListingCancelled(uint256 indexed henId, address indexed seller, uint256 nonce);
    event HenPurchased(
        uint256 indexed henId,
        address indexed seller,
        address indexed buyer,
        address recipient,
        uint256 price,
        uint256 fee,
        uint256 nonce
    );
    event ProceedsWithdrawn(address indexed seller, address indexed recipient, uint256 amount);

    error InvalidConfiguration();
    error NotHenOwner();
    error MarketplaceNotApproved();
    error InvalidListing();
    error StaleListing();
    error WrongCollection();
    error WrongPayment();
    error NothingToWithdraw();
    error TransferFailed();

    constructor(HenNFT hen_, address revenueSplitter_) {
        if (address(hen_) == address(0) || revenueSplitter_ == address(0)) revert InvalidConfiguration();
        hen = hen_;
        revenueSplitter = revenueSplitter_;
    }

    function list(uint256 henId, uint128 price, uint64 expiry) external returns (uint64 newNonce) {
        if (hen.ownerOf(henId) != msg.sender) revert NotHenOwner();
        if (price == 0 || expiry <= block.timestamp) revert InvalidListing();
        if (hen.getApproved(henId) != address(this) && !hen.isApprovedForAll(msg.sender, address(this))) {
            revert MarketplaceNotApproved();
        }
        newNonce = ++listingNonce[henId];
        listings[henId] = Listing(msg.sender, price, expiry, newNonce);
        emit HenListed(henId, msg.sender, price, expiry, newNonce);
    }

    function cancel(uint256 henId) external {
        Listing memory listing = listings[henId];
        if (listing.seller != msg.sender) revert InvalidListing();
        delete listings[henId];
        emit ListingCancelled(henId, msg.sender, listing.nonce);
    }

    /// @notice Clears a listing after ownership, approval or expiry has made it unusable.
    function invalidate(uint256 henId) external {
        Listing memory listing = listings[henId];
        if (listing.seller == address(0) || _isLive(henId, listing)) revert InvalidListing();
        delete listings[henId];
        emit ListingCancelled(henId, listing.seller, listing.nonce);
    }

    function buy(uint256 henId, address recipient, uint64 expectedNonce)
        external
        payable
        nonReentrant
        returns (uint256 paid)
    {
        return _buy(henId, recipient, expectedNonce);
    }

    /// @notice Floor-reserve adapter entrypoint. `orderData` must encode the exact listing nonce.
    function buyHen(address collection, uint256 henId, address recipient, bytes calldata orderData)
        external
        payable
        nonReentrant
        returns (uint256 paid)
    {
        if (collection != address(hen)) revert WrongCollection();
        if (orderData.length != 32) revert InvalidListing();
        return _buy(henId, recipient, abi.decode(orderData, (uint64)));
    }

    function withdrawProceeds(address payable recipient) external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidConfiguration();
        amount = pendingProceeds[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingProceeds[msg.sender] = 0;
        _sendNative(recipient, amount);
        emit ProceedsWithdrawn(msg.sender, recipient, amount);
    }

    function isLive(uint256 henId) external view returns (bool) {
        return _isLive(henId, listings[henId]);
    }

    function _buy(uint256 henId, address recipient, uint64 expectedNonce) private returns (uint256 paid) {
        if (recipient == address(0)) revert InvalidConfiguration();
        Listing memory listing = listings[henId];
        if (listing.nonce != expectedNonce || !_isLive(henId, listing)) revert StaleListing();
        paid = listing.price;
        if (msg.value != paid) revert WrongPayment();
        delete listings[henId];

        uint256 fee = paid * MARKETPLACE_FEE_BPS / BPS;
        pendingProceeds[listing.seller] += paid - fee;
        hen.safeTransferFrom(listing.seller, recipient, henId);
        _sendNative(payable(revenueSplitter), fee);
        emit HenPurchased(henId, listing.seller, msg.sender, recipient, paid, fee, listing.nonce);
    }

    function _isLive(uint256 henId, Listing memory listing) private view returns (bool) {
        if (listing.seller == address(0) || listing.expiry <= block.timestamp) return false;
        try hen.ownerOf(henId) returns (address owner) {
            if (owner != listing.seller) return false;
        } catch {
            return false;
        }
        return hen.getApproved(henId) == address(this) || hen.isApprovedForAll(listing.seller, address(this));
    }

    function _sendNative(address payable recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = recipient.call{ value: amount }("");
        if (!success) revert TransferFailed();
    }
}
