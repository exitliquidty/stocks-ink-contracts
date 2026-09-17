// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ╔══════════════════════════════════════════════════════════════════╗
// ║                                                                    ║
// ║   S T O C K S . I N K                                             ║
// ║                                                                    ║
// ║   Tokenized real-world equities, traded and staked on-chain.       ║
// ║                                                                    ║
// ╚══════════════════════════════════════════════════════════════════╝
//
// Stocks.ink lets anyone launch a tokenized version of a real-world stock,
// bond it against real price data, and trade it through a bonding curve
// that graduates into a live, fee-generating Uniswap V4 pool with on-chain
// staking and governance for the underlying treasury.

/// @notice On-chain pointer from a token address to its off-chain metadata (image/description/
/// socials, pinned to IPFS), shared across every launch factory generation.
contract TokenMetadataRegistry {
    mapping(address => string) public metadataURI;

    event MetadataURISet(address indexed token, string uri);

    error AlreadySet();
    error TokenHasNoCode();

    /// @notice Sets `token`'s metadata URI once, permanently.
    function setMetadataURI(address token, string calldata uri) external {
        if (token.code.length == 0) revert TokenHasNoCode();
        if (bytes(metadataURI[token]).length != 0) revert AlreadySet();
        metadataURI[token] = uri;
        emit MetadataURISet(token, uri);
    }
}
