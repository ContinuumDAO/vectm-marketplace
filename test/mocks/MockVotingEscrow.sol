// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockVotingEscrow is ERC721 {
    mapping(uint256 tokenId => int128 amount) internal _lockedAmount;
    mapping(uint256 tokenId => uint256 end) internal _lockedEnd;

    constructor() ERC721("Voting Escrow CTM", "veCTM") {}

    function mint(address to, uint256 tokenId, int128 amount, uint256 end) external {
        _mint(to, tokenId);
        _lockedAmount[tokenId] = amount;
        _lockedEnd[tokenId] = end;
    }

    function setLocked(uint256 tokenId, int128 amount, uint256 end) external {
        _lockedAmount[tokenId] = amount;
        _lockedEnd[tokenId] = end;
    }

    function locked(uint256 tokenId) external view returns (int128, uint256) {
        return (_lockedAmount[tokenId], _lockedEnd[tokenId]);
    }

    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool) {
        address owner = ownerOf(tokenId);
        return _isAuthorized(owner, spender, tokenId);
    }

    function transfer(address to, uint256 tokenId) external {
        _transfer(_msgSender(), to, tokenId);
    }
}
