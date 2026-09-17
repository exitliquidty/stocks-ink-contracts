// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

// Same reasoning as the sibling ../BaseHook.sol (hand-rolled instead of vendoring the official
// v4-periphery package, which blows past Windows' MAX_PATH via nested submodules) -- but shaped
// differently on purpose. ../BaseHook.sol dispatches every IHooks entrypoint to an internal
// underscore-prefixed virtual, the shape MemeStockHookV4 already builds on. The vendored
// vendor/TWAMM.sol (see that file's own header for provenance and audit links) instead overrides
// the external IHooks entrypoints directly -- the shape the real v4-periphery BaseHook actually
// uses upstream, including its IUnlockCallback dispatch (TWAMM.sol calls poolManager.unlock()
// itself to execute matched/pool-side order swaps, then implements _unlockCallback to receive the
// result). Rather than editing TWAMM.sol's own overrides to fit this repo's internal-dispatch
// convention (touching audited logic for a cosmetic reason), this reproduces the upstream shape
// exactly so the vendored file's diff against the audited original stays minimal: only the import
// path, the Owned -> Ownable swap (see TWAMM.sol's own import comment), and the remap aliases
// were changed to fit this repo's layout.
abstract contract TwammBaseHook is IHooks, IUnlockCallback {
    error NotPoolManager();
    error HookNotImplemented();

    IPoolManager public immutable poolManager;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice The exact set of callbacks this hook uses -- checked against this contract's own
    /// mined address at construction time, and by the PoolManager on every pool that attaches it.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    // -- IHooks: virtual, with a safe reverting default -- a subclass overrides only the
    // entrypoints its own getHookPermissions() actually enables. An enabled-but-unoverridden
    // callback therefore fails loudly (PoolManager's own Hooks.validateHookPermissions never lets
    // a mismatched address deploy in the first place, so this default is effectively unreachable
    // by real traffic, same guarantee as the sibling BaseHook's internal-dispatch defaults).

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        virtual
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        onlyPoolManager
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // -- IUnlockCallback: dispatches to an internal virtual, same pattern as every IHooks
    // entrypoint above. Reachable only from the PoolManager, and only while this contract itself
    // is mid-unlock (poolManager.unlock() reverts otherwise), so onlyPoolManager here is the same
    // real guarantee the official BaseHook relies on.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    function _unlockCallback(bytes calldata) internal virtual returns (bytes memory) {
        revert HookNotImplemented();
    }
}
