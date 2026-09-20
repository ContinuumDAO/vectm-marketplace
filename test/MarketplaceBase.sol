// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";

import {VotingEscrowMarketplace} from "../src/VotingEscrowMarketplace.sol";
import {IVotingEscrowMarketplace} from "../src/IVotingEscrowMarketplace.sol";

import {MockVotingEscrow} from "./mocks/MockVotingEscrow.sol";
import {MockNodeProperties} from "./mocks/MockNodeProperties.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

abstract contract MarketplaceBase is Test {
    uint256 internal constant MIN_DURATION = 1 days;
    uint256 internal constant MAX_DURATION = 30 days;
    uint256 internal constant ORDER_DURATION = 7 days;
    uint256 internal constant DEFAULT_LOCK_AMOUNT = 100_000 ether;
    uint256 internal constant PRICE = 10 ether;

    uint256 internal constant LIMIT_BLACK = 1_000_000 ether;
    uint256 internal constant LIMIT_GOLD = 500_000 ether;
    uint256 internal constant LIMIT_SILVER = 200_000 ether;
    uint256 internal constant LIMIT_BRONZE = 50_000 ether;
    uint256 internal constant LIMIT_BLUE = 1 ether;

    uint256 internal constant RATE_BLACK = 250;
    uint256 internal constant RATE_GOLD = 200;
    uint256 internal constant RATE_SILVER = 150;
    uint256 internal constant RATE_BRONZE = 100;
    uint256 internal constant RATE_BLUE = 50;

    VotingEscrowMarketplace internal market;
    MockVotingEscrow internal ve;
    MockNodeProperties internal np;
    MockWETH internal weth;
    MockERC20 internal usdc;

    address internal gov;
    address internal seller;
    address internal buyer;
    address internal bidder;

    uint256 internal nextTokenId = 1;

    function setUp() public virtual {
        gov = makeAddr("gov");
        seller = makeAddr("seller");
        buyer = makeAddr("buyer");
        bidder = makeAddr("bidder");

        ve = new MockVotingEscrow();
        np = new MockNodeProperties();
        weth = new MockWETH();
        usdc = new MockERC20("USD Coin", "USDC");

        market = new VotingEscrowMarketplace(address(ve), gov, address(np), address(weth), MIN_DURATION, MAX_DURATION);

        vm.startPrank(gov);
        market.setPaymentTokenValidity(address(usdc), true);
        market.setPaymentTokenValidity(address(weth), true);
        market.configureFees(
            [LIMIT_BLACK, LIMIT_GOLD, LIMIT_SILVER, LIMIT_BRONZE, LIMIT_BLUE],
            [RATE_BLACK, RATE_GOLD, RATE_SILVER, RATE_BRONZE, RATE_BLUE]
        );
        vm.stopPrank();

        vm.deal(seller, 1_000 ether);
        vm.deal(buyer, 1_000 ether);
        vm.deal(bidder, 1_000 ether);
        vm.deal(gov, 0);

        usdc.mint(buyer, 1_000_000 ether);
        usdc.mint(bidder, 1_000_000 ether);
        usdc.mint(seller, 1_000_000 ether);
    }

    function _mintVe(address to, uint256 lockedAmount) internal returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        uint256 unlockTime = block.timestamp + 365 days;
        ve.mint(to, tokenId, int128(int256(lockedAmount)), unlockTime);
    }

    function _mintVe(address to) internal returns (uint256 tokenId) {
        tokenId = _mintVe(to, DEFAULT_LOCK_AMOUNT);
    }

    function _approveVe(address owner, uint256 tokenId) internal {
        vm.prank(owner);
        ve.approve(address(market), tokenId);
    }

    function _approveUsdc(address owner, uint256 amount) internal {
        vm.prank(owner);
        usdc.approve(address(market), amount);
    }

    function _approveWeth(address owner, uint256 amount) internal {
        vm.prank(owner);
        weth.approve(address(market), amount);
    }

    function _createListing(address from, uint256 tokenId, address paymentToken, uint256 ask) internal {
        vm.prank(from);
        market.createListing(tokenId, paymentToken, ask, ORDER_DURATION);
    }

    function _createOffering(address from, uint256 tokenId, address paymentToken, uint256 bid) internal {
        vm.prank(from);
        market.createOffering(tokenId, paymentToken, bid, ORDER_DURATION);
    }

    function _createOfferingEth(address from, uint256 tokenId, uint256 bid, uint256 value) internal {
        vm.prank(from);
        market.createOffering{value: value}(tokenId, address(weth), bid, ORDER_DURATION);
    }

    function _createAuction(address from, uint256 tokenId, address paymentToken, uint256 reserve, uint256 increment)
        internal
    {
        vm.prank(from);
        market.createAuction(tokenId, paymentToken, uint48(ORDER_DURATION), reserve, increment);
    }

    function _feeAndNet(uint256 lockedAmount, uint256 gross) internal view returns (uint256 fee, uint256 net) {
        IVotingEscrowMarketplace.FeeTier tier = market.calculateFeeTier(lockedAmount);
        fee = gross * market.feeRateByTier(tier) / 10_000;
        net = gross - fee;
    }

    function _listing(uint256 tokenId, uint256 index)
        internal
        view
        returns (IVotingEscrowMarketplace.MarketOrder memory order)
    {
        (
            order.price,
            order.deadline,
            order.snapshotAmount,
            order.snapshotEnd,
            order.creator,
            order.paymentToken,
            order.status,
            order.kind
        ) = market.listingsByToken(tokenId, index);
    }

    function _offering(uint256 tokenId, uint256 index)
        internal
        view
        returns (IVotingEscrowMarketplace.MarketOrder memory order)
    {
        (
            order.price,
            order.deadline,
            order.snapshotAmount,
            order.snapshotEnd,
            order.creator,
            order.paymentToken,
            order.status,
            order.kind
        ) = market.offeringsByToken(tokenId, index);
    }

    function _auction(uint256 tokenId, uint256 index)
        internal
        view
        returns (IVotingEscrowMarketplace.Auction memory auction)
    {
        (
            auction.reservePrice,
            auction.minimumBidIncrement,
            auction.deadline,
            auction.seller,
            auction.paymentToken,
            auction.highestBidder,
            auction.highestBid,
            auction.status
        ) = market.auctionsByToken(tokenId, index);
    }
}
