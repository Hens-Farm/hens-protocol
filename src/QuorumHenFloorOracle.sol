// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IHenFloorOracle } from "./HenFloorSupportReserve.sol";

/// @notice A deliberately simple floor oracle requiring independent reporters to agree each round.
/// @dev Reports are sorted on finalization and the median becomes the only price exposed to the reserve.
contract QuorumHenFloorOracle is Ownable2Step, IHenFloorOracle {
    uint256 public constant MAX_REPORTERS = 9;

    mapping(address reporter => bool enabled) public isReporter;
    mapping(uint256 roundId => mapping(address reporter => bool submitted)) public hasSubmitted;
    mapping(uint256 roundId => uint256[] prices) private _roundPrices;

    uint256 public immutable quorum;
    uint256 public latestRound;
    uint256 private _floorPrice;
    uint256 private _updatedAt;
    bool public reportersLocked;

    event ReporterSet(address indexed reporter, bool enabled);
    event ReportersLocked();
    event PriceSubmitted(uint256 indexed roundId, address indexed reporter, uint256 price);
    event RoundFinalized(uint256 indexed roundId, uint256 medianPrice, uint256 reportCount);

    error InvalidConfiguration();
    error ReportersAreLocked();
    error UnauthorizedReporter();
    error InvalidRound();
    error AlreadySubmitted();
    error RoundComplete();

    constructor(uint256 quorum_, address owner_) Ownable(owner_) {
        if (quorum_ < 2 || quorum_ > MAX_REPORTERS) revert InvalidConfiguration();
        quorum = quorum_;
    }

    function setReporter(address reporter, bool enabled) external onlyOwner {
        if (reportersLocked) revert ReportersAreLocked();
        if (reporter == address(0)) revert InvalidConfiguration();
        isReporter[reporter] = enabled;
        emit ReporterSet(reporter, enabled);
    }

    function lockReporters() external onlyOwner {
        reportersLocked = true;
        emit ReportersLocked();
    }

    /// @notice Submit one price for the next round. The quorum-th report finalizes the median.
    function submit(uint256 roundId, uint256 price) external {
        if (!reportersLocked || !isReporter[msg.sender]) revert UnauthorizedReporter();
        if (roundId != latestRound + 1 || price == 0) revert InvalidRound();
        if (hasSubmitted[roundId][msg.sender]) revert AlreadySubmitted();

        uint256[] storage prices = _roundPrices[roundId];
        if (prices.length >= quorum) revert RoundComplete();
        hasSubmitted[roundId][msg.sender] = true;
        prices.push(price);
        emit PriceSubmitted(roundId, msg.sender, price);

        if (prices.length == quorum) {
            uint256[] memory sorted = prices;
            _sort(sorted);
            // For an even quorum, use the conservative lower median.
            uint256 median = sorted[(quorum - 1) / 2];
            latestRound = roundId;
            _floorPrice = median;
            _updatedAt = block.timestamp;
            emit RoundFinalized(roundId, median, quorum);
        }
    }

    function floorPrice() external view returns (uint256 price, uint256 updatedAt) {
        return (_floorPrice, _updatedAt);
    }

    function reportCount(uint256 roundId) external view returns (uint256) {
        return _roundPrices[roundId].length;
    }

    function _sort(uint256[] memory values) private pure {
        for (uint256 i = 1; i < values.length; ++i) {
            uint256 value = values[i];
            uint256 j = i;
            while (j > 0 && values[j - 1] > value) {
                values[j] = values[j - 1];
                unchecked {
                    --j;
                }
            }
            values[j] = value;
        }
    }
}
