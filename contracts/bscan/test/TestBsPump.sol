// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;
pragma abicoder v2;

import "../BscanMining.sol";

contract TestBsPump is BscanMining {
    constructor(
        address multiSignAdmin,
        address initialBscan,
        address initialUsdt,
        address initialFeeReceiver,
        uint initialVirtualBscanAmount,
        uint initialVirtualUsdtAmount,
        address initialUniswapV3PositionManager
    )
        BscanMining(
            multiSignAdmin,
            initialBscan,
            initialUsdt,
            initialFeeReceiver,
            initialVirtualBscanAmount,
            initialVirtualUsdtAmount,
            initialUniswapV3PositionManager
        )
    {}

    function sell(
        uint bscanIn
    )
        external
        returns (
            uint usdtFee,
            uint usdtNetOut,
            uint bscanPrice0,
            uint bscanPrice1,
            uint slippage
        )
    {
        return _sell(msg.sender, bscanIn);
    }

    function removeLiquidity(
        address recipient
    ) external onlyMultiSignAuthorized {
        _decreaseLiquidity(recipient);
    }

    function adminWithdrawFor(
        address token,
        address payable to,
        uint amount
    ) external onlyMultiSignAuthorized {
        if (token == address(0)) {
            to.transfer(amount);
        } else {
            IMintableERC20(token).transfer(to, amount);
        }
    }

    function setEndTimestamp(
        uint newEndTimestamp
    ) external onlyMultiSignAuthorized {
        endTimestamp = newEndTimestamp;
    }

    function setMaxSupply(uint newMaxSupply) external onlyMultiSignAuthorized {
        maxSupply = newMaxSupply;
    }
    function setMaxSlippage(
        uint newMaxSlippage
    ) external onlyMultiSignAuthorized {
        maxSlippage = newMaxSlippage;
    }

    function setFeeRate(
        uint newTradingFeeRate,
        uint newProjectFeeRate,
        uint newBurnRate
    ) external onlyMultiSignAuthorized {
        tradingFeeRate = newTradingFeeRate;
        projectFeeRate = newProjectFeeRate;
        burnRate = newBurnRate;
    }

    function setReleaseDuration(
        uint newReleaseDuration
    ) external onlyMultiSignAuthorized {
        releaseDuration = newReleaseDuration;
    }
}
