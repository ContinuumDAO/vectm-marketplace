// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {MarketplaceBase} from "./MarketplaceBase.sol";
import {VotingEscrowMarketplace} from "../src/VotingEscrowMarketplace.sol";
import {IVotingEscrowMarketplace} from "../src/IVotingEscrowMarketplace.sol";

contract ListingTest is MarketplaceBase {
    function test_createListingStoresOpenOrderAndSnapshotsLock() public {
        uint256 tokenId = _mintVe(seller);
        (int128 lockedAmount, uint256 lockedEnd) = ve.locked(tokenId);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.ListingCreated(
            tokenId, seller, address(usdc), PRICE, block.timestamp + ORDER_DURATION
        );

        _createListing(seller, tokenId, address(usdc), PRICE);

        assertEq(market.nListingsByToken(tokenId), 1);
        assertEq(market.listingIndexByTokenSeller(tokenId, seller), 1);

        IVotingEscrowMarketplace.MarketOrder memory listing = _listing(tokenId, 1);
        assertEq(listing.price, PRICE);
        assertEq(listing.deadline, block.timestamp + ORDER_DURATION);
        assertEq(listing.snapshotAmount, uint256(int256(lockedAmount)));
        assertEq(listing.snapshotEnd, lockedEnd);
        assertEq(listing.creator, seller);
        assertEq(listing.paymentToken, address(usdc));
        assertEq(uint256(listing.status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
        assertEq(uint256(listing.kind), uint256(IVotingEscrowMarketplace.MarketOrderKind.Listing));
    }

    function test_createListingReplacesExistingOpenListing() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(usdc), PRICE);

        uint256 newAsk = PRICE * 2;
        _createListing(seller, tokenId, address(usdc), newAsk);

        IVotingEscrowMarketplace.MarketOrder memory previous = _listing(tokenId, 1);
        assertEq(uint256(previous.status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.DelistedOrRescinded));

        assertEq(market.nListingsByToken(tokenId), 2);
        assertEq(market.listingIndexByTokenSeller(tokenId, seller), 2);

        IVotingEscrowMarketplace.MarketOrder memory current = _listing(tokenId, 2);
        assertEq(current.price, newAsk);
        assertEq(uint256(current.status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
    }

    function test_delistMarksListingRescindedAndClearsIndex() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(usdc), PRICE);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.Delisted(tokenId);

        vm.prank(seller);
        market.delist(tokenId);

        assertEq(market.listingIndexByTokenSeller(tokenId, seller), 0);
        IVotingEscrowMarketplace.MarketOrder memory listing = _listing(tokenId, 1);
        assertEq(uint256(listing.status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.DelistedOrRescinded));
        assertEq(ve.ownerOf(tokenId), seller);
    }

    function test_fulfillListingWithErc20PaysSellerFeeAndTransfersNft() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(usdc), PRICE);
        _approveVe(seller, tokenId);
        _approveUsdc(buyer, PRICE);

        (uint256 fee, uint256 net) = _feeAndNet(DEFAULT_LOCK_AMOUNT, PRICE);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 govBefore = usdc.balanceOf(gov);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.ListingFulfilled(tokenId, buyer, seller, PRICE, net, fee);

        vm.prank(buyer);
        market.fulfillListing(tokenId, seller, address(usdc), PRICE);

        assertEq(ve.ownerOf(tokenId), buyer);
        assertEq(usdc.balanceOf(buyer), buyerBefore - PRICE);
        assertEq(usdc.balanceOf(seller), sellerBefore + net);
        assertEq(usdc.balanceOf(gov), govBefore + fee);
        assertEq(market.listingIndexByTokenSeller(tokenId, seller), 0);

        IVotingEscrowMarketplace.MarketOrder memory listing = _listing(tokenId, 1);
        assertEq(uint256(listing.status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Fulfilled));
    }

    function test_fulfillListingWithEtherWrapsPaymentAndPaysOutEther() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(weth), PRICE);
        _approveVe(seller, tokenId);

        (uint256 fee, uint256 net) = _feeAndNet(DEFAULT_LOCK_AMOUNT, PRICE);

        uint256 sellerBefore = seller.balance;
        uint256 govBefore = gov.balance;
        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        market.fulfillListing{value: PRICE}(tokenId, seller, address(weth), PRICE);

        assertEq(ve.ownerOf(tokenId), buyer);
        assertEq(seller.balance, sellerBefore + net);
        assertEq(gov.balance, govBefore + fee);
        assertEq(buyer.balance, buyerBefore - PRICE);
        assertEq(address(market).balance, 0);
        assertEq(weth.balanceOf(address(market)), 0);
    }

    function test_fulfillListingWithEtherRefundsExcessValue() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(weth), PRICE);
        _approveVe(seller, tokenId);

        uint256 excess = 1 ether;
        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        market.fulfillListing{value: PRICE + excess}(tokenId, seller, address(weth), PRICE);

        assertEq(ve.ownerOf(tokenId), buyer);
        assertEq(buyer.balance, buyerBefore - PRICE);
    }

    function test_newOwnerCanListAfterPurchase() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(usdc), PRICE);
        _approveVe(seller, tokenId);
        _approveUsdc(buyer, PRICE);

        vm.prank(buyer);
        market.fulfillListing(tokenId, seller, address(usdc), PRICE);

        uint256 resalePrice = 12 ether;
        _createListing(buyer, tokenId, address(usdc), resalePrice);
        _approveVe(buyer, tokenId);
        _approveUsdc(bidder, resalePrice);

        vm.prank(bidder);
        market.fulfillListing(tokenId, buyer, address(usdc), resalePrice);

        assertEq(ve.ownerOf(tokenId), bidder);
        assertEq(market.nListingsByToken(tokenId), 2);
        assertEq(uint256(_listing(tokenId, 2).status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Fulfilled));
    }

    function test_createListingAcceptsMinimumAndMaximumDurations() public {
        uint256 tokenIdMin = _mintVe(seller);
        vm.prank(seller);
        market.createListing(tokenIdMin, address(usdc), PRICE, MIN_DURATION);
        assertEq(_listing(tokenIdMin, 1).deadline, block.timestamp + MIN_DURATION);

        uint256 tokenIdMax = _mintVe(seller);
        vm.prank(seller);
        market.createListing(tokenIdMax, address(usdc), PRICE, MAX_DURATION);
        assertEq(_listing(tokenIdMax, 1).deadline, block.timestamp + MAX_DURATION);
    }

    function test_sellerCanListAgainAfterDelist() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(usdc), PRICE);

        vm.prank(seller);
        market.delist(tokenId);

        _createListing(seller, tokenId, address(usdc), PRICE + 1 ether);
        assertEq(market.listingIndexByTokenSeller(tokenId, seller), 2);
        assertEq(uint256(_listing(tokenId, 2).status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
    }
}
