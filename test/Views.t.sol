// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {MarketplaceBase} from "./MarketplaceBase.sol";
import {IVotingEscrowMarketplace} from "../src/IVotingEscrowMarketplace.sol";

contract ViewsTest is MarketplaceBase {
    function test_calculateFeeTierMatchesConfiguredFloors() public view {
        assertEq(uint256(market.calculateFeeTier(LIMIT_BLACK)), uint256(IVotingEscrowMarketplace.FeeTier.Black));
        assertEq(uint256(market.calculateFeeTier(LIMIT_BLACK + 1)), uint256(IVotingEscrowMarketplace.FeeTier.Black));
        assertEq(uint256(market.calculateFeeTier(LIMIT_GOLD)), uint256(IVotingEscrowMarketplace.FeeTier.Gold));
        assertEq(uint256(market.calculateFeeTier(LIMIT_SILVER)), uint256(IVotingEscrowMarketplace.FeeTier.Silver));
        assertEq(uint256(market.calculateFeeTier(LIMIT_BRONZE)), uint256(IVotingEscrowMarketplace.FeeTier.Bronze));
        assertEq(uint256(market.calculateFeeTier(LIMIT_BLUE)), uint256(IVotingEscrowMarketplace.FeeTier.Blue));
        assertEq(
            uint256(market.calculateFeeTier(DEFAULT_LOCK_AMOUNT)), uint256(IVotingEscrowMarketplace.FeeTier.Bronze)
        );
    }

    function test_marketOrderStatusIsOpenForReadyListing() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(usdc), PRICE);
        _approveVe(seller, tokenId);
        _approveUsdc(buyer, PRICE);

        IVotingEscrowMarketplace.MarketOrder memory listing = _listing(tokenId, 1);
        IVotingEscrowMarketplace.MarketOrderStatus status =
            market.marketOrderStatus(listing, listing.snapshotAmount, listing.snapshotEnd, buyer, tokenId);

        assertEq(uint256(status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
    }

    function test_marketOrderStatusIsOpenForWethListingWithoutPaymentApproval() public {
        uint256 tokenId = _mintVe(seller);
        _createListing(seller, tokenId, address(weth), PRICE);
        _approveVe(seller, tokenId);

        IVotingEscrowMarketplace.MarketOrder memory listing = _listing(tokenId, 1);
        IVotingEscrowMarketplace.MarketOrderStatus status =
            market.marketOrderStatus(listing, listing.snapshotAmount, listing.snapshotEnd, buyer, tokenId);

        assertEq(uint256(status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
    }

    function test_marketOrderStatusIsOpenForReadyOffering() public {
        uint256 tokenId = _mintVe(seller);
        _createOffering(buyer, tokenId, address(usdc), PRICE);
        _approveVe(seller, tokenId);
        _approveUsdc(buyer, PRICE);

        IVotingEscrowMarketplace.MarketOrder memory offering = _offering(tokenId, 1);
        IVotingEscrowMarketplace.MarketOrderStatus status =
            market.marketOrderStatus(offering, offering.snapshotAmount, offering.snapshotEnd, buyer, tokenId);

        assertEq(uint256(status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
    }

    function test_auctionStatusTransitionsPendingActiveCompleteSold() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);
        _createAuction(seller, tokenId, address(usdc), 5 ether, 1 ether);

        IVotingEscrowMarketplace.Auction memory pending = _auction(tokenId, 1);
        assertEq(uint256(market.auctionStatus(pending)), uint256(IVotingEscrowMarketplace.AuctionStatus.Pending));

        _approveUsdc(buyer, 5 ether);
        vm.prank(buyer);
        market.auctionBid(tokenId, seller, 5 ether);

        IVotingEscrowMarketplace.Auction memory active = _auction(tokenId, 1);
        assertEq(uint256(market.auctionStatus(active)), uint256(IVotingEscrowMarketplace.AuctionStatus.Active));

        vm.warp(block.timestamp + ORDER_DURATION);
        IVotingEscrowMarketplace.Auction memory complete = _auction(tokenId, 1);
        assertEq(uint256(market.auctionStatus(complete)), uint256(IVotingEscrowMarketplace.AuctionStatus.Complete));

        market.settleAuction(tokenId, seller);
        IVotingEscrowMarketplace.Auction memory sold = _auction(tokenId, 1);
        assertEq(uint256(market.auctionStatus(sold)), uint256(IVotingEscrowMarketplace.AuctionStatus.Sold));
    }

    function test_auctionStatusExpiresWhenNoBidsArePlaced() public {
        uint256 tokenId = _mintVe(seller);
        _approveVe(seller, tokenId);
        _createAuction(seller, tokenId, address(usdc), 5 ether, 1 ether);

        vm.warp(block.timestamp + ORDER_DURATION);
        IVotingEscrowMarketplace.Auction memory expired = _auction(tokenId, 1);
        assertEq(uint256(market.auctionStatus(expired)), uint256(IVotingEscrowMarketplace.AuctionStatus.Expired));
    }

    function test_fulfillListingUsesFeeRateForEachTier() public {
        uint256[5] memory amounts = [LIMIT_BLACK, LIMIT_GOLD, LIMIT_SILVER, LIMIT_BRONZE, LIMIT_BLUE];
        uint256[5] memory rates = [RATE_BLACK, RATE_GOLD, RATE_SILVER, RATE_BRONZE, RATE_BLUE];

        for (uint256 i = 0; i < amounts.length; i++) {
            address tokenSeller = makeAddr(string.concat("seller", vm.toString(i)));
            address tokenBuyer = makeAddr(string.concat("buyer", vm.toString(i)));
            uint256 tokenId = _mintVe(tokenSeller, amounts[i]);

            usdc.mint(tokenBuyer, PRICE);
            vm.prank(tokenSeller);
            market.createListing(tokenId, address(usdc), PRICE, ORDER_DURATION);
            _approveVe(tokenSeller, tokenId);
            vm.prank(tokenBuyer);
            usdc.approve(address(market), PRICE);

            uint256 expectedFee = PRICE * rates[i] / 10_000;
            uint256 govBefore = usdc.balanceOf(gov);

            vm.prank(tokenBuyer);
            market.fulfillListing(tokenId, tokenSeller, address(usdc), PRICE);

            assertEq(usdc.balanceOf(gov), govBefore + expectedFee);
            assertEq(ve.ownerOf(tokenId), tokenBuyer);
        }
    }
}
