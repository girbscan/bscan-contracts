// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../common/IMintableERC20.sol";
import "../INonfungiblePositionManager.sol";

contract MockUniswapV3PositionManager is ERC721 {
    address public t0;
    address public t1;
    uint24 poolFee;
    uint160 price;

    constructor()
        ERC721("MockUniswapV3PositionManager", "MockUniswapV3PositionManager")
    {}
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool) {
        t0 = token0;
        t1 = token1;
        poolFee = fee;
        price = sqrtPriceX96;
        pool = address(uint160(uint160(token0) ^ uint160(token1)));
    }

    function mint(
        MintParams calldata params
    )
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        tokenId = 1;
        IMintableERC20(params.token0).transferFrom(
            msg.sender,
            address(this),
            params.amount0Desired
        );
        IMintableERC20(params.token1).transferFrom(
            msg.sender,
            address(this),
            params.amount1Desired
        );
        amount0 = IMintableERC20(params.token0).balanceOf(address(this));
        amount1 = IMintableERC20(params.token1).balanceOf(address(this));
        liquidity = uint128(Math.mulDiv(amount0, amount1, 1 ether));
    }

    function increaseLiquidity(
        IncreaseLiquidityParams calldata params
    )
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        IMintableERC20(t0).transferFrom(
            msg.sender,
            address(this),
            params.amount0Desired
        );
        IMintableERC20(t1).transferFrom(
            msg.sender,
            address(this),
            params.amount1Desired
        );
        amount0 = IMintableERC20(t0).balanceOf(address(this));
        amount1 = IMintableERC20(t1).balanceOf(address(this));
        liquidity = uint128(Math.mulDiv(amount0, amount1, 1 ether));
    }

    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1) {
        amount0 = IMintableERC20(t0).balanceOf(address(this)) / 2;
        amount1 = IMintableERC20(t1).balanceOf(address(this)) / 2;

        IMintableERC20(t0).transfer(params.recipient, amount0);
        IMintableERC20(t1).transfer(params.recipient, amount1);
    }
}
