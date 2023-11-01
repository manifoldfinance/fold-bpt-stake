// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@layerzerolabs/solidity-examples/contracts/lzApp/NonblockingLzApp.sol";

contract MyLzApp is NonblockingLzApp {
    constructor(address _endpoint) NonblockingLzApp(_endpoint) {
        //
    }

    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal override {
        //
    }
}
