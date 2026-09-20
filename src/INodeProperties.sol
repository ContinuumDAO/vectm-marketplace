// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

interface INodeProperties {
    function attachedKeyGen(uint256 _tokenId) external view returns (address);
}
