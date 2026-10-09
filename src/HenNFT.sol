// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC721Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import { ERC2981Upgradeable } from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract HenNFT is
    Initializable,
    ERC721Upgradeable,
    ERC2981Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant MAX_SUPPLY = 10_000;
    uint96 public constant ROYALTY_BPS = 250;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant WEIGHT_ROLE = keccak256("WEIGHT_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    enum MintOrigin {
        OgClaim,
        PublicMint,
        Trust
    }

    struct HenData {
        uint64 mintedAt;
        uint64 originalChiknId;
        MintOrigin origin;
        uint256 heggBurned;
    }

    uint256 public totalMinted;
    bool public royaltyConfigurationLocked;
    string private _baseTokenURI;
    mapping(uint256 henId => HenData) private _henData;

    event HenMinted(uint256 indexed henId, address indexed to, MintOrigin origin, uint256 originalChiknId);
    event HenWeightIncreased(uint256 indexed henId, uint256 heggBurned, uint256 totalHeggBurned);
    event BaseURISet(string newBaseURI);
    event RoyaltyConfigurationLocked();

    error MaxSupplyReached();
    error AlreadyMinted(uint256 henId);
    error RoyaltyIsLocked();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address royaltyReceiver, string calldata baseURI_)
        external
        initializer
    {
        __ERC721_init("Hens", "HEN");
        __ERC2981_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _setDefaultRoyalty(royaltyReceiver, ROYALTY_BPS);
        _baseTokenURI = baseURI_;
    }

    /// @notice Updates only the receiver; the 2.5% royalty rate is fixed in code.
    function setRoyaltyReceiver(address royaltyReceiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (royaltyConfigurationLocked) revert RoyaltyIsLocked();
        _setDefaultRoyalty(royaltyReceiver, ROYALTY_BPS);
    }

    function lockRoyaltyConfiguration() external onlyRole(DEFAULT_ADMIN_ROLE) {
        royaltyConfigurationLocked = true;
        emit RoyaltyConfigurationLocked();
    }

    function mint(address to, uint256 henId, MintOrigin origin, uint256 originalChiknId)
        external
        onlyRole(MINTER_ROLE)
    {
        if (totalMinted >= MAX_SUPPLY) revert MaxSupplyReached();
        if (_ownerOf(henId) != address(0)) revert AlreadyMinted(henId);
        ++totalMinted;
        _henData[henId] = HenData(uint64(block.timestamp), uint64(originalChiknId), origin, 0);
        _safeMint(to, henId);
        emit HenMinted(henId, to, origin, originalChiknId);
    }

    function addBurnedHegg(uint256 henId, uint256 amount) external onlyRole(WEIGHT_ROLE) {
        _requireOwned(henId);
        _henData[henId].heggBurned += amount;
        emit HenWeightIncreased(henId, amount, _henData[henId].heggBurned);
    }

    function henData(uint256 henId) external view returns (HenData memory) {
        _requireOwned(henId);
        return _henData[henId];
    }

    function setBaseURI(string calldata newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = newBaseURI;
        emit BaseURISet(newBaseURI);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) { }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC2981Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
