// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

interface IVotingEscrow {
    function safeTransferFrom(address _from, address _to, uint256 _tokenId) external;
    function transfer(address _to, uint256 _tokenId) external;
    function transferFrom(address _from, address _to, uint256 _tokenId) external;
    function approve(address _approved, uint256 _tokenId) external;
    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool);
    function ownerOf(uint256 _tokenId) external view returns (address);
    function locked(uint256 _tokenId) external view returns (int128, uint256);
}
