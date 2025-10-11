// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.29;

import "forge-std/Script.sol";

import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeploySimpleInterestRateModel is Deployer {
    function run() public broadcast returns (address) {
        // Deploy SimpleInterestRateModel
        SimpleInterestRateModel simpleInterestRateModel = new SimpleInterestRateModel();
        console.log("SimpleInterestRateModel", address(simpleInterestRateModel));

        return (address(simpleInterestRateModel));
    }
}
