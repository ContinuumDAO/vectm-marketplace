// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {MarketplaceBase} from "./MarketplaceBase.sol";
import {VotingEscrowMarketplace} from "../src/VotingEscrowMarketplace.sol";
import {IVotingEscrowMarketplace} from "../src/IVotingEscrowMarketplace.sol";

contract OfferingTest is MarketplaceBase {
    function test_createOfferingStoresOpenOrderWithoutEscrowingErc20() public {
        uint256 tokenId = _mintVe(seller);
        uint256 buyerUsdcBefore = usdc.balanceOf(buyer);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.OfferingCreated(
            tokenId, buyer, address(usdc), PRICE, block.timestamp + ORDER_DURATION
        );

        _createOffering(buyer, tokenId, address(usdc), PRICE);

        assertEq(usdc.balanceOf(buyer), buyerUsdcBefore);
        assertEq(market.nOfferingsByToken(tokenId), 1);
        assertEq(market.offeringIndexByTokenBuyer(tokenId, buyer), 1);

        IVotingEscrowMarketplace.MarketOrder memory offering = _offering(tokenId, 1);
        assertEq(offering.price, PRICE);
        assertEq(offering.creator, buyer);
        assertEq(offering.paymentToken, address(usdc));
        assertEq(offering.snapshotAmount, DEFAULT_LOCK_AMOUNT);
        assertEq(uint256(offering.status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
        assertEq(uint256(offering.kind), uint256(IVotingEscrowMarketplace.MarketOrderKind.Offering));
    }

    function test_createOfferingWithEtherWrapsWethToBuyer() public {
        uint256 tokenId = _mintVe(seller);
        uint256 buyerEthBefore = buyer.balance;

        _createOfferingEth(buyer, tokenId, PRICE, PRICE);

        assertEq(weth.balanceOf(buyer), PRICE);
        assertEq(weth.balanceOf(address(market)), 0);
        assertEq(buyer.balance, buyerEthBefore - PRICE);

        IVotingEscrowMarketplace.MarketOrder memory offering = _offering(tokenId, 1);
        assertEq(offering.paymentToken, address(weth));
        assertEq(uint256(offering.status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
    }

    function test_createOfferingWithEtherRefundsExcessValue() public {
        uint256 tokenId = _mintVe(seller);
        uint256 excess = 2 ether;
        uint256 buyerEthBefore = buyer.balance;

        _createOfferingEth(buyer, tokenId, PRICE, PRICE + excess);

        assertEq(weth.balanceOf(buyer), PRICE);
        assertEq(buyer.balance, buyerEthBefore - PRICE);
    }

    function test_createOfferingReplacesExistingOpenOffering() public {
        uint256 tokenId = _mintVe(seller);
        _createOffering(buyer, tokenId, address(usdc), PRICE);

        uint256 newBid = PRICE + 3 ether;
        _createOffering(buyer, tokenId, address(usdc), newBid);

        assertEq(
            uint256(_offering(tokenId, 1).status),
            uint256(IVotingEscrowMarketplace.MarketOrderStatus.DelistedOrRescinded)
        );
        assertEq(market.nOfferingsByToken(tokenId), 2);
        assertEq(market.offeringIndexByTokenBuyer(tokenId, buyer), 2);
        assertEq(_offering(tokenId, 2).price, newBid);
        assertEq(uint256(_offering(tokenId, 2).status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
    }

    function test_rescindMarksOfferingRescindedAndClearsIndex() public {
        uint256 tokenId = _mintVe(seller);
        _createOffering(buyer, tokenId, address(usdc), PRICE);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.Rescinded(tokenId);

        vm.prank(buyer);
        market.rescind(tokenId);

        assertEq(market.offeringIndexByTokenBuyer(tokenId, buyer), 0);
        assertEq(
            uint256(_offering(tokenId, 1).status),
            uint256(IVotingEscrowMarketplace.MarketOrderStatus.DelistedOrRescinded)
        );
    }

    function test_fulfillOfferingWithErc20PaysSellerFeeAndTransfersNft() public {
        uint256 tokenId = _mintVe(seller);
        _createOffering(buyer, tokenId, address(usdc), PRICE);
        _approveVe(seller, tokenId);
        _approveUsdc(buyer, PRICE);

        (uint256 fee, uint256 net) = _feeAndNet(DEFAULT_LOCK_AMOUNT, PRICE);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 govBefore = usdc.balanceOf(gov);

        vm.expectEmit(true, true, true, true, address(market));
        emit VotingEscrowMarketplace.OfferingFulfilled(tokenId, buyer, seller, PRICE, net, fee);

        vm.prank(seller);
        market.fulfillOffering(tokenId, buyer, address(usdc), PRICE);

        assertEq(ve.ownerOf(tokenId), buyer);
        assertEq(usdc.balanceOf(buyer), buyerBefore - PRICE);
        assertEq(usdc.balanceOf(seller), sellerBefore + net);
        assertEq(usdc.balanceOf(gov), govBefore + fee);
        assertEq(market.offeringIndexByTokenBuyer(tokenId, buyer), 0);
        assertEq(uint256(_offering(tokenId, 1).status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Fulfilled));
    }

    function test_fulfillOfferingWithWethUsesWrappedBalanceAndPaysEther() public {
        uint256 tokenId = _mintVe(seller);
        _createOfferingEth(buyer, tokenId, PRICE, PRICE);
        _approveVe(seller, tokenId);
        _approveWeth(buyer, PRICE);

        (uint256 fee, uint256 net) = _feeAndNet(DEFAULT_LOCK_AMOUNT, PRICE);
        uint256 sellerBefore = seller.balance;
        uint256 govBefore = gov.balance;

        vm.prank(seller);
        market.fulfillOffering(tokenId, buyer, address(weth), PRICE);

        assertEq(ve.ownerOf(tokenId), buyer);
        assertEq(weth.balanceOf(buyer), 0);
        assertEq(seller.balance, sellerBefore + net);
        assertEq(gov.balance, govBefore + fee);
        assertEq(address(market).balance, 0);
    }

    function test_createOfferingAcceptsMinimumAndMaximumDurations() public {
        uint256 tokenIdMin = _mintVe(seller);
        vm.prank(buyer);
        market.createOffering(tokenIdMin, address(usdc), PRICE, MIN_DURATION);
        assertEq(_offering(tokenIdMin, 1).deadline, block.timestamp + MIN_DURATION);

        uint256 tokenIdMax = _mintVe(seller);
        vm.prank(buyer);
        market.createOffering(tokenIdMax, address(usdc), PRICE, MAX_DURATION);
        assertEq(_offering(tokenIdMax, 1).deadline, block.timestamp + MAX_DURATION);
    }

    function test_buyerCanCreateNewOfferingAfterRescind() public {
        uint256 tokenId = _mintVe(seller);
        _createOffering(buyer, tokenId, address(usdc), PRICE);

        vm.prank(buyer);
        market.rescind(tokenId);

        _createOffering(buyer, tokenId, address(usdc), PRICE + 1 ether);
        assertEq(market.offeringIndexByTokenBuyer(tokenId, buyer), 2);
        assertEq(uint256(_offering(tokenId, 2).status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
    }

    function test_sellerCanAcceptOneOfMultipleOpenOfferings() public {
        uint256 tokenId = _mintVe(seller);
        _createOffering(buyer, tokenId, address(usdc), PRICE);
        _createOffering(bidder, tokenId, address(usdc), PRICE + 2 ether);

        _approveVe(seller, tokenId);
        _approveUsdc(bidder, PRICE + 2 ether);

        vm.prank(seller);
        market.fulfillOffering(tokenId, bidder, address(usdc), PRICE + 2 ether);

        assertEq(ve.ownerOf(tokenId), bidder);
        assertEq(uint256(_offering(tokenId, 1).status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Open));
        assertEq(uint256(_offering(tokenId, 2).status), uint256(IVotingEscrowMarketplace.MarketOrderStatus.Fulfilled));
    }
}
