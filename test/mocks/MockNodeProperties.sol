// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

contract MockNodeProperties {
    mapping(uint256 tokenId => address keyGen) public attachedKeyGen;

    function attach(uint256 tokenId, address keyGen) external {
        attachedKeyGen[tokenId] = keyGen;
    }
}
