// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.29;

import "forge-std/Script.sol";

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {LoanRouter} from "src/LoanRouter.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract UpgradeLoanRouter is Deployer {
    function run(
        address collateralLiquidator,
        address collateralWrapper,
        address depositTimelock
    ) public broadcast useDeployment returns (address) {
        // Deploy LoanRouter implementation
        LoanRouter loanRouterImpl = new LoanRouter(collateralLiquidator, collateralWrapper, depositTimelock);
        console.log("LoanRouter implementation", address(loanRouterImpl));

        /* Lookup proxy admin */
        address proxyAdmin = address(uint160(uint256(vm.load(_deployment.loanRouter, ERC1967Utils.ADMIN_SLOT))));

        if (Ownable(proxyAdmin).owner() == msg.sender) {
            /* Upgrade Proxy */
            ProxyAdmin(proxyAdmin)
                .upgradeAndCall(ITransparentUpgradeableProxy(_deployment.loanRouter), address(loanRouterImpl), "");
            console.log("Upgraded proxy %s implementation to: %s\n", _deployment.loanRouter, address(loanRouterImpl));
        } else {
            console.log("\nUpgrade calldata");
            console.log("Target:   %s", proxyAdmin);
            console.log("Calldata:");
            console.logBytes(
                abi.encodeWithSelector(
                    ProxyAdmin.upgradeAndCall.selector,
                    ITransparentUpgradeableProxy(_deployment.loanRouter),
                    address(loanRouterImpl),
                    ""
                )
            );
        }

        return address(loanRouterImpl);
    }
}
