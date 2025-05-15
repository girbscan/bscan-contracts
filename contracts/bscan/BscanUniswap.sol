// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;
pragma abicoder v2;

import "./BscanPump.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../common/IMintableERC20.sol";
import "../multisign/MultiSignOwnable.sol";
import "../uniswap/INonfungiblePositionManager.sol";
import "../uniswap/UniswapUtil.sol";
import "../uniswap/interfaces/pool/IUniswapV3PoolState.sol";

abstract contract BscanUniswap is BscanPump {
    using SafeERC20 for IMintableERC20;

    uint24 public constant UNISWAP_POOL_FEE = 3000;
    INonfungiblePositionManager public immutable uniswapV3PositionManager;
    address public uniswapPool;
    uint256 public positionTokenId;

    int24 public initialPriceTick;

    constructor(
        address multiSignAdmin,
        address initialBscan,
        address initialUsdt,
        address initialFeeReceiver,
        uint initialVirtualBscanAmount,
        uint initialVirtualUsdtAmount,
        address initialUniswapV3PositionManager
    )
        BscanPump(
            multiSignAdmin,
            initialBscan,
            initialUsdt,
            initialFeeReceiver,
            initialVirtualBscanAmount,
            initialVirtualUsdtAmount
        )
    {
        uniswapV3PositionManager = INonfungiblePositionManager(
            initialUniswapV3PositionManager
        );
    }

    function _finishPump() internal override {
        super._finishPump();
        _addLiquidity();
    }

    uint public supplyMinted;
    function _mintSupply() internal {
        if (supplyMinted == 0) {
            usdt.approve(address(uniswapV3PositionManager), type(uint256).max);
            bscan.approve(address(uniswapV3PositionManager), type(uint256).max);

            supplyMinted = _calcInjectBscanAmount();
            bscan.mint(
                address(this),
                supplyMinted + bscanSupply + bscanSoldSupply
            );
        }
    }

    function _getPoolTokens()
        internal
        view
        returns (address token0, address token1, uint balance0, uint balance1)
    {
        (token0, token1) = UniswapUtil.sortPoolTokens(
            address(bscan),
            address(usdt)
        );
        (balance0, balance1) = token0 == address(usdt)
            ? (usdtBalance, supplyMinted)
            : (supplyMinted, usdtBalance);
    }

    function _getCreatePoolParams()
        internal
        view
        returns (
            address token0,
            address token1,
            uint24 fee,
            uint160 sqrtPriceX96,
            int24 priceTick,
            uint balance0,
            uint balance1
        )
    {
        (token0, token1, balance0, balance1) = _getPoolTokens();
        fee = UNISWAP_POOL_FEE;
        priceTick = UniswapUtil.getTickAtSqrtPriceX96(
            UniswapUtil.getRawSqrtPriceX96(balance0, balance1)
        );
        sqrtPriceX96 = UniswapUtil.getSqrtPriceX96AtTick(priceTick);
    }

    function _createPool() internal {
        if (uniswapPool != address(0)) {
            return;
        }

        (
            address token0,
            address token1,
            uint24 fee,
            uint160 sqrtPriceX96,
            int24 priceTick,
            ,

        ) = _getCreatePoolParams();

        initialPriceTick = priceTick;

        uniswapPool = uniswapV3PositionManager
            .createAndInitializePoolIfNecessary(
                token0,
                token1,
                fee,
                sqrtPriceX96
            );
    }

    function _getMintParams()
        internal
        view
        returns (INonfungiblePositionManager.MintParams memory)
    {
        (
            address token0,
            address token1,
            uint balance0,
            uint balance1
        ) = _getPoolTokens();
        (int24 tickLower, int24 tickUpper) = UniswapUtil.getMinMaxTick(
            UNISWAP_POOL_FEE
        );
        return
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: UNISWAP_POOL_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: balance0,
                amount1Desired: balance1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 100
            });
    }
    function _uniswapMint()
        internal
        returns (
            uint tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        (tokenId, liquidity, amount0, amount1) = uniswapV3PositionManager.mint(
            _getMintParams()
        );
        positionTokenId = tokenId;
    }

    function _getIncreaseLiquidityParams()
        internal
        view
        returns (INonfungiblePositionManager.IncreaseLiquidityParams memory)
    {
        (, , uint balance0, uint balance1) = _getPoolTokens();
        return
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionTokenId,
                amount0Desired: balance0,
                amount1Desired: balance1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            });
    }
    function _increaseLiquidity() internal {
        uniswapV3PositionManager.increaseLiquidity(
            _getIncreaseLiquidityParams()
        );
    }

    function _addLiquidity() internal {
        _mintSupply();
        if (uniswapPool == address(0)) {
            _createPool();
        }

        (
            ,
            //uint160 sqrtPriceX96,
            int24 tick, //uint16 observationIndex, //uint16 observationCardinality //uint16 observationCardinalityNext //uint8 feeProtocol //bool unlocked
            ,
            ,
            ,
            ,

        ) = IUniswapV3PoolState(uniswapPool).slot0();

        require(
            tick >= initialPriceTick - 10 && tick <= initialPriceTick + 10,
            "invalid price range"
        );

        if (positionTokenId == 0) {
            _uniswapMint();
        } else {
            _increaseLiquidity();
        }

        uint256 usdtRemaining = usdt.balanceOf(address(this));
        if (usdtRemaining > 0) {
            usdt.safeTransfer(feeReceiver, usdtRemaining);
        }
    }

    function _poolCollect(address recipient) internal {
        uniswapV3PositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionTokenId,
                recipient: recipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    function _poolRefund(address recipient) internal {
        uniswapV3PositionManager.sweepToken(address(bscan), 0, recipient);
        uniswapV3PositionManager.sweepToken(address(usdt), 0, recipient);
    }

    function _sqrtPriceX96ToE18(
        uint256 sqrtPriceX96,
        bool reverse
    ) internal pure returns (uint) {
        if (reverse) {
            return Math.mulDiv(2 ** 192, 1 ether, sqrtPriceX96) / sqrtPriceX96; //token0/token1;
        } else {
            return Math.mulDiv(sqrtPriceX96 * 1 ether, sqrtPriceX96, 2 ** 192); //token1/token0
        }
    }

    function _uniswapBscanPrice() internal view returns (uint) {
        if (uniswapPool == address(0)) {
            return 0;
        }
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3PoolState(uniswapPool)
            .slot0();
        (address token0, , , ) = _getPoolTokens();
        return
            _sqrtPriceX96ToE18(uint256(sqrtPriceX96), token0 == address(usdt));
    }

    function uniswapCollect(
        address recipient
    ) external onlyMultiSignAuthorized {
        require(
            uniswapPool != address(0) && positionTokenId != 0,
            "Invalid status"
        );
        _poolCollect(recipient);
        _poolRefund(recipient);
    }

    function _decreaseLiquidity(address recipient) internal {
        require(uniswapPool != address(0), "Pool not created");
        require(positionTokenId != 0, "No position token id");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            //uint96 nonce
            //address operator
            //address token0
            //address token1
            //uint24 fee
            //int24 tickLower
            //int24 tickUpper
            uint128 liquidity, //uint256 feeGrowthInside0LastX128 //uint256 feeGrowthInside1LastX128 //uint128 tokensOwed0 //uint128 tokensOwed1
            ,
            ,
            ,

        ) = uniswapV3PositionManager.positions(positionTokenId);

        uniswapV3PositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionTokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 100
            })
        );

        _poolCollect(recipient);
        _poolRefund(recipient);
    }
}
