// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import { Factory } from "./Factory.sol";
import { Pair } from "./Pair.sol";
import { ERC20 } from "./ERC20.sol";
import { JumpRate } from "./JumpRate.sol";

import { IMintCallback } from "./interfaces/IMintCallback.sol";
import { ILendgine } from "./interfaces/ILendgine.sol";

import { Position } from "./libraries/Position.sol";
import { LiquidityMath } from "./libraries/LiquidityMath.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";

contract Lendgine is ERC20, JumpRate, ILendgine {
    using Position for mapping(address => Position.Info);
    using Position for Position.Info;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Mint(address indexed sender, uint256 amountS, uint256 shares, uint256 liquidity, address indexed to);

    event Burn(address indexed sender, uint256 amountS, uint256 shares, uint256 liquidity, address indexed to);

    event Deposit(address indexed sender, uint256 liquidity, address indexed to);

    event Withdraw(address indexed sender, uint256 liquidity);

    event AccrueInterest(uint256 timeElapsed, uint256 amountS, uint256 liquidity, uint256 rewardPerLiquidity);

    event AccruePositionInterest(address indexed owner, uint256 rewardPerLiquidity, uint256 tokensOwed);

    event Collect(address indexed owner, address indexed to, uint256 amountBase);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ReentrancyError();

    error BalanceReturnError();

    error InsufficientInputError();

    error InsufficientOutputError();

    error CompleteUtilizationError();

    error InsufficientPositionError();

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendgine
    address public immutable override factory;

    /// @inheritdoc ILendgine
    address public immutable override pair;

    /*//////////////////////////////////////////////////////////////
                          LENDGINE STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendgine
    mapping(address => Position.Info) public override positions;

    /// @inheritdoc ILendgine
    uint256 public override totalLiquidity;

    /// @inheritdoc ILendgine
    uint256 public override totalLiquidityBorrowed;

    /// @inheritdoc ILendgine
    uint256 public override rewardPerLiquidityStored;

    /// @inheritdoc ILendgine
    uint64 public override lastUpdate;

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

        pair = address(new Pair{ salt: keccak256(abi.encode(address(this))) }(msg.sender));
    }

    /*//////////////////////////////////////////////////////////////
                            MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendgine
    function mint(
        address to,
        uint256 amountS,
        bytes calldata data
    ) external override lock returns (uint256 shares) {
        _accrueInterest();

        uint256 liquidity = convertAssetToLiquidity(amountS);
        shares = convertLiquidityToShare(liquidity);

        if (shares == 0) revert InsufficientOutputError();
        if (liquidity + totalLiquidityBorrowed > totalLiquidity) revert CompleteUtilizationError();
        if (totalSupply > 0 && totalLiquidityBorrowed == 0) revert CompleteUtilizationError();

        totalLiquidityBorrowed += liquidity;

        _mint(to, shares); // optimistically mint
        Pair(pair).addBuffer(liquidity);

        uint256 balanceBefore = balanceSpeculative();
        IMintCallback(msg.sender).MintCallback(amountS, data);
        uint256 balanceAfter = balanceSpeculative();
        if (balanceAfter < balanceBefore + amountS) revert InsufficientInputError();

        emit Mint(msg.sender, amountS, shares, liquidity, to);
    }

    /// @inheritdoc ILendgine
    function burn(address to) external override lock returns (uint256 amountS) {
        _accrueInterest();

        uint256 shares = balanceOf[address(this)];
        uint256 liquidity = convertShareToLiquidity(shares);
        amountS = convertLiquidityToAsset(liquidity);

        if (liquidity == 0) revert InsufficientOutputError();

        totalLiquidityBorrowed -= liquidity;

        _burn(address(this), shares);
        Pair(pair).removeBuffer(liquidity);
        SafeTransferLib.safeTransfer(Pair(pair).speculative(), to, amountS);

        emit Burn(msg.sender, amountS, shares, liquidity, to);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendgine
    function deposit(address to) external override lock {
        _accrueInterest();

        uint256 liquidity = Pair(pair).buffer();

        if (liquidity == 0) revert InsufficientOutputError();

        positions.update(to, int256(liquidity));
        totalLiquidity += liquidity;

        Pair(pair).removeBuffer(liquidity);
        emit Deposit(msg.sender, liquidity, to);
    }

    /// @inheritdoc ILendgine
    function withdraw(uint256 liquidity) external override lock {
        _accrueInterest();

        if (liquidity == 0) revert InsufficientOutputError();
        Position.Info memory positionInfo = positions.get(msg.sender);

        if (liquidity > positionInfo.liquidity) revert InsufficientPositionError();
        if (totalLiquidityBorrowed > totalLiquidity - liquidity) revert CompleteUtilizationError();

        positions.update(msg.sender, -int256(liquidity));
        totalLiquidity -= liquidity;

        Pair(pair).addBuffer(liquidity);
        emit Withdraw(msg.sender, liquidity);
    }

    /*//////////////////////////////////////////////////////////////
                            INTEREST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendgine
    function accrueInterest() external override lock {
        _accrueInterest();
    }

    /// @inheritdoc ILendgine
    function accruePositionInterest() external override lock {
        _accrueInterest();
        _accruePositionInterest(msg.sender);
    }

    /// @inheritdoc ILendgine
    function collect(address to, uint256 amountSRequested) external override lock returns (uint256 amountS) {
        Position.Info storage position = positions.get(msg.sender);

        amountS = amountSRequested > position.tokensOwed ? position.tokensOwed : amountSRequested;

        if (amountS > 0) {
            position.tokensOwed -= amountS;
            SafeTransferLib.safeTransfer(Pair(pair).speculative(), to, amountS);
        }

        emit Collect(msg.sender, to, amountS);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendgine
    function convertLiquidityToShare(uint256 liquidity) public view override returns (uint256) {
        uint256 _totalLiquidityBorrowed = totalLiquidityBorrowed;
        return _totalLiquidityBorrowed == 0 ? liquidity : (liquidity * totalSupply) / _totalLiquidityBorrowed;
    }

    /// @inheritdoc ILendgine
    function convertShareToLiquidity(uint256 shares) public view override returns (uint256) {
        return (totalLiquidityBorrowed * shares) / totalSupply;
    }

    /// @inheritdoc ILendgine
    function convertAssetToLiquidity(uint256 assets) public view override returns (uint256) {
        return (assets * 10**18) / (2 * Pair(pair).upperBound());
    }

    /// @inheritdoc ILendgine
    function convertLiquidityToAsset(uint256 liquidity) public view override returns (uint256) {
        return (2 * liquidity * Pair(pair).upperBound()) / 10**18;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEW
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendgine
    function balanceSpeculative() public view override returns (uint256) {
        bool success;
        bytes memory data;

        (success, data) = Pair(pair).speculative().staticcall(
            abi.encodeWithSelector(bytes4(keccak256(bytes("balanceOf(address)"))), address(this))
        );
        if (!success || data.length < 32) revert BalanceReturnError();

        return abi.decode(data, (uint256));
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL INTEREST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Helper function for accruing lendgine interest
    function _accrueInterest() private {
        if (totalSupply == 0 || totalLiquidityBorrowed == 0) {
            lastUpdate = uint64(block.timestamp);
            return;
        }

        uint256 _totalLiquidityBorrowed = totalLiquidityBorrowed; // SLOAD
        uint256 _totalLiquidity = totalLiquidity; //SLOAD

        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed == 0) return;

        // assuming dpr
        uint256 borrowRate = getBorrowRate(_totalLiquidityBorrowed, _totalLiquidity);

        uint256 dilutionLPRequested = (borrowRate * _totalLiquidityBorrowed * timeElapsed) / (1 ether * 1 days);
        uint256 dilutionLP = dilutionLPRequested > _totalLiquidityBorrowed
            ? _totalLiquidityBorrowed
            : dilutionLPRequested;

        uint256 dilutionSpeculative = convertLiquidityToAsset(dilutionLP);
        rewardPerLiquidityStored += (dilutionSpeculative * 1 ether) / _totalLiquidity;

        totalLiquidityBorrowed = _totalLiquidityBorrowed - dilutionLP;
        lastUpdate = uint64(block.timestamp);

        emit AccrueInterest(timeElapsed, dilutionSpeculative, dilutionLP, rewardPerLiquidityStored);
    }

    /// @notice Helper function for accruing interest to a position
    /// @dev Assume the global interest is up to date
    /// @param owner The address that this position belongs to
    function _accruePositionInterest(address owner) private {
        Position.Info storage position = positions[owner];
        Position.Info memory _position = position;

        uint256 _rewardPerLiquidityStored = rewardPerLiquidityStored; // SLOAD

        uint256 tokensOwed = newTokensOwed(_position, _rewardPerLiquidityStored);

        position.rewardPerLiquidityPaid = _rewardPerLiquidityStored;
        position.tokensOwed = _position.tokensOwed + tokensOwed;

        emit AccruePositionInterest(owner, _rewardPerLiquidityStored, tokensOwed);
    }

    /// @notice Helper function for determining the amount of tokens owed to a position
    /// @dev Assumes the global interest is up to date
    function newTokensOwed(Position.Info memory position, uint256 _rewardPerLiquidity) private pure returns (uint256) {
        uint256 liquidity = position.liquidity;

        return (liquidity * (_rewardPerLiquidity - position.rewardPerLiquidityPaid)) / (1 ether);
    }
}
