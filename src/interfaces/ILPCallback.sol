// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface ILPCallback {
    /// @notice Called to `msg.sender` after executing a mint via Pair
    /// @dev In the implementation you must pay the pool tokens owed for the mint.
    /// The caller of this method must be checked to be a Pair deployed by the canonical Factory.
    /// @param data Any data passed through by the caller via the Mint call
    function LPCallback(uint256 amount, bytes calldata data) external;
}
