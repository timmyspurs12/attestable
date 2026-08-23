// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";
import {ProofPolicy} from "../contracts/ProofPolicy.sol";

/// @notice Deploys the Attestable stack.
///
///         forge script script/Deploy.s.sol --rpc-url bsc_testnet --broadcast --verify
///
/// @dev ROUTER. ProofPolicy gates `onSubmitted` on an immutable router address.
///      In production that is BNB Chain's `EvaluatorRouter`, but jobs cannot bind
///      to our policy there until it is whitelisted. So `ROUTER` defaults to the
///      deployer, which lets the full lifecycle be driven end-to-end today.
///      Pointing it at the real router later is a one-variable change and a
///      redeploy — the policy is immutable by design.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address router = vm.envOr("ROUTER", deployer);
        uint64 proofWindow = uint64(vm.envOr("PROOF_WINDOW", uint256(1 hours)));

        console.log("chainid   ", block.chainid);
        console.log("deployer  ", deployer);
        console.log("router    ", router);
        console.log("proofWin  ", proofWindow);

        vm.startBroadcast(pk);
        EvidenceRegistry registry = new EvidenceRegistry();
        ProofPolicy policy = new ProofPolicy(router, registry, proofWindow);
        vm.stopBroadcast();

        console.log("");
        console.log("EvidenceRegistry", address(registry));
        console.log("ProofPolicy     ", address(policy));

        string memory json = string.concat(
            '{\n  "chainId": ',
            vm.toString(block.chainid),
            ',\n  "evidenceRegistry": "',
            vm.toString(address(registry)),
            '",\n  "proofPolicy": "',
            vm.toString(address(policy)),
            '",\n  "router": "',
            vm.toString(router),
            '",\n  "proofWindow": ',
            vm.toString(uint256(proofWindow)),
            "\n}\n"
        );
        vm.writeFile(
            string.concat("config/deployed.", vm.toString(block.chainid), ".json"), json
        );
        console.log("");
        console.log("wrote config/deployed.%s.json", vm.toString(block.chainid));
    }
}
