pragma solidity ^0.8.4;

import "forge-std/console2.sol";

import { TestHelper } from "./utils/TestHelper.sol";
import { CallbackHelper } from "./utils/CallbackHelper.sol";

import { LendgineAddress } from "../src/libraries/LendgineAddress.sol";

import { Factory } from "../src/Factory.sol";
import { Lendgine } from "../src/Lendgine.sol";

contract InvariantTest is TestHelper {
    function setUp() public {
        _setUp();
    }

    function testLiquidityAmount() public {
        _pairMint(1 ether, 1 ether, cuh);

        assertEq(pair.totalSupply(), k);
        assertEq(pair.buffer(), k - pair.MINIMUM_LIQUIDITY());
    }

    function testBurnAmount() public {
        _pairMint(1 ether, 1 ether, cuh);
        uint256 amount0 = (1 ether * (k - pair.MINIMUM_LIQUIDITY())) / k;
        uint256 amount1 = (1 ether * (k - pair.MINIMUM_LIQUIDITY())) / k;
        pair.burn(cuh, amount0, amount1);

        assertEq(speculative.balanceOf(cuh), (1 ether * (k - pair.MINIMUM_LIQUIDITY())) / k);
        assertEq(base.balanceOf(cuh), (1 ether * (k - pair.MINIMUM_LIQUIDITY())) / k);

        assertEq(pair.totalSupply(), pair.MINIMUM_LIQUIDITY());
        assertEq(pair.buffer(), 0);
    }

    // function testDouble() public {
    //     _mintMaker(1 ether, 1 ether, 1, cuh);
    //     _pairMint(1_000_000, 1_000_000, dennis);

    //     uint256 k2 = 5 ether**2 + 1_000_000 - (5 ether - 1_000_000 / 2)**2;

    //     assertEq(pair.totalSupply(), k + k2);
    //     assertEq(pair.buffer(), k2);

    //     pair.burn(dennis);

    //     console2.log("s", speculative.balanceOf(dennis));
    //     console2.log("b", base.balanceOf(dennis));
    // }

    // test 2/3 1/3 burn
}
