// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.4;

import { Factory } from "./Factory.sol";
import { Pair } from "./Pair.sol";

import { IMintCallback } from "./interfaces/IMintCallback.sol";

import { Position } from "./libraries/Position.sol";
import { Tick } from "./libraries/Tick.sol";

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";

/// @notice A general purpose funding rate engine
/// @author Kyle Scott (https://github.com/numoen/core/blob/master/src/Lendgine.sol)
/// @author Modified from Uniswap (https://github.com/Uniswap/v3-core/blob/main/contracts/UniswapV3Pool.sol)
/// and Primitive (https://github.com/primitivefinance/rmm-core/blob/main/contracts/PrimitiveEngine.sol)
contract Lendgine is ERC20 {
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    using Tick for mapping(uint24 => Tick.Info);
    using Tick for Tick.Info;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Mint(address indexed sender, address indexed to, uint256 amountSpeculative, uint256 amountShares);

    event Burn(address indexed sender, address indexed to, uint256 amountShares, uint256 amountSpeculative);

    event MintMaker(address indexed sender, address indexed to, uint256 amountLP, uint24 tick); // add ticks to events

    event BurnMaker(address indexed to, uint256 amountLP, uint24 tick);

    event AccrueInterest();

    event AccrueMakerInterest();

    event Collect(address indexed owner, address indexed to, uint256 amountBase);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ReentrancyError();

    error BalanceReturnError();

    error InvalidTick();

    error InsufficientInputError();

    error InsufficientOutputError();

    error CompleteUtilizationError();

    error InsufficientPositionError();

    error UnutilizedAccrueError();

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable factory;

    address public immutable pair;

    /*//////////////////////////////////////////////////////////////
                          LENDGINE STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => Position.Info) public positions;

    mapping(uint24 => Tick.Info) public ticks;

    // tick 0 corresponds to empty
    uint24 public currentTick;

    uint256 public currentLiquidity;

    uint256 public interestNumerator;

    uint256 public totalLiquidityBorrowed;

    uint256 public rewardPerINStored;

    uint40 public lastUpdate;

    /*//////////////////////////////////////////////////////////////
                           REENTRANCY LOGIC
    //////////////////////////////////////////////////////////////*/

    uint256 private locked = 1;

    modifier lock() virtual {
        if (locked != 1) revert ReentrancyError();

        locked = 2;

        _;

        locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() ERC20("Numoen Lendgine", "NLDG", 18) {
        factory = msg.sender;

        pair = address(new Pair{ salt: keccak256(abi.encode(address(this))) }(msg.sender));
    }

    /*//////////////////////////////////////////////////////////////
                            LENDGINE LOGIC
    //////////////////////////////////////////////////////////////*/

    function mint(
        address recipient,
        uint256 amountSpeculative,
        bytes calldata data
    ) external lock returns (uint256) {
        _accrueInterest();

        if (currentTick == 0) revert CompleteUtilizationError();

        // amount of LP to be borrowed
        uint256 lpAmount = lpForSpeculative(amountSpeculative);

        // amount of shares to award the recipient
        uint256 totalLPAmount = totalLiquidityBorrowed;
        uint256 _totalSupply = totalSupply;
        uint256 amountShares = _totalSupply != 0 ? (lpAmount * _totalSupply) / totalLPAmount : lpAmount;

        if (amountShares == 0) revert InsufficientOutputError();

        // gather speculative tokens from makers
        uint256 interestNumeratorDelta = increaseCurrentLiquidity(lpAmount);
        interestNumerator += interestNumeratorDelta;
        totalLiquidityBorrowed += lpAmount;

        _mint(recipient, amountShares); // optimistically mint

        Pair(pair).addBuffer(lpAmount);

        uint256 balanceBefore = balanceSpeculative();
        IMintCallback(msg.sender).MintCallback(amountSpeculative, data);
        uint256 balanceAfter = balanceSpeculative();

        if (balanceAfter < balanceBefore + amountSpeculative) revert InsufficientInputError();

        emit Mint(msg.sender, recipient, amountSpeculative, amountShares);

        return amountShares;
    }

    function burn(address recipient) external lock {
        _accrueInterest();

        uint256 amountShares = balanceOf[address(this)];

        uint256 amountLP = (amountShares * totalLiquidityBorrowed) / totalSupply;

        if (amountLP == 0) revert InsufficientOutputError();

        uint256 amountSpeculative = speculativeForLP(amountLP);

        uint256 interestNumeratorDelta = decreaseCurrentLiquidity(amountLP);

        interestNumerator -= interestNumeratorDelta;
        totalLiquidityBorrowed -= amountLP;

        _burn(address(this), amountShares);

        SafeTransferLib.safeTransfer(ERC20(Pair(pair).speculative()), recipient, amountSpeculative);

        Pair(pair).removeBuffer(amountLP);

        emit Burn(msg.sender, recipient, amountShares, amountSpeculative);
    }

    function mintMaker(address recipient, uint24 tick) external lock {
        uint256 amountLP = Pair(pair).buffer();

        Position.Info storage position = positions.get(recipient, tick);
        bytes32 id = Position.getId(recipient, tick);

        if (amountLP == 0) revert InsufficientOutputError();
        if (tick == 0) revert InvalidTick();

        // trigger accruals if current position is utilized
        {
            bool utilized = (currentTick == tick && currentLiquidity > 0) || (tick < currentTick);

            if (utilized) {
                _accrueInterest();
                if (tick != currentTick) _accrueTickInterest(tick);
                _accrueMakerInterest(id, tick);
            }
        }

        ticks.update(tick, int256(amountLP));
        position.update(int256(amountLP));

        // remove liquidity if we bumped someone out
        if (tick < currentTick) {
            // TODO: update interestNumerator
            decreaseCurrentLiquidity(amountLP);
        }

        if (currentTick == 0) {
            currentTick = tick;
        }

        Pair(pair).removeBuffer(amountLP);

        emit MintMaker(msg.sender, recipient, amountLP, tick);
    }

    function burnMaker(uint24 tick, uint256 amountLP) external lock {
        if (tick == 0) revert InvalidTick();

        Position.Info storage position = positions.get(msg.sender, tick);
        bytes32 id = Position.getId(msg.sender, tick);

        bool utilized = (currentTick == tick && currentLiquidity > 0) || (tick < currentTick);

        if (utilized) {
            _accrueInterest();
            if (tick != currentTick) _accrueTickInterest(tick);
            _accrueMakerInterest(id, tick);
        }

        if (amountLP == 0) revert InsufficientOutputError();

        uint256 utilizedLP;

        if (tick == currentTick) {
            if (currentLiquidity > position.liquidity - amountLP) {
                utilizedLP = currentLiquidity - (position.liquidity - amountLP);
            }

            if (amountLP == position.liquidity) {
                // if fully removing position
                // TODO: write to stack instead
                currentLiquidity = 0;
            }
        } else if (tick < currentTick) {
            utilizedLP = amountLP;
        }

        if (amountLP == 0) revert InsufficientOutputError();
        if (amountLP > position.liquidity) revert InsufficientPositionError();

        // Remove position from the data structure
        // if tick needs to advance to the next tick
        if (currentTick == tick && currentLiquidity > position.liquidity - amountLP) {
            currentLiquidity = position.liquidity - amountLP;
        }

        ticks.update(tick, -int256(amountLP));
        position.update(-int256(amountLP));

        // Replace if we removed utilized liquidity
        if (utilizedLP > 0) {
            // TODO: update interestNumerator
            increaseCurrentLiquidity(utilizedLP);
        }

        Pair(pair).addBuffer(amountLP);

        emit BurnMaker(msg.sender, amountLP, tick);
    }

    function accrueInterest() external lock {
        _accrueInterest();
    }

    function accrueTickInterest(uint24 tick) external lock {
        if (tick == 0) revert InvalidTick();
        _accrueInterest();
        if (tick != currentTick) _accrueTickInterest(tick);
    }

    function accrueMakerInterest(bytes32 id, uint24 tick) external lock {
        if (tick == 0) revert InvalidTick();

        _accrueInterest();
        if (tick != currentTick) _accrueTickInterest(tick);
        _accrueMakerInterest(id, tick);
    }

    function collectMaker(address recipient, uint24 tick) external lock returns (uint256 collectedTokens) {
        if (tick == 0) revert InvalidTick();

        Position.Info storage position = positions.get(msg.sender, tick);

        collectedTokens = position.tokensOwed;

        if (collectedTokens == 0) revert InsufficientOutputError();

        position.tokensOwed = 0;

        SafeTransferLib.safeTransfer(ERC20(Pair(pair).speculative()), recipient, collectedTokens);

        emit Collect(msg.sender, recipient, collectedTokens);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEW
    //////////////////////////////////////////////////////////////*/

    function balanceSpeculative() public view returns (uint256) {
        bool success;
        bytes memory data;

        (success, data) = Pair(pair).speculative().staticcall(
            abi.encodeWithSelector(bytes4(keccak256(bytes("balanceOf(address)"))), address(this))
        );
        if (!success || data.length < 32) revert BalanceReturnError();

        return abi.decode(data, (uint256));
    }

    function speculativeForLP(uint256 _lpAmount) public view returns (uint256) {
        return (2 * _lpAmount * Pair(pair).upperBound()) / 10**18;
    }

    function lpForSpeculative(uint256 _speculativeAmount) public view returns (uint256) {
        return (_speculativeAmount * 1 ether) / (2 * Pair(pair).upperBound());
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Current position is assumed to be valid
    function increaseCurrentLiquidity(uint256 amountLP) private returns (uint256 interestNumeratorDelta) {
        uint24 _currentTick = currentTick;
        Tick.Info memory currentTickInfo = ticks[_currentTick];

        // amount of speculative in this tick available
        uint256 remainingCurrentLiquidity = currentTickInfo.liquidity - currentLiquidity;
        uint256 remainingLP = amountLP; // amount of pair lp tokens to be added

        while (true) {
            if (remainingCurrentLiquidity >= remainingLP) {
                break;
            } else {
                interestNumeratorDelta += _currentTick * remainingCurrentLiquidity;

                _currentTick = _currentTick + 1;
                currentLiquidity = 0;
                // TODO: error when max tick is reached
                currentTickInfo = ticks[_currentTick];

                remainingLP -= remainingCurrentLiquidity;
                remainingCurrentLiquidity = currentTickInfo.liquidity;
            }
        }

        interestNumeratorDelta += _currentTick * remainingLP;
        currentTick = _currentTick;
        currentLiquidity += remainingLP;
    }

    /// @dev assumed to never decrease past zero
    function decreaseCurrentLiquidity(uint256 amountLP) private returns (uint256 interestNumeratorDelta) {
        uint24 _currentTick = currentTick;
        Tick.Info memory currentTickInfo = ticks[_currentTick];

        uint256 remainingCurrentLiquidity = currentLiquidity;
        uint256 remainingLP = amountLP;

        while (true) {
            if (remainingCurrentLiquidity >= remainingLP) {
                break;
            } else {
                interestNumeratorDelta += _currentTick * remainingCurrentLiquidity;

                // should never underflow
                _currentTick = _currentTick - 1;
                currentTickInfo = ticks[_currentTick];

                remainingLP -= remainingCurrentLiquidity;
                remainingCurrentLiquidity = currentTickInfo.liquidity;
                _accrueTickInterest(_currentTick);
            }
        }

        interestNumeratorDelta += _currentTick * remainingLP;
        currentTick = _currentTick;
        currentLiquidity = remainingCurrentLiquidity - remainingLP;
    }

    function _accrueInterest() private {
        if (totalSupply == 0) {
            lastUpdate = uint40(block.timestamp);
            return;
        }

        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed == 0 || interestNumerator == 0) return;

        // calculate how much must be removed
        uint256 dilutionLP = (interestNumerator * timeElapsed) / (1 days * 10_000);
        uint256 dilutionSpeculative = speculativeForLP(dilutionLP);

        rewardPerINStored += (dilutionSpeculative * 1 ether) / interestNumerator;

        _accrueTickInterest(currentTick);

        uint256 interestNumeratorDelta = decreaseCurrentLiquidity(dilutionLP);
        totalLiquidityBorrowed -= dilutionLP;
        interestNumerator -= interestNumeratorDelta;

        // TODO: dilution > baseReserves;
        lastUpdate = uint40(block.timestamp);

        emit AccrueInterest();
    }

    function _accrueTickInterest(uint24 tick) private {
        if (tick > currentTick) revert UnutilizedAccrueError();

        Tick.Info storage tickInfo = ticks[tick];
        Tick.Info memory _tickInfo = tickInfo;

        uint256 tokensOwed = newTokensOwed(_tickInfo, tick);

        tickInfo.rewardPerINPaid = rewardPerINStored;
        if (tokensOwed > 0)
            tickInfo.tokensOwedPerLiquidity =
                _tickInfo.tokensOwedPerLiquidity +
                ((tokensOwed * 1 ether) / _tickInfo.liquidity);

        emit AccrueMakerInterest();
    }

    /// @dev assume global interest accrual is up to date
    function _accrueMakerInterest(bytes32 id, uint24 tick) private {
        // TODO: assert tick is matched with correct id
        Position.Info storage position = positions[id];
        Position.Info memory _position = position;

        Tick.Info storage tickInfo = ticks[tick];
        Tick.Info memory _tickInfo = tickInfo;

        uint256 tokensOwed = newTokensOwed(_position, _tickInfo);

        position.rewardPerLiquidityPaid = tickInfo.tokensOwedPerLiquidity;
        position.tokensOwed = _position.tokensOwed + tokensOwed;

        emit AccrueMakerInterest();
    }

    /// @dev Assumes reward per token stored is up to date
    function newTokensOwed(Tick.Info memory tickInfo, uint24 tick) private view returns (uint256) {
        if (tick > currentTick) return 0;
        uint256 liquidity = tickInfo.liquidity;
        if (currentTick == tick) {
            liquidity = currentLiquidity;
        }
        uint256 owed = (liquidity * tick * (rewardPerINStored - tickInfo.rewardPerINPaid)) / 1 ether;
        return owed;
    }

    /// @dev Assumes reward per token stored is up to date
    function newTokensOwed(Position.Info memory position, Tick.Info memory tickInfo) private pure returns (uint256) {
        uint256 liquidity = position.liquidity;

        uint256 owed = (liquidity * (tickInfo.tokensOwedPerLiquidity - position.rewardPerLiquidityPaid)) / (1 ether);
        return owed;
    }
}
