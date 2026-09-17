// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {StocksHook} from "../src/dex/v4/StocksHook.sol";
import {StocksGraduator} from "../src/dex/v4/StocksGraduator.sol";
import {StocksCurveFactory} from "../src/curve/StocksCurveFactory.sol";
import {StocksStakingFactory} from "../src/StocksStakingFactory.sol";
import {StocksGovernorFactory} from "../src/governance/StocksGovernorFactory.sol";
import {StocksLaunchFactory} from "../src/StocksLaunchFactory.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @notice V7 sibling of DeployFactoryV6.s.sol -- identical deploy sequence and TWAMM-merged
/// stack, with one real difference: StocksGraduator now also takes this factory's own (predicted)
/// address, and StocksLaunchFactory gains no new constructor params but now populates a new
/// `curveOf` mapping StocksGraduator checks callers against -- see StocksGraduator.sol's own
/// AUDIT FIX H-3 docstring for the direct-hijack vulnerability this closes (found in a live
/// security review of the deployed V6 stack: graduate() had no way to tell a real curve's own
/// graduation call apart from anyone else's). V6 pools/tokens already graduated are completely
/// unaffected -- this is a new, separate launch path for future launches only, exactly like every
/// prior generation bump.
///
/// Three-way mutual reference, not two: StocksHook needs the graduator's address (`poolDeployer`);
/// StocksGraduator needs both the hook's address AND this factory's address (to call
/// `curveOf` on it); StocksLaunchFactory needs the graduator's address (`v4Graduator`). Resolved
/// by predicting BOTH the graduator's and the factory's future addresses from the deployer's
/// nonce before broadcasting anything, then deploying hook -> graduator -> factory in that order,
/// each one landing exactly where predicted.
///
/// TOKEN_METADATA_REGISTRY_ADDRESS must already exist -- run
/// script/DeployTokenMetadataRegistry.s.sol once, separately, before this script (the registry is
/// a shared singleton meant to outlive any single factory generation, so it is NOT deployed here).
///
/// **Before ever running this against real Ink mainnet**, re-verify the FULL script end to end
/// against a local anvil fork, exactly like DeployFactoryV6.s.sol's own docstring instructed.
///   1. `anvil --fork-url https://rpc-gel.inkonchain.com --port 8555 &`
///   2. Set every env var below; DEPLOYER_ADDRESS must be a real anvil dev account.
///   3. `forge script script/DeployFactoryV7.s.sol --rpc-url http://127.0.0.1:8555 --sender <addr>
///      --private-key <anvil dev key> --broadcast`
///   4. Confirm `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL` and no address-mismatch revert.
///
/// Needs, all as env vars:
///   POOL_MANAGER_ADDRESS      -- Uniswap V4's PoolManager singleton on Ink.
///   DEPLOYER_ADDRESS          -- the address that will actually broadcast every transaction in
///                               this run (i.e. whatever --private-key/--ledger/--sender resolves
///                               to). Used only to read its CURRENT nonce before broadcasting
///                               starts, to predict the graduator's and factory's future addresses
///                               -- must match the real broadcaster exactly, or the safety checks
///                               below revert.
///   TRUSTED_SIGNER_ADDRESS    -- public address matching frontend/.env.local's own
///                               PRICE_SIGNER_PRIVATE_KEY. Get it without ever putting the
///                               private key itself into this shell's environment:
///                               `cast wallet address <PRICE_SIGNER_PRIVATE_KEY>`.
///   PROTOCOL_TREASURY_ADDRESS -- receives the protocol's share of every pool's trading fee.
///   EXPIRATION_INTERVAL_SECONDS -- TWAMM's own order-expiration tick size.
///   TOKEN_METADATA_REGISTRY_ADDRESS -- output of script/DeployTokenMetadataRegistry.s.sol, run
///                               once, separately, before this script.
///
/// Plus the 7 per-generation "protocol constant" values -- see this codebase's deploy history for
/// the exact TEST/MAINNET profile numbers and the MIN_REWARDS_DURATION/MIN_VOTING_DELAY/
/// MIN_VOTING_PERIOD floor explanation, unchanged here.
contract DeployFactoryV7 is Script {
    function run()
        external
        returns (
            address governorFactory,
            address curveDeployer,
            address stakingFactory,
            address hook,
            address graduator,
            address factory
        )
    {
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address trustedSigner = vm.envAddress("TRUSTED_SIGNER_ADDRESS");
        address protocolTreasury = vm.envAddress("PROTOCOL_TREASURY_ADDRESS");
        uint256 expirationInterval = vm.envUint("EXPIRATION_INTERVAL_SECONDS");
        address metadataRegistry = vm.envAddress("TOKEN_METADATA_REGISTRY_ADDRESS");

        uint256 graduationUsdThreshold = vm.envUint("GRADUATION_USD_THRESHOLD");
        uint256 minRewardsDuration = vm.envUint("MIN_REWARDS_DURATION_SECONDS");
        uint256 maxRewardsDuration = vm.envUint("MAX_REWARDS_DURATION_SECONDS");
        uint48 votingDelay = uint48(vm.envUint("VOTING_DELAY_SECONDS"));
        uint32 votingPeriod = uint32(vm.envUint("VOTING_PERIOD_SECONDS"));
        uint256 proposalThresholdBps = vm.envUint("PROPOSAL_THRESHOLD_BPS");
        uint256 minHolderBps = vm.envUint("MIN_HOLDER_BPS");

        require(
            CREATE2_FACTORY.code.length > 0,
            "CREATE2 deterministic deployment proxy not found at the canonical address on this chain -- see this script's own docstring"
        );
        require(metadataRegistry.code.length > 0, "TOKEN_METADATA_REGISTRY_ADDRESS has no code -- run DeployTokenMetadataRegistry.s.sol first");

        // Captured BEFORE broadcasting starts -- vm.getNonce is a plain state read, safe to call
        // pre-broadcast. FOUR broadcaster-originated transactions precede the graduator's own
        // deploy: governorFactory, curveDeployer, stakingFactory, and the CREATE2-proxy call that
        // deploys the hook -- same accounting as DeployFactoryV6.s.sol, unchanged here since the
        // metadata registry is deployed separately, not in this script. ONE more transaction (the
        // graduator's own deploy) sits between that and the factory's deploy, so the factory lands
        // at nonceAtStart + 5, not + 4.
        uint256 nonceAtStart = vm.getNonce(deployer);
        address predictedGraduator = vm.computeCreateAddress(deployer, nonceAtStart + 4);
        address predictedFactory = vm.computeCreateAddress(deployer, nonceAtStart + 5);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), predictedGraduator, expirationInterval);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(StocksHook).creationCode, constructorArgs);

        vm.startBroadcast();

        governorFactory = address(new StocksGovernorFactory());
        curveDeployer = address(new StocksCurveFactory());
        stakingFactory = address(new StocksStakingFactory());

        // Deployed via an explicit, low-level call to CREATE2_FACTORY -- see DeployFactoryV6.s.sol's
        // own comment on the same line for why the salted `new X{salt: salt}(...)` syntax is NOT
        // used here.
        bytes memory hookInitCode = abi.encodePacked(type(StocksHook).creationCode, constructorArgs);
        (bool hookDeployOk, bytes memory hookDeployReturn) =
            CREATE2_FACTORY.call(abi.encodePacked(salt, hookInitCode));
        require(hookDeployOk, "CREATE2 factory call failed while deploying the hook");
        hook = address(bytes20(hookDeployReturn));
        require(hook == hookAddress, "hook address mismatch -- see docstring on nonce/CREATE2 assumptions");
        StocksHook hookContract = StocksHook(hook);

        StocksGraduator graduatorContract = new StocksGraduator(IPoolManager(poolManager), hookContract, predictedFactory);
        require(
            address(graduatorContract) == predictedGraduator,
            "graduator address mismatch -- see docstring on nonce/CREATE2 assumptions"
        );
        graduator = address(graduatorContract);

        factory = address(
            new StocksLaunchFactory(
                trustedSigner,
                protocolTreasury,
                hook,
                governorFactory,
                stakingFactory,
                curveDeployer,
                graduator,
                metadataRegistry,
                graduationUsdThreshold,
                minRewardsDuration,
                maxRewardsDuration,
                votingDelay,
                votingPeriod,
                proposalThresholdBps,
                minHolderBps
            )
        );
        require(factory == predictedFactory, "factory address mismatch -- see docstring on nonce/CREATE2 assumptions");

        vm.stopBroadcast();

        console.log("StocksGovernorFactory deployed at:", governorFactory);
        console.log("StocksCurveFactory deployed at:", curveDeployer);
        console.log("StocksStakingFactory deployed at:", stakingFactory);
        console.log("StocksHook deployed at:", hook);
        console.log("StocksGraduator deployed at:", graduator);
        console.log("StocksLaunchFactory deployed at:", factory);
        console.log("");
        console.log("trustedSigner set to:", trustedSigner);
        console.log("protocol treasury set to:", protocolTreasury);
        console.log("expirationInterval (seconds) set to:", expirationInterval);
        console.log("metadataRegistry set to:", metadataRegistry);
        console.log("");
        console.log("Set frontend/.env.local's NEXT_PUBLIC_CURVE_FACTORY_V7_ADDRESS to the factory address above.");
        console.log("No dedicated router to configure -- V7 pools trade through SuperSwap's existing V4 swap path");
        console.log("(the real Universal Router already configured on Ink), same as any other hook-enabled pool.");
        console.log("The hook's own address above must still be indexed there for pool discovery to find it.");
    }
}
