// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {MarketplaceBase} from "./MarketplaceBase.sol";
import {VotingEscrowMarketplace} from "../src/VotingEscrowMarketplace.sol";
import {IVotingEscrowMarketplace} from "../src/IVotingEscrowMarketplace.sol";

contract AuctionTest is MarketplaceBase {
    uint256 internal constant RESERVE = 5 ether;
    uint256 internal constant INCREMENT = 1 ether;

    function test_createAuctionEscrowsNftAndStoresPendingAuction() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.AuctionCreated(
            tokenId, seller, address(usdc), RESERVE, INCREMENT, block.timestamp + ORDER_DURATION
        );

        _createAuction(seller, tokenId, address(usdc), RESERVE, INCREMENT);

        assertEq(ve.ownerOf(tokenId), address(market));
        assertEq(market.nAuctionsByToken(tokenId), 1);
        assertEq(market.auctionIndexByTokenSeller(tokenId, seller), 1);

        IVotingEscrowMarketplace.Auction memory auction = _auction(tokenId, 1);
        assertEq(auction.reservePrice, RESERVE);
        assertEq(auction.minimumBidIncrement, INCREMENT);
        assertEq(auction.deadline, block.timestamp + ORDER_DURATION);
        assertEq(auction.seller, seller);
        assertEq(auction.paymentToken, address(usdc));
        assertEq(auction.highestBidder, address(0));
        assertEq(auction.highestBid, 0);
        assertEq(uint256(auction.status), uint256(IVotingEscrowMarketplace.AuctionStatus.Pending));
    }

    function test_createAuctionDelistsExistingOpenListing() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(usdc), PRICE);
        _approveVe(seller, tokenId);

        _createAuction(seller, tokenId, address(usdc), RESERVE, INCREMENT);

        assertEq(market.listingIndexByTokenSeller(tokenId, seller), 0);
        assertEq(
            uint256(_listing(tokenId, 1).status),
            uint256(IVotingEscrowMarketplace.MarketOrderStatus.DelistedOrRescinded)
        );
        assertEq(ve.ownerOf(tokenId), address(market));
    }

    function test_cancelPendingAuctionReturnsNftToSeller() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);
        _createAuction(seller, tokenId, address(usdc), RESERVE, INCREMENT);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.AuctionCanceled(tokenId, seller);

        vm.prank(seller);
        market.cancelAuction(tokenId);

        assertEq(ve.ownerOf(tokenId), seller);
        assertEq(uint256(_auction(tokenId, 1).status), uint256(IVotingEscrowMarketplace.AuctionStatus.Canceled));
    }

    function test_firstBidActivatesAuctionAndEscrowsPayment() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);
        _createAuction(seller, tokenId, address(usdc), RESERVE, INCREMENT);
        _approveUsdc(buyer, RESERVE);

        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.AuctionBid(tokenId, seller, buyer, RESERVE);

        vm.prank(buyer);
        market.auctionBid(tokenId, seller, RESERVE);

        IVotingEscrowMarketplace.Auction memory auction = _auction(tokenId, 1);
        assertEq(auction.highestBidder, buyer);
        assertEq(auction.highestBid, RESERVE);
        assertEq(uint256(auction.status), uint256(IVotingEscrowMarketplace.AuctionStatus.Active));
        assertEq(usdc.balanceOf(buyer), buyerBefore - RESERVE);
        assertEq(usdc.balanceOf(address(market)), RESERVE);
        assertEq(ve.ownerOf(tokenId), address(market));
    }

    function test_outbidRefundsPreviousBidderAndEscrowsNewBid() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);
        _createAuction(seller, tokenId, address(usdc), RESERVE, INCREMENT);

        _approveUsdc(buyer, RESERVE);
        vm.prank(buyer);
        market.auctionBid(tokenId, seller, RESERVE);

        uint256 higherBid = RESERVE + INCREMENT;
        _approveUsdc(bidder, higherBid);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 bidderBefore = usdc.balanceOf(bidder);

        vm.prank(bidder);
        market.auctionBid(tokenId, seller, higherBid);

        IVotingEscrowMarketplace.Auction memory auction = _auction(tokenId, 1);
        assertEq(auction.highestBidder, bidder);
        assertEq(auction.highestBid, higherBid);
        assertEq(usdc.balanceOf(buyer), buyerBefore + RESERVE);
        assertEq(usdc.balanceOf(bidder), bidderBefore - higherBid);
        assertEq(usdc.balanceOf(address(market)), higherBid);
    }

    function test_settleSuccessfulAuctionPaysSellerAndTransfersNft() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);
        _createAuction(seller, tokenId, address(usdc), RESERVE, INCREMENT);

        _approveUsdc(buyer, RESERVE);
        vm.prank(buyer);
        market.auctionBid(tokenId, seller, RESERVE);

        vm.warp(block.timestamp + ORDER_DURATION);

        (uint256 fee, uint256 net) = _feeAndNet(DEFAULT_LOCK_AMOUNT, RESERVE);
        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 govBefore = usdc.balanceOf(gov);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.AuctionSuccessful(tokenId, seller, buyer, RESERVE, fee, net);
        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.AuctionSettled(tokenId, seller, IVotingEscrowMarketplace.AuctionStatus.Sold);

        market.settleAuction(tokenId, seller);

        assertEq(ve.ownerOf(tokenId), buyer);
        assertEq(usdc.balanceOf(seller), sellerBefore + net);
        assertEq(usdc.balanceOf(gov), govBefore + fee);
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(uint256(_auction(tokenId, 1).status), uint256(IVotingEscrowMarketplace.AuctionStatus.Sold));
    }

    function test_settleExpiredAuctionReturnsNftToSeller() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);
        _createAuction(seller, tokenId, address(usdc), RESERVE, INCREMENT);

        vm.warp(block.timestamp + ORDER_DURATION);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.AuctionSettled(tokenId, seller, IVotingEscrowMarketplace.AuctionStatus.Expired);

        market.settleAuction(tokenId, seller);

        assertEq(ve.ownerOf(tokenId), seller);
        assertEq(uint256(_auction(tokenId, 1).status), uint256(IVotingEscrowMarketplace.AuctionStatus.Expired));
    }

    function test_etherAuctionBidOutbidAndSettle() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);
        _createAuction(seller, tokenId, address(weth), RESERVE, INCREMENT);

        uint256 buyerEthBefore = buyer.balance;
        vm.prank(buyer);
        market.auctionBid{value: RESERVE}(tokenId, seller, RESERVE);
        assertEq(buyer.balance, buyerEthBefore - RESERVE);

        uint256 higherBid = RESERVE + INCREMENT;
        uint256 bidderEthBefore = bidder.balance;
        vm.prank(bidder);
        market.auctionBid{value: higherBid}(tokenId, seller, higherBid);

        assertEq(buyer.balance, buyerEthBefore);
        assertEq(bidder.balance, bidderEthBefore - higherBid);

        vm.warp(block.timestamp + ORDER_DURATION);

        (uint256 fee, uint256 net) = _feeAndNet(DEFAULT_LOCK_AMOUNT, higherBid);
        uint256 sellerBefore = seller.balance;
        uint256 govBefore = gov.balance;

        market.settleAuction(tokenId, seller);

        assertEq(ve.ownerOf(tokenId), bidder);
        assertEq(seller.balance, sellerBefore + net);
        assertEq(gov.balance, govBefore + fee);
        assertEq(address(market).balance, 0);
        assertEq(weth.balanceOf(address(market)), 0);
    }

    function test_createAuctionAcceptsMinimumAndMaximumDurations() public {
        uint256 tokenIdMin = _mintVe(seller);
        _approveVe(seller, tokenIdMin);
        vm.prank(seller);
        market.createAuction(tokenIdMin, address(usdc), uint48(MIN_DURATION), RESERVE, INCREMENT);
        assertEq(_auction(tokenIdMin, 1).deadline, block.timestamp + MIN_DURATION);

        uint256 tokenIdMax = _mintVe(seller);
        _approveVe(seller, tokenIdMax);
        vm.prank(seller);
        market.createAuction(tokenIdMax, address(usdc), uint48(MAX_DURATION), RESERVE, INCREMENT);
        assertEq(_auction(tokenIdMax, 1).deadline, block.timestamp + MAX_DURATION);
    }

    function test_newOwnerCanAuctionAfterPurchase() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);
        _createAuction(seller, tokenId, address(usdc), RESERVE, INCREMENT);

        _approveUsdc(buyer, RESERVE);
        vm.prank(buyer);
        market.auctionBid(tokenId, seller, RESERVE);

        vm.warp(block.timestamp + ORDER_DURATION);
        market.settleAuction(tokenId, seller);

        _approveVe(buyer, tokenId);
        vm.prank(buyer);
        market.createAuction(tokenId, address(usdc), uint48(ORDER_DURATION), RESERVE, INCREMENT);

        assertEq(ve.ownerOf(tokenId), address(market));
        assertEq(market.nAuctionsByToken(tokenId), 2);
        assertEq(market.auctionIndexByTokenSeller(tokenId, buyer), 2);
        assertEq(uint256(_auction(tokenId, 2).status), uint256(IVotingEscrowMarketplace.AuctionStatus.Pending));
    }
}
