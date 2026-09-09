// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IVotingEscrow {
    function safeTransferFrom(address _from, address _to, uint256 _tokenId) external;
    function approve(address _approved, uint256 _tokenId) external;
    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool);
    function ownerOf(uint256 _tokenId) external view returns (address);
    function locked(uint256 _tokenId) external view returns (int128, uint256);
}

interface INodeProperties {
    function attachedKeyGen(uint256 _tokenId) external view returns (address);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 _wad) external;
}

// NOTE: Inline BUG or NOTE comments will be removed before production.
contract VotingEscrowMarketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Only governance can call this function.
    error OnlyGov();
    /// @notice Only veCTM can call this function.
    error OnlyVotingEscrow();
    /// @notice Only owner of relevant veCTM can call this function.
    error OnlyOwner();
    /// @notice Owner of relevant veCTM cannot call this function.
    error OnlyNonOwner();
    /// @notice Only the seller of the Listing can be supplied.
    error OnlySeller();
    /// @notice Only the buyer of the Offering can be supplied.
    error OnlyBuyer();

    /// @notice Fees provided are invalid: either non-monotonic, equal to zero, or greater than bps denominator
    error InvalidFeeConfiguration();

    /// @notice Order (Listing/Offering) has a status different from what is expected.
    error UnexpectedMarketOrderState(MarketOrderStatus _expected, MarketOrderStatus _actual);

    /// @notice veCTM in question is attached to a KeyGen (via NodeProperties) rendering it unable to change ownership.
    error KeyGenAttached();

    /// @notice Invalid ether is attached to msg.value; this could mean too little or too much.
    error InvalidEtherAmount();
    /// @notice The underlying CTM amount for the relevant veCTM has decreased since some snapshot taken in the past.
    error LockAmountDecreased();
    /// @notice The unlock (expiry) time for the relevant veCTM has increased since some snapshot taken in the past.
    error LockEndIncreased();
    /// @notice This should never throw: it means the underlying CTM in a veCTM is below the lowest fee tier floor,
    /// which shouldn't be possible if the latter is set to the enforced veCTM minimum lock.
    error LockBelowMinimum();
    /// @notice The relevant veCTM order (Listing/Offering) has been modified this block, potentially misleading others
    /// interacting with the order.
    error FlashProhibited();
    /// @notice The payment token provided is not supported as a valid medium of exchange in this marketplace.
    error InvalidPaymentToken();
    /// @notice The low-level call with msg.value failed.
    error EtherTransferFailed();

    /// @notice The order duration provided is below the minimum allowable order duration.
    error DurationBelowMinimum();

    /// @notice The bid made for an auction was less than the reserve price (this can occur when no-one has bid yet).
    error BidBelowReservePrice();
    /// @notice The bid made for an auction was more than the highest & reserve price, but not by the minimum increment.
    error BidIncrementBelowMinimum();
    /// @notice Auction has a status different from what is expected.
    error UnexpectedAuctionState(AuctionStatus);
    // BUG: I-2: Removed unused BidTooLow error
    // error BidTooLow();

    /// @notice Protocol contract addresses (voting escrow, governance, node properties, wrapped ether) were updated.
    event ProtocolContractsUpdated(address _ve, address _gov, address _np, address _weth);
    /// @notice Minimum duration for an order or an auction was updated.
    event MinimumDurationUpdated(uint256 _s);
    /// @notice A payment token was either added or removed to or from the whitelist.
    event PaymentTokenValidityUpdated(address indexed _paymentToken, bool indexed _newValidity);
    /// @notice Some or all of the fee limits and/or rates were updated.
    event FeesConfigured(
        uint256 _limitBlack,
        uint256 _limitGold,
        uint256 _limitSilver,
        uint256 _limitBronze,
        uint256 _limitBlue,
        uint256 _rateBlack,
        uint256 _rateGold,
        uint256 _rateSilver,
        uint256 _rateBronze,
        uint256 _rateBlue
    );

    /// @notice An order of type Listing was created by veCTM owner.
    event ListingCreated(
        uint256 indexed _tokenId,
        address indexed _listedBy,
        address indexed _paymentToken,
        uint256 _ask,
        uint256 _deadline
    );
    /// @notice An order of type Listing was fulfilled by a buyer.
    event ListingFulfilled(
        uint256 indexed _tokenId,
        address indexed _buyer,
        address indexed _seller,
        uint256 _ask,
        uint256 _netPrice,
        uint256 _fee
    );
    /// @notice An order of type Listing was delisted by the creator.
    event Delisted(uint256 indexed _tokenId);

    /// @notice An order of type Offering was created by a potential veCTM buyer.
    event OfferingCreated(
        uint256 indexed _tokenId,
        address indexed _offeredBy,
        address indexed _paymentToken,
        uint256 _bid,
        uint256 _deadline
    );
    /// @notice An order of type Offering was fulfilled by an owner.
    event OfferingFulfilled(
        uint256 indexed _tokenId,
        address indexed _buyer,
        address indexed _seller,
        uint256 _bid,
        uint256 _netPrice,
        uint256 _fee
    );
    /// @notice An order of type Offering was rescinded by the creator.
    event Rescinded(uint256 indexed _tokenId);

    /// @notice An auction was started by a veCTM owner.
    event AuctionCreated(
        uint256 indexed _tokenId,
        address indexed _createdBy,
        address indexed _paymentToken,
        uint256 _reservePrice,
        uint256 _minimumBidIncrement,
        uint256 _deadline
    );
    /// @notice An auction was canceled by an initiator, but no valid offers were made.
    event AuctionCanceled(uint256 indexed _tokenId, address indexed _seller);
    /// @notice A valid bid was made on an auction.
    event AuctionBid(uint256 indexed _tokenId, address indexed _seller, address indexed _buyer, uint256 _price);
    /// @notice An auction was settled; this can be largely categorized as Sold, Canceled or Expired.
    event AuctionSettled(uint256 indexed _tokenId, address indexed _seller, AuctionStatus indexed _finalStatus);
    /// @notice An auction was successful; veCTM was transferred to buyer, funds were transferred to seller.
    event AuctionSuccessful(
        uint256 indexed _tokenId,
        address indexed _seller,
        address indexed _buyer,
        uint256 _price,
        uint256 _fee,
        uint256 _net
    );

    event NFTTransferTreasuryFallback(address indexed _failedReceiver, uint256 indexed _tokenId);
    event ETHTransferTreasuryFallback(address indexed _failedReceiver, uint256 _amount);

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

    /// @notice The blueprint for an auction.
    struct Auction {
        uint256 reservePrice;
        uint256 minimumBidIncrement;
        uint256 deadline;
        address seller;
        address paymentToken;
        address highestBidder;
        uint256 highestBid;
        uint256 lockedAmount;
        AuctionStatus status;
    }

    /// @notice The minimum duration allowable for an order or an auction.
    uint256 public minimumDuration;

    /// @notice The voting escrow contract address, which is IERC721 compatible.
    address public ve;
    /// @notice The address allowed to make administrative modifications.
    address public gov;
    /// @notice The NodeProperties contract address, where veCTM tokens are attached to off-chain nodes.
    address public np;
    /// @notice The wrapped ether contract address, allowing IERC20 interface for ether.
    address public weth;

    /// @notice Whether or not a payment token address is valid.
    mapping(address _paymentToken => bool _isValid) public isValidPaymentToken;

    /// @notice The fee tier floor: each fee tier has a lower limit until which it is applicable.
    mapping(FeeTier _feeTier => uint256 _lowerLimit) public feeLimitByTier;
    /// @notice The fee rate (in bps) charged on a transaction by fee tier.
    mapping(FeeTier _feeTier => uint256 _rate) public feeRateByTier;

    // BUG: C-8: Changed to using mappings instead of arrays to prevent OOB while respecting 1-indexed accounting.
    /// @notice Listings storage for a veCTM token, past and present.
    mapping(uint256 _tokenId => mapping(uint256 _index => MarketOrder _listings)) public listingsByToken;
    /// @notice The number of listings in existence for a veCTM token.
    mapping(uint256 _tokenId => uint256 _n) public nListingsByToken;
    /// @notice The index of a listing for a particular veCTM token and owner.
    mapping(uint256 _tokenId => mapping(address _seller => uint256 _index)) public listingIndexByTokenSeller;

    // BUG: C-8: Changed to using mappings instead of arrays to prevent OOB while respecting 1-indexed accounting.
    /// @notice Offerings storage for a veCTM token, past and present.
    mapping(uint256 _tokenId => mapping(uint256 _index => MarketOrder _offerings)) public offeringsByToken;
    /// @notice The number of offerings in existence for a veCTM token.
    mapping(uint256 _tokenId => uint256 _n) public nOfferingsByToken;
    /// @notice The index of an offering for a particular veCTM token and owner.
    mapping(uint256 _tokenId => mapping(address _buyer => uint256 _index)) public offeringIndexByTokenBuyer;

    // BUG: C-8: Changed to using mappings instead of arrays to prevent OOB while respecting 1-indexed accounting.
    /// @notice Auctions storage for a veCTM token, past and present.
    mapping(uint256 _tokenId => mapping(uint256 _index => Auction _auctions)) public auctionsByToken;
    /// @notice The number of auctions in existence for a veCTM token.
    mapping(uint256 _tokenId => uint256 _n) public nAuctionsByToken;
    /// @notice The index of an auction for a particular veCTM token and owner.
    mapping(uint256 _tokenId => mapping(address _seller => uint256 _index)) public auctionIndexByTokenSeller;

    // BUG: I-3: Changed _flashStamp visibility from public to internal
    /// @notice The last block in which a particular veCTM token and account combination has interacted with the market.
    mapping(uint256 _tokenId => mapping(address _account => uint256 _blockNumber)) internal _flashStamp;

    /// @notice Modifier to enforce caller is governance.
    modifier onlyGov() {
        if (msg.sender != gov) revert OnlyGov();
        _;
    }

    /// @notice Modifier to enforce veCTM token and account combination has not interacted in the current block already.
    modifier flashStampTokenFor(uint256 _tokenId, address _account) {
        if (_flashStamp[_tokenId][_account] == block.number) revert FlashProhibited();
        _;
        _flashStamp[_tokenId][_account] = block.number;
    }

    /// @notice Modifier to enforce that the caller is or is not the owner of the relevant veCTM token.
    modifier ownerStatus(uint256 _tokenId, address _account, bool _expected) {
        bool isSender = IVotingEscrow(ve).ownerOf(_tokenId) == _account;
        if (_expected && !isSender) revert OnlyOwner();
        else if (!_expected && isSender) revert OnlyNonOwner();
        _;
    }

    /// @notice Modifier to enforce that the payment token is in the whitelist for the market.
    modifier validPaymentToken(address _paymentToken) {
        if (!isValidPaymentToken[_paymentToken]) revert InvalidPaymentToken();
        _;
    }

    /// @notice Modifier to enforce that the duration of the order/auction is not below the minimum allowable.
    modifier validDuration(uint256 _s) {
        if (_s < minimumDuration) revert DurationBelowMinimum();
        _;
    }

    /**
     * @notice Constructor for VotingEscrowMarketplace, setting protocol contracts and initial minimum duration.
     * @param _ve The address of the VotingEscrow NFT contract
     * @param _gov The address of governance, which will have administrative power
     * @param _np The address of the NodeProperties contract, in which KeyGen attachment is checked
     * @param _weth The address of the wrapped ether contract, which enables tokenized ether
     */
    constructor(address _ve, address _gov, address _np, address _weth, uint256 _minimumDuration) {
        _setProtocolContracts(_ve, _gov, _np, _weth);
        _setMinimumDuration(_minimumDuration);
    }

    /**
     * @notice Sets the protocol contracts for the marketplace.
     * @param _ve The address of the VotingEscrow NFT contract
     * @param _gov The address of governance, which will have administrative power
     * @param _np The address of the NodeProperties contract, in which KeyGen attachment is checked
     * @param _weth The address of the wrapped ether contract, which enables tokenized ether
     * NOTE: I-5: Governance is controlled by a DAO, therefore centralized trust is acceptable.
     */
    function setProtocolContracts(address _ve, address _gov, address _np, address _weth) external onlyGov {
        _setProtocolContracts(_ve, _gov, _np, _weth);
    }

    /**
     * @notice Sets the minimum duration that is allowable for a listing, offering or auction.
     * @param _s The duration in seconds
     * NOTE: I-5: Governance is controlled by a DAO, therefore centralized trust is acceptable.
     */
    function setMinimumDuration(uint256 _s) external onlyGov {
        _setMinimumDuration(_s);
    }

    /**
     * @notice Adds an ERC20 payment token to the whitelist, or removes it.
     * @param _paymentToken The address of the payment token to add or remove from the whitelist
     * @param _isValid True if adding to the whitelist, false if removing
     * NOTE: I-5: Governance is controlled by a DAO, therefore centralized trust is acceptable.
     */
    function setPaymentTokenValidity(address _paymentToken, bool _isValid) external onlyGov {
        if (isValidPaymentToken[_paymentToken] != _isValid) {
            isValidPaymentToken[_paymentToken] = _isValid;
            emit PaymentTokenValidityUpdated(_paymentToken, _isValid);
        }
    }

    /**
     * @notice Set the fee tier floor; the lower limit for that tier, as well as the rate (in bps) for that tier.
     * @param _limitsCTM An array of length 5 containing the lower limits, starting with the highest
     * @param _ratesBps An array of length 5 containing the corresponding rates (in bps) for each tier
     * NOTE: I-5: Governance is controlled by a DAO, therefore centralized trust is acceptable.
     * NOTE: I-12: Limits are in wei, not whole CTM
     */
    function configureFees(uint256[5] calldata _limitsCTM, uint256[5] calldata _ratesBps) external onlyGov {
        uint256 _lastTierLimit = _limitsCTM[0] + 1;
        for (uint8 i = 0; i < 5; i++) {
            // BUG: L-2: Prevented non-monotonic limits, zero limits and rates equal to or exceeding bps denominator
            // BUG: C-10: The mistaken check for _limitsCTM < 10_000 was changed to check _ratesBps < 10_000
            if (_limitsCTM[i] >= _lastTierLimit || _limitsCTM[i] == 0 || _ratesBps[i] >= 10_000) {
                revert InvalidFeeConfiguration();
            }
            _lastTierLimit = _limitsCTM[i];
            feeLimitByTier[FeeTier(i)] = _limitsCTM[i];
            feeRateByTier[FeeTier(i)] = _ratesBps[i];
        }
        // BUG: I-22: Emit event for fee configuration
        emit FeesConfigured(
            _limitsCTM[0],
            _limitsCTM[1],
            _limitsCTM[2],
            _limitsCTM[3],
            _limitsCTM[4],
            _ratesBps[0],
            _ratesBps[1],
            _ratesBps[2],
            _ratesBps[3],
            _ratesBps[4]
        );
    }

    /**
     * @notice Creates a listing for a token for a specified payment.
     * @param _tokenId The ID of the veCTM token owned by caller.
     * @param _paymentToken The address of the payment token requested by the caller; must be in the payment whitelist.
     * @param _ask The amount of the payment token the caller will accept for their token.
     * @param _listingDuration The duration of the listing, after which it is considered expired.
     */
    function createListing(uint256 _tokenId, address _paymentToken, uint256 _ask, uint256 _listingDuration)
        external
        ownerStatus(_tokenId, msg.sender, true)
        validPaymentToken(_paymentToken)
        validDuration(_listingDuration)
        flashStampTokenFor(_tokenId, msg.sender)
    {
        (uint256 _lockedAmount, uint256 _lockedEnd) = _snapshot(_tokenId);
        // BUG: H-3: Added delete for existing Open Listing
        uint256 _existingIndex = listingIndexByTokenSeller[_tokenId][msg.sender];
        if (_existingIndex != 0) {
            MarketOrder memory _marketOrder = listingsByToken[_tokenId][_existingIndex];
            if (_marketOrder.status == MarketOrderStatus.Open) {
                _deleteListingByTokenSeller(_tokenId, msg.sender, MarketOrderStatus.DelistedOrRescinded);
            }
        }
        uint256 _deadline = block.timestamp + _listingDuration;
        // BUG: M-1: Moved the '++' increment so that incremented value is returned, disabling index == 0
        uint256 _index = ++nListingsByToken[_tokenId];
        listingIndexByTokenSeller[_tokenId][msg.sender] = _index;
        // BUG: C-1: Changed array to mapping so that no OOB occurs
        listingsByToken[_tokenId][_index] = MarketOrder(
            _ask,
            _deadline,
            _lockedAmount,
            _lockedEnd,
            msg.sender,
            _paymentToken,
            MarketOrderStatus.Open,
            MarketOrderKind.Listing
        );
        emit ListingCreated(_tokenId, msg.sender, _paymentToken, _ask, _deadline);
    }

    /**
     * @notice Delists a token.
     * @param _tokenId The ID of the veCTM token that is currently listed, that should be delisted.
     */
    function delist(uint256 _tokenId)
        external
        ownerStatus(_tokenId, msg.sender, true)
        flashStampTokenFor(_tokenId, msg.sender)
    {
        // BUG: L-8: Added check for Listing state to ensure only Open Listings canceled
        uint256 _index = listingIndexByTokenSeller[_tokenId][msg.sender];
        MarketOrder memory _listing = listingsByToken[_tokenId][_index];
        if (_listing.status != MarketOrderStatus.Open) {
            revert UnexpectedMarketOrderState(MarketOrderStatus.Open, _listing.status);
        }
        _deleteListingByTokenSeller(_tokenId, msg.sender, MarketOrderStatus.DelistedOrRescinded);
        emit Delisted(_tokenId);
    }

    /**
     * @notice Fulfills an open listing, executing the exchange in one step.
     * @param _tokenId The ID of the veCTM token that is currently listed and that the caller wishes to buy.
     * @param _seller The address of the creator of the listing.
     * NOTE: C-11: It is safe to delete the Listing from storage because if the swap reverts, the storage write will be
     * undone.
     * BUG: I-7: Replaced instances of 'fulfil' (UK) with 'fulfill' (US)
     */
    function fulfillListing(uint256 _tokenId, address _seller)
        external
        payable
        ownerStatus(_tokenId, _seller, true)
        flashStampTokenFor(_tokenId, _seller)
        // BUG: M-4: Added reentrancy guard to fulfillListing
        nonReentrant
    {
        uint256 _index = listingIndexByTokenSeller[_tokenId][_seller];
        MarketOrder memory _listing = listingsByToken[_tokenId][_index];
        // BUG: M-6: Added check for supplied seller
        if (_listing.creator != _seller) revert OnlySeller();
        _deleteListingByTokenSeller(_tokenId, _seller, MarketOrderStatus.Fulfilled);
        (uint256 _lockedAmountNow, uint256 _lockedEndNow) = _snapshot(_tokenId);
        MarketOrderStatus _status = marketOrderStatus(_listing, _lockedAmountNow, _lockedEndNow, msg.sender, _tokenId);
        // BUG: M-8: If the payment token is WETH, status cannot be PaymentApprovalRequired
        if (_status != MarketOrderStatus.Open) revert UnexpectedMarketOrderState(MarketOrderStatus.Open, _status);
        (uint256 _fee, uint256 _net) =
            _executeTokenSwap(_tokenId, _lockedAmountNow, _listing.paymentToken, _listing.price, msg.sender, _seller);
        // BUG: L-1: Swapped _net and _fee in event emission order
        emit ListingFulfilled(_tokenId, msg.sender, _seller, _listing.price, _net, _fee);
    }

    /**
     * @notice Creates an offering for a token for a specified payment.
     * @param _tokenId The ID of the veCTM token desired by caller.
     * @param _paymentToken The address of the payment token requested by the caller; must be in the payment whitelist.
     * @param _bid The amount of the payment token the caller will pay for the token.
     * @param _offeringDuration The duration of the offering, after which it is considered expired.
     * NOTE: I-6: Bid funds are not locked at Offering creation, but enforced at swap time.
     */
    function createOffering(uint256 _tokenId, address _paymentToken, uint256 _bid, uint256 _offeringDuration)
        external
        // BUG: C-12: Added payable modifier
        payable
        ownerStatus(_tokenId, msg.sender, false)
        validPaymentToken(_paymentToken)
        validDuration(_offeringDuration)
        flashStampTokenFor(_tokenId, msg.sender)
    {
        (uint256 _lockedAmount, uint256 _lockedEnd) = _snapshot(_tokenId);
        // BUG: H-3: Added delete for existing Open Offering
        uint256 _existingIndex = offeringIndexByTokenBuyer[_tokenId][msg.sender];
        if (_existingIndex != 0) {
            MarketOrder memory _marketOrder = offeringsByToken[_tokenId][_existingIndex];
            if (_marketOrder.status == MarketOrderStatus.Open) {
                _deleteOfferingByTokenBuyer(_tokenId, msg.sender, MarketOrderStatus.DelistedOrRescinded);
            }
        }
        uint256 _deadline = block.timestamp + _offeringDuration;
        // BUG: M-1: Moved the '++' increment so that incremented value is returned, disabling index == 0
        uint256 _index = ++nOfferingsByToken[_tokenId];
        offeringIndexByTokenBuyer[_tokenId][msg.sender] = _index;
        // BUG: C-1: Changed array to mapping so that no OOB occurs
        offeringsByToken[_tokenId][_index] = MarketOrder(
            _bid,
            _deadline,
            _lockedAmount,
            _lockedEnd,
            msg.sender,
            _paymentToken,
            MarketOrderStatus.Open,
            MarketOrderKind.Offering
        );
        // BUG: C-9 & I-16: Create Offering wraps for the offeror, they must approve, then execute swap (from seller)
        // transfers the wrapped ether from them to contract, unwraps and transfers to seller (and fee to treasury)
        if (_paymentToken == weth) _wrapEtherFor(msg.sender, _bid);
        // BUG: M-9: Added revert for msg.value > 0 for non-ether Offerings
        else if (msg.value > 0) revert InvalidEtherAmount();
        emit OfferingCreated(_tokenId, msg.sender, _paymentToken, _bid, _deadline);
    }

    /**
     * @notice Rescinds an offer for a token.
     * @param _tokenId The ID of the veCTM token that is currently the subject of an offer, that should be rescinded.
     */
    function rescind(uint256 _tokenId) external flashStampTokenFor(_tokenId, msg.sender) {
        // BUG: L-8: Added check for Offering state to ensure only Open Offerings canceled
        uint256 _index = offeringIndexByTokenBuyer[_tokenId][msg.sender];
        MarketOrder memory _offering = offeringsByToken[_tokenId][_index];
        if (_offering.status != MarketOrderStatus.Open) {
            revert UnexpectedMarketOrderState(MarketOrderStatus.Open, _offering.status);
        }
        _deleteOfferingByTokenBuyer(_tokenId, msg.sender, MarketOrderStatus.DelistedOrRescinded);
        emit Rescinded(_tokenId);
    }

    /**
     * @notice Fulfills an open offering, executing the exchange in one step.
     * @param _tokenId The ID of the veCTM token that is subject of the offer being accepted.
     * @param _buyer The address of the creator of the offering.
     * BUG: C-6: Added payable modifier
     * NOTE: C-11: It is safe to delete the Listing from storage because if the swap reverts, the storage write will be
     * undone.
     * BUG: I-7: Replaced instances of 'fulfil' (UK) with 'fulfill' (US)
     */
    function fulfillOffering(uint256 _tokenId, address _buyer)
        external
        payable
        ownerStatus(_tokenId, msg.sender, true)
        flashStampTokenFor(_tokenId, _buyer)
        // BUG: M-4: Added reentrancy guard to fulfillOffering
        nonReentrant
    {
        uint256 _index = offeringIndexByTokenBuyer[_tokenId][_buyer];
        MarketOrder memory _offering = offeringsByToken[_tokenId][_index];
        // BUG: M-6: Added check for supplied buyer
        if (_offering.creator != _buyer) revert OnlyBuyer();
        _deleteOfferingByTokenBuyer(_tokenId, _buyer, MarketOrderStatus.Fulfilled);
        (uint256 _lockedAmountNow, uint256 _lockedEndNow) = _snapshot(_tokenId);
        MarketOrderStatus _status =
            marketOrderStatus(_offering, _lockedAmountNow, _lockedEndNow, _offering.creator, _tokenId);
        if (_status != MarketOrderStatus.Open) revert UnexpectedMarketOrderState(MarketOrderStatus.Open, _status);
        (uint256 _fee, uint256 _net) =
            _executeTokenSwap(_tokenId, _lockedAmountNow, _offering.paymentToken, _offering.price, _buyer, msg.sender);
        // BUG: L-1: Swapped _net and _fee in event emission order
        emit OfferingFulfilled(_tokenId, _buyer, msg.sender, _offering.price, _net, _fee);
    }

    /**
     * @notice Create a new auction for a token, with a floor price and minimum bid increment.
     * @param _tokenId The ID of the veCTM owned by caller.
     * @param _paymentToken The address of the payment token the bids will be made in.
     * @param _auctionDuration The duration of the auction, after which it is considered expired.
     * @param _reservePrice The starting (floor) price for the auction.
     * @param _minimumBidIncrement The smallest possible increment in highest offer between bids.
     */
    function createAuction(
        uint256 _tokenId,
        address _paymentToken,
        uint48 _auctionDuration,
        uint256 _reservePrice,
        uint256 _minimumBidIncrement
    )
        external
        ownerStatus(_tokenId, msg.sender, true)
        validPaymentToken(_paymentToken)
        validDuration(_auctionDuration)
        // BUG: I-3: Removed flash stamp for createAuction
        // flashStampTokenFor(_tokenId, msg.sender)

    {
        // BUG: M-7: Added delete for existing Open Listing
        uint256 _existingIndex = listingIndexByTokenSeller[_tokenId][msg.sender];
        if (_existingIndex != 0) {
            MarketOrder memory _marketOrder = listingsByToken[_tokenId][_existingIndex];
            if (_marketOrder.status == MarketOrderStatus.Open) {
                _deleteListingByTokenSeller(_tokenId, msg.sender, MarketOrderStatus.DelistedOrRescinded);
            }
        }
        // BUG: M-3: Added check for node attachment in createAuction
        if (INodeProperties(np).attachedKeyGen(_tokenId) != address(0)) revert KeyGenAttached();
        uint256 _deadline = block.timestamp + _auctionDuration;
        // BUG: M-1: Moved the '++' increment so that incremented value is returned, disabling index == 0
        uint256 _index = ++nAuctionsByToken[_tokenId];
        auctionIndexByTokenSeller[_tokenId][msg.sender] = _index;
        (uint256 _lockedAmount,) = _snapshot(_tokenId);
        // BUG: C-1: Changed array to mapping so that no OOB occurs
        auctionsByToken[_tokenId][_index] = Auction(
            _reservePrice,
            _minimumBidIncrement,
            _deadline,
            msg.sender,
            _paymentToken,
            address(0),
            0,
            _lockedAmount,
            AuctionStatus.Pending
        );
        _transferToken(msg.sender, address(this), _tokenId);
        emit AuctionCreated(_tokenId, msg.sender, _paymentToken, _reservePrice, _minimumBidIncrement, _deadline);
    }

    /**
     * @notice Cancel an active auction which has been initiated but on which no valid bid has yet been made.
     * @param _tokenId The token ID of the veCTM up for auction
     * NOTE: M-3: Escrowed tokens cannot be attached to node.
     */
    function cancelAuction(uint256 _tokenId) external ownerStatus(_tokenId, address(this), true) {
        uint256 _index = auctionIndexByTokenSeller[_tokenId][msg.sender];
        Auction storage _auction = auctionsByToken[_tokenId][_index];
        // BUG: H-2: Added msg.sender check to prevent unrestricted cancel of auction with index == 0
        if (msg.sender != _auction.seller) revert OnlyOwner();
        AuctionStatus _status = auctionStatus(_auction);
        if (_status == AuctionStatus.Pending) {
            _auction.status = AuctionStatus.Canceled;
            // BUG: C-5: Canceled auctions refund the owner the escrowed token
            _transferToken(address(this), msg.sender, _tokenId);
            emit AuctionCanceled(_tokenId, msg.sender);
        } else {
            revert UnexpectedAuctionState(_status);
        }
    }

    /**
     * @notice Bid for a token that is currently up for auction.
     * @param _tokenId The ID of the veCTM currently up for auction.
     * @param _seller The address of the initiator of the auction.
     * @param _price The amount to offer for the token up for auction.
     * BUG: C-6: Added payable modifier
     * BUG: M-4: Added reentrancy guard to auctionBid
     * NOTE: M-3: Escrowed tokens cannot be attached to node.
     * NOTE: I-10: Flash stamping not required for auctions AFAIK
     */
    function auctionBid(uint256 _tokenId, address _seller, uint256 _price)
        external
        payable
        nonReentrant
        // BUG: I-3: Removed flash stamp for auctionBid
        // flashStampTokenFor(_tokenId, _seller)

    {
        uint256 _index = auctionIndexByTokenSeller[_tokenId][_seller];
        Auction storage _auction = auctionsByToken[_tokenId][_index];
        // BUG: L-9: Added _seller check
        if (_seller != _auction.seller) revert OnlyOwner();
        AuctionStatus _status = auctionStatus(_auction);
        if (_status != AuctionStatus.Pending && _status != AuctionStatus.Active) {
            revert UnexpectedAuctionState(_status);
        }
        if (_price < _auction.reservePrice) {
            revert BidBelowReservePrice();
            // BUG: L-4: Added check that the highest bid is non-zero before checking whether minimum bid increment is met
            // BUG: M-11: Modified '<=' to '<' so that highestBid + minimumBidIncrement is enough
        } else if (_auction.highestBid != 0 && _price < _auction.highestBid + _auction.minimumBidIncrement) {
            revert BidIncrementBelowMinimum();
        }
        _auction.highestBidder = msg.sender;
        _auction.highestBid = _price;
        _auction.status = AuctionStatus.Active;
        // BUG: I-21: Move _auction updates before refund for best CEI practices
        {
            address _refundee = _auction.highestBidder;
            uint256 _refundAmount = _auction.highestBid;
            // BUG: C-4: Previous highest bid is refunded to its bidder
            // BUG: H-5: The refund payment was moved to auctions that already have a bid
            if (_status == AuctionStatus.Active) {
                _transferPaymentOut(_auction.paymentToken, _refundee, _refundAmount);
            }
        }
        _transferPaymentIn(_auction.paymentToken, msg.sender, _price);
        emit AuctionBid(_tokenId, _seller, msg.sender, _price);
    }

    /**
     * @notice Settles an auction that has concluded. If successful, executes the transaction, if not refunds the owner.
     * @param _tokenId The token ID of the veCTM up for auction
     * @param _seller The address of the one who initiated the auction
     * NOTE: M-3: Escrowed tokens cannot be attached to node.
     * BUG: M-4 & M-5: Added reentrancy guard to settleAuction
     */
    function settleAuction(uint256 _tokenId, address _seller)
        external
        // BUG: I-3: Removed flash stamp for settleAuction
        // flashStampTokenFor(_tokenId, _seller)
        nonReentrant
    {
        uint256 _index = auctionIndexByTokenSeller[_tokenId][_seller];
        Auction storage _auction = auctionsByToken[_tokenId][_index];
        // BUG: L-9: Added _seller check
        if (_seller != _auction.seller) revert OnlyOwner();
        AuctionStatus _status = auctionStatus(_auction);
        if (_status == AuctionStatus.Pending) {
            revert UnexpectedAuctionState(_status);
        } else if (_status == AuctionStatus.Active) {
            revert UnexpectedAuctionState(_status);
        } else if (_auction.status != AuctionStatus.Expired && _status == AuctionStatus.Expired) {
            // BUG: L-5: Marked Expired auction as Expired to prevent future transfer attempts
            _auction.status = AuctionStatus.Expired;
            _transferToken(address(this), _auction.seller, _tokenId);
        } else if (_status == AuctionStatus.Complete) {
            // BUG: L-5: Marked Complete auction as Sold
            // BUG: L-6: Marked _status as Sold to ensure correct event AuctionSettled emission
            _auction.status = _status = AuctionStatus.Sold;
            // BUG: C-7: Removed the double-transfer of funds from bidder (see auctionBid)
            (uint256 _fee, uint256 _net) =
                _deductProtocolFee(_auction.paymentToken, _auction.lockedAmount, _auction.highestBid);
            _transferPaymentOut(_auction.paymentToken, _auction.seller, _net);
            _transferToken(address(this), _auction.highestBidder, _tokenId);
            emit AuctionSuccessful(_tokenId, _auction.seller, _auction.highestBidder, _auction.highestBid, _fee, _net);
        } else {
            // INFO: NonExistent/Canceled/Sold/Expired & previously settled
            revert UnexpectedAuctionState(_status);
        }
        emit AuctionSettled(_tokenId, _auction.seller, _status);
    }

    /**
     * @notice Get the auction status.
     * @param _auction The auction state
     * @dev Possible auction states include:
     * Sold: auction is marked as Sold when auction settles.
     * Canceled: auction is marked as Canceled when it happens.
     * Active: auction is marked as Active when first valid bid is made.
     * NonExistent: default status of an auction that was never actually created.
     * Pending: none of the above AND deadline not reached
     * Expired: none of the above AND deadline reached AND was Pending
     * Complete: none of the above AND deadline reached AND was Active
     * BUG: I-19: Changed visibility from internal to public to aid off-chain integrators
     * BUG: I-23: Updated comments' language to reflect actual check
     */
    function auctionStatus(Auction memory _auction) public view returns (AuctionStatus _status) {
        _status = _auction.status;
        if (_status != AuctionStatus.Sold && _status != AuctionStatus.Canceled && _status != AuctionStatus.NonExistent)
        {
            // BUG: C-3: Active no longer treated as terminal post deadline
            if (block.timestamp >= _auction.deadline) {
                if (_status == AuctionStatus.Active) _status = AuctionStatus.Complete;
                else if (_status == AuctionStatus.Pending) _status = AuctionStatus.Expired;
            }
        }
    }

    /**
     * @notice Executes the swap associated with a fulfilled Listing/Offering, transferring the token from the seller
     * to the buyer and transferring the payment from the buyer to the seller.
     * @param _tokenId The token ID of the veCTM relevant to this listing/offering
     * @param _lockedAmount The amount of CTM underlying the veCTM at swap time
     * @param _paymentToken The address of the payment token used
     * @param _paymentAmount The amount of the payment token agreed upon by buyer and seller
     * @param _buyer The address of the buyer
     * @param _seller The address of the seller
     */
    function _executeTokenSwap(
        uint256 _tokenId,
        uint256 _lockedAmount,
        address _paymentToken,
        uint256 _paymentAmount,
        address _buyer,
        address _seller
    ) internal returns (uint256, uint256) {
        _transferPaymentIn(_paymentToken, _buyer, _paymentAmount);
        (uint256 _fee, uint256 _net) = _deductProtocolFee(_paymentToken, _lockedAmount, _paymentAmount);
        _transferPaymentOut(_paymentToken, _seller, _net);
        _transferToken(_seller, _buyer, _tokenId);
        return (_fee, _net);
    }

    /**
     * @notice Get the order (Listing/Offering) status.
     * @param _marketOrder The order state
     * @param _lockedAmountNow The amount of CTM underlying the veCTM at swap time
     * @param _lockedEndNow The unlock time of the veCTM at swap time
     * @param _buyer The address of the buyer
     * @param _tokenId The token ID of the order in question
     * @dev Possible market order states include:
     *  NonExistent: default status of an order that was never actually created.
     *  Open: order has been created, not yet fulfilled or expired.
     *  Fulfilled: order has already been fulfilled (Listing or Offering accepted).
     *  Expired: order has surpassed its deadline without being fulfilled.
     *  DelistedOrRescinded: order has been canceled by its creator.
     *  LockAmountDecreased: order is invalidated due to owner decreasing the veCTM's underlying CTM since snapshot.
     *  LockEndIncreased: order is invalidated due to owner increasing the veCTM's unlock time since snapshot.
     *  TokenApprovalRequired: order requires the seller to approve the marketplace to transfer the veCTM.
     *  PaymentApprovalRequired: order requires the buyer to approve the marketplace to transfer the payment.
     *  KeyGenAttached: order cannot be fulfilled due to the veCTM in question being attached to a node.
     * BUG: I-19: Changed visibility from internal to public to aid off-chain integrators
     */
    function marketOrderStatus(
        MarketOrder memory _marketOrder,
        uint256 _lockedAmountNow,
        uint256 _lockedEndNow,
        address _buyer,
        uint256 _tokenId
    ) public view returns (MarketOrderStatus _status) {
        _status = _marketOrder.status;
        // BUG: I-4: Replaced 'if' with 'else if' to enforce one status only, Expired gets priority
        if (block.timestamp >= _marketOrder.deadline) {
            _status = MarketOrderStatus.Expired;
        } else if (INodeProperties(np).attachedKeyGen(_tokenId) != address(0)) {
            _status = MarketOrderStatus.KeyGenAttached;
        } else if (_marketOrder.snapshotAmount > _lockedAmountNow) {
            // BUG: H-1 & H-4: Revert with LockAmountDecreased instead of LockEndIncreased, corrected sign
            _status = MarketOrderStatus.LockAmountDecreased;
        } else if (_marketOrder.snapshotEnd < _lockedEndNow) {
            _status = MarketOrderStatus.LockEndIncreased;
        } else if (!IVotingEscrow(ve).isApprovedOrOwner(address(this), _tokenId)) {
            _status = MarketOrderStatus.TokenApprovalRequired;
        } else if (
            (_marketOrder.paymentToken != weth || _marketOrder.kind != MarketOrderKind.Listing)
                && IERC20(_marketOrder.paymentToken).allowance(_buyer, address(this)) < _marketOrder.price
        ) {
            // BUG: L-10 & I18: The only configuration of market order that does not need an approval check is
            // kind == Listing, and payment token == WETH. Anything else must be approval-enforced.
            // NOTE: C-9: When an Offering is created for ETH, the contract first wraps the ether and then transfers it
            // to the Offering party; this is to allow them to hold their WETH while the Offering is ongoing, instead of
            // having to escrow it. Therefore, an approval to later spend that WETH is required in the case the Offering
            // is fulfilled.
            _status = MarketOrderStatus.PaymentApprovalRequired;
        }
    }

    /**
     * @notice Calculates the fee tier that the veCTM is subject to, based on its underlying CTM amount.
     * @param _lockedAmount The amount of CTM underlying the veCTM
     */
    function calculateFeeTier(uint256 _lockedAmount) public view returns (FeeTier) {
        for (uint8 i = 0; i < 5; i++) {
            if (_lockedAmount >= feeLimitByTier[FeeTier(i)]) return FeeTier(i);
        }
        revert LockBelowMinimum();
    }

    /**
     * @notice Internal handler for setting the protocol contracts.
     * @param _ve The address of the VotingEscrow NFT contract
     * @param _gov The address of governance, which will have administrative power
     * @param _np The address of the NodeProperties contract, in which KeyGen attachment is checked
     * @param _weth The address of the wrapped ether contract, which enables tokenized ether
     */
    function _setProtocolContracts(address _ve, address _gov, address _np, address _weth) internal {
        ve = _ve;
        gov = _gov;
        np = _np;
        weth = _weth;
        emit ProtocolContractsUpdated(_ve, _gov, _np, _weth);
    }

    /**
     * @notice Internal handler for setting the minimum duration that is allowable for a listing, offering or auction.
     * @param _s The duration in seconds
     */
    function _setMinimumDuration(uint256 _s) internal {
        minimumDuration = _s;
        emit MinimumDurationUpdated(_s);
    }

    /**
     * @notice Deletes a Listing for a token ID and seller address. This deletes the most recent Listing made by the
     * given address for the given token ID.
     * @param _tokenId The ID of the veCTM in the Listing
     * @param _seller The address of the seller in the Listing
     */
    function _deleteListingByTokenSeller(uint256 _tokenId, address _seller, MarketOrderStatus _status) internal {
        uint256 _index = listingIndexByTokenSeller[_tokenId][_seller];
        delete listingIndexByTokenSeller[_tokenId][_seller];
        listingsByToken[_tokenId][_index].status = _status;
    }

    /**
     * @notice Deletes an Offering for a token ID and buyer address. This deletes the most recent Offering made by the
     * given address for the given token ID.
     * @param _tokenId The ID of the veCTM in the Offering
     * @param _buyer The address of the buyer in the Offering
     */
    function _deleteOfferingByTokenBuyer(uint256 _tokenId, address _buyer, MarketOrderStatus _status) internal {
        uint256 _index = offeringIndexByTokenBuyer[_tokenId][_buyer];
        delete offeringIndexByTokenBuyer[_tokenId][_buyer];
        offeringsByToken[_tokenId][_index].status = _status;
    }

    /**
     * @notice Calculates applicable fee tier and its rate based on a veCTM's underlying CTM locked, calculates the
     * payable fee from the gross payment and deducts this amount from the gross, transferring it to the treasury.
     * @param _paymentToken The address of the payment token in this transaction (already verified to be whitelisted)
     * @param _amount The underlying CTM locked in the veCTM token subjected to this transaction
     * @param _gross The ask/bid/agreed amount that was agreed upon by buyer and seller for this transaction
     */
    function _deductProtocolFee(address _paymentToken, uint256 _amount, uint256 _gross)
        internal
        returns (uint256 _feePayable, uint256 _netAmount)
    {
        FeeTier _feeTier = calculateFeeTier(_amount);
        uint256 _feeRate = feeRateByTier[_feeTier];
        _feePayable = _gross * _feeRate / 10_000;
        _netAmount = _gross - _feePayable;
        _transferPaymentOut(_paymentToken, gov, _feePayable);
    }

    /**
     * @notice Wraps a given amount of ether for a given account. Uses the official WETH9 contract on Linea.
     * @param _account The account which should receive the wrapped ether
     * @param _amount The amount of ether (from msg.value) to wrap
     */
    function _wrapEtherFor(address _account, uint256 _amount) internal {
        // BUG: I-20: Moved WETH deposit to before refund for best practice
        address _weth = weth;
        // BUG: C-6: Added msg object with value == _amount to WETH.deposit
        IWETH(_weth).deposit{value: _amount}();
        // BUG: C-12: Move the msg.value checks from _transferPaymentIn to _wrapEtherFor to fix createOffering
        // NOTE: we only transfer unwrapped ether in; no wrapped ether
        if (msg.value < _amount) revert InvalidEtherAmount();
        // BUG: L-3: Changed ether transfer to call
        if (msg.value > _amount) {
            uint256 _excess = msg.value - _amount;
            (bool success,) = msg.sender.call{value: _excess}("");
            // BUG: M-12: Added fallback to divert excess funds to treasury in case msg.sender has receive() reversion
            if (!success) {
                (success,) = gov.call{value: _excess}("");
                emit ETHTransferTreasuryFallback(msg.sender, _excess);
            }
        }
        if (_account != address(this)) {
            // BUG: L-12: Change from transfer to safeTransfer
            IERC20(_weth).safeTransfer(_account, _amount);
        }
    }

    /**
     * @notice Unwraps a given amount of wrapped ether for a given account. Uses the official WETH9 contract on Linea.
     * @param _account The account which should receive the unwrapped ether
     * @param _amount The amount of ether to unwrap
     */
    function _unwrapEtherFor(address _account, uint256 _amount) internal {
        address _weth = weth;
        IWETH(_weth).withdraw(_amount);
        if (_account != address(this)) {
            // BUG: L-3: Changed ether transfer to call
            (bool success,) = _account.call{value: _amount}("");
            // BUG: M-12: Added fallback to divert excess funds to treasury in case _account has receive() reversion
            if (!success) {
                (success,) = gov.call{value: _amount}("");
                emit ETHTransferTreasuryFallback(_account, _amount);
            }
        }
    }

    /**
     * @notice Transfers a given amount of a given payment token from a given account to this contract. If the WETH
     * address is provided as the payment token, wraps msg.value for the contract.
     * @param _paymentToken The address of the payment token to transfer from the provided account's balance
     * @param _from The address of the account to debit the amount of payment token
     * @param _amount The amount of payment token to debit the account
     */
    function _transferPaymentIn(address _paymentToken, address _from, uint256 _amount) internal {
        address _weth = weth;
        // BUG: C-9: Added a check for _from == msg.sender to prevent fulfillOffering double-wrapping the payment. With
        // this configuration, when the buyer creates the Offering, their ether gets wrapped and transferred to them.
        // When the seller fulfills the Offering, the WETH gets transferred from the buyer's balance to the seller.
        if (_paymentToken == _weth && _from == msg.sender) {
            _wrapEtherFor(address(this), _amount);
        } else {
            // BUG: M-2: Added check to prevent accidental ether being transferred in
            if (msg.value > 0) revert InvalidEtherAmount();
            IERC20(_paymentToken).safeTransferFrom(_from, address(this), _amount);
        }
    }

    /**
     * @notice Transfers a given amount of a given payment token from this contract to a given account. If the WETH
     * address is provided as the payment token, unwraps to the credited account.
     * @param _paymentToken The address of the payment token to transfer to the provided account's balance
     * @param _to The address of the account to credit the amount of payment token
     * @param _amount The amount of payment token to credit the account
     */
    function _transferPaymentOut(address _paymentToken, address _to, uint256 _amount) internal {
        address _weth = weth;
        if (_paymentToken == _weth) {
            // NOTE: we only transfer unwrapped ether out; no wrapped ether
            // BUG: C-13: Added verification that sends to DAO in case of recipient malfeasance regarding receive().
            // Transfer to the DAO is guaranteed to work.
            _unwrapEtherFor(_to, _amount);
        } else {
            IERC20(_paymentToken).safeTransfer(_to, _amount);
        }
    }

    /**
     * @notice Transfers a given token ID of veCTM between two given accounts.
     * @param _from The account to transfer the veCTM from
     * @param _to The account to transfer the veCTM to
     * @param _tokenId The ID of the veCTM to transfer
     */
    function _transferToken(address _from, address _to, uint256 _tokenId) internal {
        // BUG: M-10: Added verification that sends to DAO in case of recipient malfeasance regarding
        // onERC721Received(). Transfer to the DAO is guaranteed to work.
        (bool success,) =
            ve.call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", _from, _to, _tokenId));
        if (!success) IVotingEscrow(ve).safeTransferFrom(_from, gov, _tokenId);
    }

    /**
     * @notice Takes a snapshot of a veCTM token with regards to its underlying locked CTM and its unlock time.
     * @param _tokenId The ID of the veCTM token to snapshot
     * NOTE: L-11: While the locked amount is saved as int128, it cannot be negative, nor can it be less than 1 ether.
     */
    function _snapshot(uint256 _tokenId) internal view returns (uint256, uint256) {
        (int128 _lockedAmountInt128, uint256 _lockedEnd) = IVotingEscrow(ve).locked(_tokenId);
        uint256 _lockedAmount = uint256(int256(_lockedAmountInt128));
        return (_lockedAmount, _lockedEnd);
    }

    // BUG: I-1: Removed unused _validateSnapshot
    // /**
    //  * @notice Validates the current snapshot of a veCTM token against a previous one. Reverts if the current snapshot
    //  * has either decreased in locked CTM or increased in unlock time. This is to prevent misleading of buyers.
    //  * @param _tokenId The ID of the veCTM token to validate present and past snapshots
    //  * @param _minAmount The underlying locked CTM amount in the reference snapshot, which acts as the minimum allowed
    //  * @param _maxEnd The unlock time in the reference snapshot, which acts as the maximum allowed
    //  */
    // function _validateSnapshot(uint256 _tokenId, uint256 _minAmount, uint256 _maxEnd) internal view {
    //     (uint256 _lockedAmount, uint256 _lockedEnd) = _snapshot(_tokenId);
    //     if (_minAmount > _lockedAmount) revert LockAmountDecreased();
    //     if (_maxEnd < _lockedEnd) revert LockEndIncreased();
    // }

    /**
     * @notice Implementation of IERC721Receiver.onERC721Received to allow safeTransferFrom with this contract as the
     * receiver.
     * BUG: C-2: Added onERC721Received so that safeTransferFrom doesn't revert
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        // BUG: L-7: Added check that this is only called from VotingEscrow (via safeTransferFrom)
        if (msg.sender != ve) revert OnlyVotingEscrow();
        return this.onERC721Received.selector;
    }

    // BUG: C-6: Added receive function to allow withdrawal/unwrapping of ether
    // NOTE: I-11: Acknowledged that receive is unrestricted - ether should not be sent to the contract outside of
    // payable functions.
    receive() external payable {}
}
