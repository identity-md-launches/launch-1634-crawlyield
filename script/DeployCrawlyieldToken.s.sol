// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {CrawlyieldToken} from "../src/CrawlyieldToken.sol";

/// @title Deploy script for Crawlyield (CRAWL)
/// @notice The token takes no constructor arguments, so there is nothing to configure. `deploy()`
///         is the unit the tests call directly; `run()` only wraps it in a broadcast.
/// @dev On an IdentityMD launch this script is not used: the factory deploys the token from its
///      creation code and receives the supply as `msg.sender`. The script exists so the same
///      bytecode can be deployed and reviewed outside that flow.
contract DeployCrawlyieldToken is Script {
    /// @notice Deploys the token. Whoever calls this (the broadcaster under `run()`) receives the
    ///         whole supply.
    function deploy() public returns (CrawlyieldToken token) {
        token = new CrawlyieldToken();
    }

    function run() external returns (CrawlyieldToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
