// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice Irrevocable custody for the protocol's single Uniswap v4 position NFT.
/// @dev It intentionally has no NFT transfer, withdrawal, rescue or arbitrary-call function.
contract V4PositionCustody is IERC721Receiver {
    IERC721 public immutable positionManager;
    address public immutable configurator;

    address public liquidityOperator;
    uint256 public positionTokenId;
    uint256 public expectedTokenId;
    bool public prepared;
    bool public finalized;

    event PositionPrepared(uint256 indexed tokenId, address indexed liquidityOperator);
    event PositionReceived(uint256 indexed tokenId);
    event PositionFinalized(uint256 indexed tokenId, address indexed liquidityOperator);

    error Unauthorized();
    error AlreadyConfigured();
    error InvalidConfiguration();
    error UnexpectedPosition();
    error PositionNotReceived();

    constructor(IERC721 positionManager_, address configurator_) {
        if (address(positionManager_) == address(0) || configurator_ == address(0)) {
            revert InvalidConfiguration();
        }
        positionManager = positionManager_;
        configurator = configurator_;
    }

    /// @notice Commits the only position ID and operator this custody contract will ever accept.
    function preparePosition(uint256 tokenId, address operator) external {
        if (msg.sender != configurator) revert Unauthorized();
        if (prepared || finalized) revert AlreadyConfigured();
        if (tokenId == 0 || operator == address(0)) revert InvalidConfiguration();
        prepared = true;
        expectedTokenId = tokenId;
        liquidityOperator = operator;
        emit PositionPrepared(tokenId, operator);
    }

    /// @notice Grants the fixed operator permission to increase liquidity after custody is proven.
    function finalizePosition() external {
        if (msg.sender != configurator) revert Unauthorized();
        if (!prepared || finalized) revert AlreadyConfigured();
        if (positionTokenId != expectedTokenId || positionManager.ownerOf(expectedTokenId) != address(this)) {
            revert PositionNotReceived();
        }
        finalized = true;
        positionManager.approve(liquidityOperator, positionTokenId);
        emit PositionFinalized(positionTokenId, liquidityOperator);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(positionManager) || !prepared || finalized || tokenId != expectedTokenId) {
            revert UnexpectedPosition();
        }
        positionTokenId = tokenId;
        emit PositionReceived(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }
}
