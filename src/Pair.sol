// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.4;

import { Factory } from "./Factory.sol";
import { Lendgine } from "./Lendgine.sol";

import { IPair } from "./interfaces/IPair.sol";

import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { PRBMathUD60x18 } from "prb-math/PRBMathUD60x18.sol";

contract Pair is IPair {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event Mint(address indexed sender, uint256 liquidity);

    event Burn(address indexed sender, uint256 amount0, uint256 amount1, uint256 liquidity, address indexed to);

    event Swap(address indexed sender, uint256 amount0Out, uint256 amount1Out, address indexed to);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ReentrancyError();

    error InsufficientInputError();

    error InsufficientOutputError();

    error BalanceReturnError();

    error LendgineError();

    error InvariantError();

    error SpeculativeInvariantError();

    error BufferError();

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPair
    address public immutable override factory;

    /// @inheritdoc IPair
    address public immutable override lendgine;

    /// @inheritdoc IPair
    address public immutable override base;

    /// @inheritdoc IPair
    address public immutable override speculative;

    /// @inheritdoc IPair
    uint256 public immutable override upperBound;

    /// @inheritdoc IPair
    uint256 public immutable override baseScaleFactor;

    /// @inheritdoc IPair
    uint256 public immutable override speculativeScaleFactor;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPair
    uint256 public override totalSupply;

    /// @inheritdoc IPair
    uint256 public override buffer;

    /*//////////////////////////////////////////////////////////////
                           REENTRANCY LOGIC
    //////////////////////////////////////////////////////////////*/

    uint8 private locked = 1;

    modifier lock() virtual {
        if (locked != 1) revert ReentrancyError();

        locked = 2;

        _;

        locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        factory = msg.sender;

        uint256 _baseScaleFactor;
        uint256 _speculativeScaleFactor;

        (lendgine, base, speculative, _baseScaleFactor, _speculativeScaleFactor, upperBound) = Factory(msg.sender)
            .pairParameters();

        if (_baseScaleFactor > 18 || _baseScaleFactor < 6) revert InvariantError();
        if (_speculativeScaleFactor > 18 || _speculativeScaleFactor < 6) revert InvariantError();

        baseScaleFactor = _baseScaleFactor;
        speculativeScaleFactor = _speculativeScaleFactor;
    }

    /*//////////////////////////////////////////////////////////////
                              PAIR LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPair
    function verifyInvariant(
        uint256 r0,
        uint256 r1,
        uint256 shares
    ) public view returns (bool valid) {
        uint256 scale0 = PRBMathUD60x18.div(PRBMathUD60x18.div(r0, shares), 10**baseScaleFactor);
        uint256 scale1 = PRBMathUD60x18.div(PRBMathUD60x18.div(r1, shares), 10**speculativeScaleFactor);

        uint256 a = scale0;
        uint256 b = PRBMathUD60x18.mul(scale1, upperBound);
        uint256 c = PRBMathUD60x18.powu(scale1, 2) / 4;
        uint256 d = PRBMathUD60x18.powu(upperBound, 2);

        if (scale1 > 2 * upperBound) revert SpeculativeInvariantError();

        return a + b == c + d;
    }

    /// @inheritdoc IPair
    function mint(uint256 liquidity) external override lock {
        if (liquidity == 0) revert InsufficientOutputError();

        (uint256 balance0, uint256 balance1) = balances();
        if (!verifyInvariant(balance0, balance1, liquidity + totalSupply)) revert InvariantError();
        _mint(liquidity);

        emit Mint(msg.sender, liquidity);
    }

    /// @inheritdoc IPair
    function burn(address to, uint256 liquidity) external override lock {
        (uint256 balance0, uint256 balance1) = balances();
        uint256 _totalSupply = totalSupply;
        if (!verifyInvariant(balance0, balance1, totalSupply)) revert InvariantError();

        uint256 amount0 = (balance0 * liquidity) / _totalSupply;
        uint256 amount1 = (balance1 * liquidity) / _totalSupply;

        if (amount0 == 0 && amount1 == 0) revert InsufficientOutputError();
        _burn(liquidity);

        SafeTransferLib.safeTransfer(base, to, amount0);
        SafeTransferLib.safeTransfer(speculative, to, amount1);

        emit Burn(msg.sender, amount0, amount1, liquidity, to);
    }

    /// @inheritdoc IPair
    function swap(
        address to,
        uint256 amount0Out,
        uint256 amount1Out
    ) external override lock {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputError();

        if (amount0Out > 0) SafeTransferLib.safeTransfer(base, to, amount0Out);
        if (amount1Out > 0) SafeTransferLib.safeTransfer(speculative, to, amount1Out);

        (uint256 balance0, uint256 balance1) = balances();
        if (!verifyInvariant(balance0, balance1, totalSupply)) revert InvariantError();

        emit Swap(msg.sender, amount0Out, amount1Out, to);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEW
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPair
    function balances() public view override returns (uint256, uint256) {
        bool success;
        bytes memory data;

        (success, data) = base.staticcall(
            abi.encodeWithSelector(bytes4(keccak256(bytes("balanceOf(address)"))), address(this))
        );
        if (!success || data.length < 32) revert BalanceReturnError();
        uint256 balance0 = abi.decode(data, (uint256));

        (success, data) = speculative.staticcall(
            abi.encodeWithSelector(bytes4(keccak256(bytes("balanceOf(address)"))), address(this))
        );
        if (!success || data.length < 32) revert BalanceReturnError();

        return (balance0, abi.decode(data, (uint256)));
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(uint256 amount) internal {
        totalSupply += amount;

        // Cannot overflow because the buffer
        // can't exceed the max uint256 value.
        unchecked {
            buffer += amount;
        }
    }

    function _burn(uint256 amount) internal {
        buffer -= amount;

        // Cannot underflow because the buffer
        // will never be larger than the total supply.
        unchecked {
            totalSupply -= amount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                             BUFFER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPair
    function addBuffer(uint256 amount) external override {
        if (msg.sender != lendgine) revert LendgineError();
        if (amount + buffer > totalSupply) revert BufferError();

        buffer += amount;
    }

    /// @inheritdoc IPair
    function removeBuffer(uint256 amount) external override {
        if (msg.sender != lendgine) revert LendgineError();

        buffer -= amount;
    }
}
