// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

contract DeployMockTokensScript is Script {
    function run() external {
        require(block.chainid == 31337, "LOCAL_ONLY");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        MockERC20 stakingToken = new MockERC20("Staking Token", "STK", 18);
        MockERC20 rewardToken = new MockERC20("Reward Token", "RWD", 18);
        vm.stopBroadcast();

        console2.log("STAKING_TOKEN:", address(stakingToken));
        console2.log("REWARD_TOKEN:", address(rewardToken));
    }
}
