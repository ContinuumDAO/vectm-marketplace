// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

interface IVotingEscrowMarketplace {
    // NOTE: I-14: Replaced grammar as suggested
    /// @notice The Fee tiers used to charge higher fees on larger locks, discouraging shill bidding.
    enum FeeTier {
        Black, // 1m   <= x
        Gold, // 500k <= x < 1m
        Silver, // 200k <= x < 500k
        Bronze, // 50k  <= x < 200k
        Blue // 1    <= x < 50k
    }

    /// @notice The kind of market order; can be either Listing (seller initiated) or Offering (buyer initiated)
    enum MarketOrderKind {
        Listing,
        Offering
    }

    /// @notice The possible states in which a market order (Listing/Offering) can be.
    enum MarketOrderStatus {
        NonExistent,
        Open,
        Fulfilled,
        Expired,
        DelistedOrRescinded,
        LockAmountDecreased,
        LockEndIncreased,
        TokenApprovalRequired,
        PaymentApprovalRequired,
        KeyGenAttached
    }

    /// @notice The blueprint of a market order can be instantiated as Listing or Offering.
    struct MarketOrder {
        uint256 price;
        uint256 deadline;
        uint256 snapshotAmount;
        uint256 snapshotEnd;
        address creator;
        address paymentToken;
        MarketOrderStatus status;
        MarketOrderKind kind;
    }

    /// @notice The possible states in which an auction can be.
    enum AuctionStatus {
        NonExistent,
        Pending,
        Active,
        Complete,
        Sold,
        Canceled,
        Expired
    }

    /// @notice The blueprint for an auction.
    struct Auction {
        uint256 reservePrice;
        uint256 minimumBidIncrement;
        uint256 deadline;
        address seller;
        address paymentToken;
        address highestBidder;
        uint256 highestBid;
        // BUG: I-28: Remove redundant locked amount snapshot from auctioned token (locked CTM cannot be removed while
        // escrowed in this contract
        // uint256 lockedAmount;
        AuctionStatus status;
    }

    // state
    function minimumDuration() external view returns (uint256);
    function maximumDuration() external view returns (uint256);
    function ve() external view returns (address);
    function gov() external view returns (address);
    function np() external view returns (address);
    function weth() external view returns (address);

    // state mappings
    function isValidPaymentToken(address _paymentToken) external view returns (bool _isValid);
    function feeLimitByTier(FeeTier _feeTier) external view returns (uint256 _lowerLimit);
    function feeRateByTier(FeeTier _feeTier) external view returns (uint256 _rate);
    function listingsByToken(uint256 _tokenId, uint256 _index)
        external
        view
        returns (
            uint256 price,
            uint256 deadline,
            uint256 snapshotAmount,
            uint256 snapshotEnd,
            address creator,
            address paymentToken,
            MarketOrderStatus status,
            MarketOrderKind kind
        );
    function nListingsByToken(uint256 _tokenId) external view returns (uint256 _n);
    function listingIndexByTokenSeller(uint256 _tokenId, address _seller) external view returns (uint256 _index);
    function offeringsByToken(uint256 _tokenId, uint256 _index)
        external
        view
        returns (
            uint256 price,
            uint256 deadline,
            uint256 snapshotAmount,
            uint256 snapshotEnd,
            address creator,
            address paymentToken,
            MarketOrderStatus status,
            MarketOrderKind kind
        );
    function nOfferingsByToken(uint256 _tokenId) external view returns (uint256 _n);
    function offeringIndexByTokenBuyer(uint256 _tokenId, address _buyer) external view returns (uint256 _index);
    function auctionsByToken(uint256 _tokenId, uint256 _index)
        external
        view
        returns (
            uint256 reservePrice,
            uint256 minimumBidIncrement,
            uint256 deadline,
            address seller,
            address paymentToken,
            address highestBidder,
            uint256 highestBid,
            AuctionStatus status
        );
    function nAuctionsByToken(uint256 _tokenId) external view returns (uint256 _n);
    function auctionIndexByTokenSeller(uint256 _tokenId, address _seller) external view returns (uint256 _index);

    // admin
    function setProtocolContracts(address _ve, address _gov, address _np, address _weth) external;
    function setBoundaryDurations(uint256 _min, uint256 _max) external;
    function setPaymentTokenValidity(address _paymentToken, bool _isValid) external;
    function configureFees(uint256[5] calldata _limitsCTM, uint256[5] calldata _ratesBps) external;

    // listing
    function createListing(uint256 _tokenId, address _paymentToken, uint256 _ask, uint256 _listingDuration) external;
    function delist(uint256 _tokenId) external;
    function fulfillListing(uint256 _tokenId, address _seller, address _paymentToken, uint256 _price) external payable;

    // offering
    function createOffering(uint256 _tokenId, address _paymentToken, uint256 _bid, uint256 _offeringDuration)
        external
        payable;
    function rescind(uint256 _tokenId) external;
    function fulfillOffering(uint256 _tokenId, address _buyer, address _paymentToken, uint256 _price) external;

    // auction
    function createAuction(
        uint256 _tokenId,
        address _paymentToken,
        uint48 _auctionDuration,
        uint256 _reservePrice,
        uint256 _minimumBidIncrement
    ) external;
    function cancelAuction(uint256 _tokenId) external;
    function auctionBid(uint256 _tokenId, address _seller, uint256 _price) external payable;
    function settleAuction(uint256 _tokenId, address _seller) external;

    // view status
    function marketOrderStatus(
        MarketOrder memory _marketOrder,
        uint256 _lockedAmountNow,
        uint256 _lockedEndNow,
        address _buyer,
        uint256 _tokenId
    ) external returns (MarketOrderStatus _status);
    function auctionStatus(Auction memory _auction) external view returns (AuctionStatus _status);
    function calculateFeeTier(uint256 _lockedAmount) external view returns (FeeTier);

    // IERC721Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4);
}
