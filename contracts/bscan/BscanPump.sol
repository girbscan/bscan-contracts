// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

import "../common/IMintableERC20.sol";
import "../multisign/MultiSignOwnable.sol";

abstract contract BscanPump is MultiSignOwnable {
    using SafeERC20 for IMintableERC20;

    uint public maxSlippage = 10 * 10 ** 16; //10%
    uint public endTimestamp = block.timestamp + 183 days;
    uint public maxSupply = 35 * 10 ** 25;

    uint internal immutable virtualBscan;
    uint internal immutable virtualUsdt;

    IMintableERC20 public immutable bscan;
    IMintableERC20 public immutable usdt;

    uint public tradingFeeRate = 1 * 10 ** 16; // 1%
    address public feeReceiver;

    mapping(address => uint) public usersSupply;
    uint public bscanSoldSupply;
    uint public bscanSupply;
    uint public usdtBalance;

    constructor(
        address multiSignAdmin,
        address initialBscan,
        address initialUsdt,
        address initialFeeReceiver,
        uint initialVirtualBscanAmount,
        uint initialVirtualUsdtAmount
    ) MultiSignOwnable(multiSignAdmin) {
        bscan = IMintableERC20(initialBscan);
        usdt = IMintableERC20(initialUsdt);
        require(
            bscan.decimals() == 18 && usdt.decimals() == 18,
            "invalid decimals"
        );
        require(
            initialVirtualBscanAmount > 0 && initialVirtualUsdtAmount > 0,
            "invalid args"
        );

        virtualBscan = initialVirtualBscanAmount;
        virtualUsdt = initialVirtualUsdtAmount;
        feeReceiver = initialFeeReceiver;
    }

    function _calcCurve(
        uint x,
        uint dx,
        uint y
    ) internal pure returns (uint dy) {
        // K = x * y = ( x + dx ) * ( y - dy );
        // dy = y - K / ( x + dx);
        // dy = y - ( x * y ) / (x + dx);
        dy = y - Math.mulDiv(x, y, x + dx);
    }

    function _calcCurve2(
        uint x,
        uint dy,
        uint y
    ) internal pure returns (uint dx) {
        // K = x * y = ( x + dx ) * ( y - dy );
        // dx = K / ( y - dy) - x;
        // dx = (x * y) / (y - dy);
        dx = Math.mulDiv(x, y, y - dy) - x;
    }

    function calcUsdtRequiredWithFee(
        uint bscanOut
    ) public view returns (uint usdtNetIn, uint usdtFee) {
        usdtNetIn = _calcCurve2(
            usdtBalance + virtualUsdt,
            bscanOut,
            virtualBscan - bscanSupply
        );
        usdtFee =
            Math.mulDiv(usdtNetIn, 1 ether, 1 ether - tradingFeeRate) -
            usdtNetIn;
    }

    function _calcBscanOut(uint usdtIn) internal view returns (uint bscanOut) {
        bscanOut = _calcCurve(
            usdtBalance + virtualUsdt,
            usdtIn,
            virtualBscan - bscanSupply
        );
    }

    function _calcUsdtOut(uint bscanIn) internal view returns (uint usdtOut) {
        usdtOut = _calcCurve(
            virtualBscan - bscanSupply,
            bscanIn,
            usdtBalance + virtualUsdt
        );
    }

    function _calcInjectBscanAmount() internal view returns (uint bscanAmount) {
        bscanAmount = Math.mulDiv(
            usdtBalance,
            virtualBscan - bscanSupply,
            usdtBalance + virtualUsdt
        );
    }

    function _bscanPumpPrice() internal view returns (uint) {
        return
            Math.mulDiv(
                usdtBalance + virtualUsdt,
                1 ether,
                virtualBscan - bscanSupply
            );
    }

    event PumpBuy(
        address indexed buyer,
        uint usdtNetIn,
        uint bscanOut,
        uint usdtFee,
        uint supply,
        uint bscanPrice0,
        uint bscanPrice1,
        uint timestamp
    );

    function calcBuy(
        uint usdtInWithFee
    )
        public
        view
        returns (
            uint usdtNetIn,
            uint usdtFee,
            uint bscanOut,
            uint bscanPrice0,
            uint bscanPrice1,
            uint slippage
        )
    {
        require(releaseStartTime == 0 || bscanSupply >= maxSupply, "finished");

        usdtFee = Math.mulDiv(usdtInWithFee, tradingFeeRate, 1 ether);
        usdtNetIn = usdtInWithFee - usdtFee;
        bscanOut = _calcBscanOut(usdtNetIn);
        if (bscanOut + bscanSupply > maxSupply) {
            bscanOut = maxSupply - bscanSupply;
            (usdtNetIn, usdtFee) = calcUsdtRequiredWithFee(bscanOut);
        }

        bscanPrice0 = Math.mulDiv(
            usdtBalance + virtualUsdt,
            1 ether,
            virtualBscan - bscanSupply
        );

        bscanPrice1 = Math.mulDiv(
            (usdtBalance + usdtNetIn) + virtualUsdt,
            1 ether,
            virtualBscan - (bscanSupply + bscanOut)
        );
        slippage = Math.mulDiv(bscanPrice1, 1 ether, bscanPrice0);
    }

    function buy(
        uint usdtInWithFee
    )
        external
        returns (
            uint usdtNetIn,
            uint usdtFee,
            uint bscanOut,
            uint bscanPrice0,
            uint bscanPrice1,
            uint slippage
        )
    {
        address buyer = msg.sender;
        (
            usdtNetIn,
            usdtFee,
            bscanOut,
            bscanPrice0,
            bscanPrice1,
            slippage
        ) = calcBuy(usdtInWithFee);

        usdt.safeTransferFrom(buyer, address(this), usdtNetIn);
        usdt.safeTransferFrom(buyer, feeReceiver, usdtFee);

        bscanSupply += bscanOut;
        usdtBalance += usdtNetIn;
        usersSupply[buyer] += bscanOut;

        emit PumpBuy(
            buyer,
            usdtNetIn,
            bscanOut,
            usdtFee,
            usersSupply[buyer],
            bscanPrice0,
            bscanPrice1,
            block.timestamp
        );

        if (block.timestamp >= endTimestamp || bscanSupply >= maxSupply) {
            _finishPump();
        }
    }

    event PumpSell(
        address indexed seller,
        uint bscanIn,
        uint usdtNetOut,
        uint usdtFee,
        uint supply,
        uint bscanPrice0,
        uint bscanPrice1,
        uint timestamp
    );

    function calcSell(
        uint bscanIn
    )
        public
        view
        returns (
            uint usdtFee,
            uint usdtNetOut,
            uint bscanPrice0,
            uint bscanPrice1,
            uint slippage
        )
    {
        require(releaseStartTime == 0, "finished");
        require(bscanIn <= bscanSupply, "insufficient supply");

        uint usdtOutWithFee = _calcUsdtOut(bscanIn);
        usdtFee = Math.mulDiv(usdtOutWithFee, tradingFeeRate, 1 ether);
        usdtNetOut = usdtOutWithFee - usdtFee;
        require(usdtBalance >= usdtOutWithFee, "insufficient usdt balance");

        bscanPrice0 = Math.mulDiv(
            usdtBalance + virtualUsdt,
            1 ether,
            virtualBscan - bscanSupply
        );

        bscanPrice1 = Math.mulDiv(
            (usdtBalance - usdtOutWithFee) + virtualUsdt,
            1 ether,
            virtualBscan - (bscanSupply - bscanIn)
        );
        slippage = Math.mulDiv(bscanPrice1, 1 ether, bscanPrice0);
        require(slippage + maxSlippage >= 1 ether, "exceed max slippage");
    }

    function _sell(
        address seller,
        uint bscanIn
    )
        internal
        returns (
            uint usdtFee,
            uint usdtNetOut,
            uint bscanPrice0,
            uint bscanPrice1,
            uint slippage
        )
    {
        require(bscanIn <= usersSupply[seller], "insufficient balance");
        (usdtFee, usdtNetOut, bscanPrice0, bscanPrice1, slippage) = calcSell(
            bscanIn
        );

        usdt.safeTransfer(feeReceiver, usdtFee);
        usdt.safeTransfer(seller, usdtNetOut);

        bscanSoldSupply += bscanIn;
        bscanSupply -= bscanIn;
        usdtBalance -= usdtFee + usdtNetOut;
        usersSupply[seller] -= bscanIn;

        emit PumpSell(
            seller,
            bscanIn,
            usdtNetOut,
            usdtFee,
            usersSupply[seller],
            bscanPrice0,
            bscanPrice1,
            block.timestamp
        );

        if (block.timestamp >= endTimestamp || bscanSupply >= maxSupply) {
            _finishPump();
        }
    }

    uint public releaseDuration = 180 days;
    uint public releaseStartTime;

    function _finishPump() internal virtual {
        releaseStartTime = block.timestamp;
        //inject to uniswap;
    }

    function _calcReleasedPercent(
        uint startTimestamp,
        uint duration,
        uint curTimestamp
    ) internal pure returns (uint) {
        if (startTimestamp == 0 || startTimestamp >= curTimestamp) {
            return 0;
        }
        uint releasedTime = curTimestamp - startTimestamp;
        if (releasedTime >= duration) {
            return 1 ether;
        }
        return Math.mulDiv(releasedTime, 1 ether, duration);
    }

    function pumpReleasedPercent() public view returns (uint) {
        return
            _calcReleasedPercent(
                releaseStartTime,
                releaseDuration,
                block.timestamp
            );
    }

    event PumpWithdraw(
        address indexed user,
        uint withdrawAmount,
        uint supply,
        uint timestamp
    );
    mapping(address => uint) public usersSupplyWithdrawn;
    function getWithdrawAvaliable(address user) public view returns (uint) {
        uint totalReleased = Math.mulDiv(
            usersSupply[user] + usersSupplyWithdrawn[user],
            pumpReleasedPercent(),
            1 ether
        );
        return
            totalReleased <= usersSupplyWithdrawn[user]
                ? 0
                : totalReleased - usersSupplyWithdrawn[user];
    }

    function withdrawBscanSupply(
        uint withdrawAmount
    ) external returns (uint amount, uint supply) {
        address user = msg.sender;
        uint availableAmount = getWithdrawAvaliable(user);
        amount = withdrawAmount == 0 ? availableAmount : withdrawAmount;
        require(
            availableAmount >= amount && amount > 0,
            "insufficient released supply"
        );
        bscan.safeTransfer(user, amount);
        usersSupplyWithdrawn[user] += amount;
        usersSupply[user] -= amount;
        supply = usersSupply[user];
        emit PumpWithdraw(user, amount, supply, block.timestamp);
    }

    function setFeeReceiver(
        address newFeeReceiver
    ) external onlyMultiSignAuthorized {
        feeReceiver = newFeeReceiver;
    }
}
