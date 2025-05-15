// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;
pragma abicoder v2;

import "./BscanUniswap.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract BscanMining is BscanUniswap, EIP712 {
    using SafeERC20 for IMintableERC20;

    constructor(
        address multiSignAdmin,
        address initialBscan,
        address initialUsdt,
        address initialFeeReceiver,
        uint initialVirtualBscanAmount,
        uint initialVirtualUsdtAmount,
        address initialUniswapV3PositionManager
    )
        EIP712("BscanMining", "1.0")
        BscanUniswap(
            multiSignAdmin,
            initialBscan,
            initialUsdt,
            initialFeeReceiver,
            initialVirtualBscanAmount,
            initialVirtualUsdtAmount,
            initialUniswapV3PositionManager
        )
    {}

    mapping(address => uint) public usersSettledMiningIncome;
    mapping(address => uint) public usersTotalMiningIncome;

    address public constant BURN_ADDRESS =
        0x00000000000000000000000000000000000000ff;
    uint public projectFeeRate = 2 * 10 ** 16; //2%
    uint public burnRate = 3 * 10 ** 16; // 3%
    event MiningIncomePumpSell(
        address indexed seller,
        uint bscanWithFee,
        uint fee,
        uint burn,
        uint usdtNetOut,
        uint usdtFee,
        uint timestamp
    );

    function calcSellMiningIncome(
        uint bscanWithFee
    )
        public
        view
        returns (
            uint usdtFee,
            uint usdtNetOut,
            uint bscanPrice0,
            uint bscanPrice1,
            uint slippage,
            uint projectFee,
            uint burned
        )
    {
        projectFee = Math.mulDiv(bscanWithFee, projectFeeRate, 1 ether);
        burned = Math.mulDiv(bscanWithFee, burnRate, 1 ether);
        uint netBscan = bscanWithFee - projectFee - burned;
        (usdtFee, usdtNetOut, bscanPrice0, bscanPrice1, slippage) = calcSell(
            netBscan
        );
    }

    function _pumpSellMiningIncome(
        address seller,
        uint bscanWithFee
    )
        internal
        returns (
            uint usdtFee,
            uint usdtNetOut,
            uint bscanPrice0,
            uint bscanPrice1,
            uint slippage,
            uint projectFee,
            uint burned
        )
    {
        uint available = usersTotalMiningIncome[seller] >=
            usersSettledMiningIncome[seller]
            ? usersTotalMiningIncome[seller] - usersSettledMiningIncome[seller]
            : 0;

        bscanWithFee = bscanWithFee == 0 ? available : bscanWithFee;
        require(
            available >= bscanWithFee && bscanWithFee > 0,
            "insufficient mining income"
        );

        projectFee = Math.mulDiv(bscanWithFee, projectFeeRate, 1 ether);
        burned = Math.mulDiv(bscanWithFee, burnRate, 1 ether);
        uint netBscan = bscanWithFee - projectFee - burned;

        bscan.mint(BURN_ADDRESS, burned);
        bscan.mint(feeReceiver, projectFee);

        usersSupply[seller] += netBscan;
        usersSettledMiningIncome[seller] += bscanWithFee;

        (usdtFee, usdtNetOut, bscanPrice0, bscanPrice1, slippage) = _sell(
            seller,
            netBscan
        );

        emit MiningIncomePumpSell(
            seller,
            bscanWithFee,
            projectFee,
            burned,
            usdtNetOut,
            usdtFee,
            block.timestamp
        );
    }

    function pumpSellMiningIncome(
        uint bscanWithFee
    )
        external
        returns (
            uint usdtFee,
            uint usdtNetOut,
            uint bscanPrice0,
            uint bscanPrice1,
            uint slippage,
            uint projectFee,
            uint burned
        )
    {
        return _pumpSellMiningIncome(msg.sender, bscanWithFee);
    }

    event MiningIncomeWithdraw(
        address indexed user,
        uint bscanWithFee,
        uint fee,
        uint burn,
        uint timestamp
    );

    function _withdrawMiningIncome(
        address user,
        uint bscanWithFee
    ) internal returns (uint netBscanOut, uint projectFee, uint burned) {
        require(releaseStartTime > 0, "release not started");
        uint available = usersTotalMiningIncome[user] >=
            usersSettledMiningIncome[user]
            ? usersTotalMiningIncome[user] - usersSettledMiningIncome[user]
            : 0;

        uint amount = bscanWithFee == 0 ? available : bscanWithFee;
        require(
            available >= amount && amount > 0,
            "insufficient mining income"
        );
        projectFee = Math.mulDiv(amount, projectFeeRate, 1 ether);
        burned = Math.mulDiv(amount, burnRate, 1 ether);
        netBscanOut = amount - projectFee - burned;

        bscan.mint(feeReceiver, projectFee);
        bscan.mint(BURN_ADDRESS, burned);
        bscan.mint(user, netBscanOut);
        usersSettledMiningIncome[user] += amount;

        emit MiningIncomeWithdraw(
            user,
            bscanWithFee,
            projectFee,
            burned,
            block.timestamp
        );
    }

    function withdrawMiningIncome(
        uint bscanWithFee
    ) external returns (uint netBscanOut, uint projectFee, uint burned) {
        return _withdrawMiningIncome(msg.sender, bscanWithFee);
    }

    address public signerAddress1;
    address public signerAddress2;

    function setSignerAddress(
        address newSignerAddress1,
        address newSignerAddress2
    ) external onlyMultiSignAuthorized {
        signerAddress1 = newSignerAddress1;
        signerAddress2 = newSignerAddress2;
    }

    bytes32 public constant DATA_TYPE_HASH =
        keccak256(
            "Data(address signerAddress1,address signerAddress2,address account,uint256 totalMiningIncome,uint256 deadline)"
        );

    function _calcDigest(
        address account,
        uint totalMiningIncome,
        uint deadline
    ) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        DATA_TYPE_HASH,
                        signerAddress1,
                        signerAddress2,
                        account,
                        totalMiningIncome,
                        deadline
                    )
                )
            );
    }

    function checkSignature(
        address account,
        uint totalMiningIncome,
        uint deadline,
        bytes memory signature1,
        bytes memory signature2
    ) public view returns (bool) {
        return
            signerAddress1 ==
            ECDSA.recover(
                _calcDigest(account, totalMiningIncome, deadline),
                signature1
            ) &&
            signerAddress2 ==
            ECDSA.recover(
                _calcDigest(account, totalMiningIncome, deadline),
                signature2
            );
    }

    function updateMiningIncome(
        uint totalMiningIncome,
        uint deadline,
        bytes memory signature1,
        bytes memory signature2
    ) public {
        require(
            usersTotalMiningIncome[msg.sender] <= totalMiningIncome,
            "income cannot be reduced"
        );
        require(deadline > block.timestamp, "signature expired");
        require(
            checkSignature(
                msg.sender,
                totalMiningIncome,
                deadline,
                signature1,
                signature2
            ),
            "invalid signature"
        );
        usersTotalMiningIncome[msg.sender] = totalMiningIncome;
    }

    function updateMiningIncomeAndWithdraw(
        uint bscanWithFee,
        uint totalMiningIncome,
        uint deadline,
        bytes memory signature1,
        bytes memory signature2
    ) external {
        updateMiningIncome(totalMiningIncome, deadline, signature1, signature2);
        _withdrawMiningIncome(msg.sender, bscanWithFee);
    }

    function updateMiningIncomeAndPumpSell(
        uint bscanWithFee,
        uint totalMiningIncome,
        uint deadline,
        bytes memory signature1,
        bytes memory signature2
    ) external {
        updateMiningIncome(totalMiningIncome, deadline, signature1, signature2);
        _pumpSellMiningIncome(msg.sender, bscanWithFee);
    }

    struct Mining {
        uint principal;
        uint startTimestamp;
        uint withdrawn;
    }

    mapping(address => Mining) public usersMining;

    event MiningPrincipalDeposit(
        address indexed user,
        uint bscanAmount,
        uint principal,
        uint timestamp
    );

    function getReleasedPrincipal(
        address user
    ) public view returns (uint releasedPrincipal) {
        releasedPrincipal = Math.mulDiv(
            usersMining[user].principal + usersMining[user].withdrawn,
            _calcReleasedPercent(
                usersMining[user].startTimestamp,
                releaseDuration,
                block.timestamp
            ),
            1 ether
        );
    }

    function depositForMining(uint bscanAmount) external {
        address user = msg.sender;
        bscan.safeTransferFrom(user, address(this), bscanAmount);
        usersMining[user].withdrawn = 0;

        usersMining[user].principal += bscanAmount;
        usersMining[user].startTimestamp = block.timestamp;
        emit MiningPrincipalDeposit(
            user,
            bscanAmount,
            usersMining[user].principal,
            block.timestamp
        );
    }

    event MiningPrincipalWithdraw(
        address indexed user,
        uint bscanAmount,
        uint principal,
        uint timestamp
    );

    function withdrawMiningPrincipal(uint bscanAmount) external {
        address user = msg.sender;
        uint totalReleased = getReleasedPrincipal(user);
        uint available = totalReleased > usersMining[user].withdrawn
            ? totalReleased - usersMining[user].withdrawn
            : 0;
        bscanAmount = bscanAmount == 0 ? available : bscanAmount;
        require(bscanAmount <= usersMining[user].principal, "exceed principal");
        require(
            available >= bscanAmount && bscanAmount > 0,
            "exceed total released"
        );
        bscan.safeTransfer(user, bscanAmount);
        usersMining[user].principal -= bscanAmount;
        usersMining[user].withdrawn += bscanAmount;
        emit MiningPrincipalWithdraw(
            user,
            bscanAmount,
            usersMining[user].principal,
            block.timestamp
        );
    }

    struct PumpInfo {
        uint maxSlippage;
        uint endTimestamp;
        uint maxSupply;
        uint virtualBscan;
        uint virtualUsdt;
        address bscan;
        address usdt;
        uint tradingFeeRate;
        address feeReceiver;
        uint bscanSupply;
        uint usdtBalance;
        uint bscanSoldSupply;
        uint bscanPrice;
        uint releaseDuration;
        uint releaseStartTime;
        uint releasedPercent;
        uint projectFeeRate;
        uint burnRate;
        address signerAddress1;
        address signerAddress2;
        address uniswapPool;
        uint positionTokenId;
        address uniswapV3PositionManager;
        uint supplyMinted;
        uint timestamp;
    }

    function getPumpInfo() external view returns (PumpInfo memory info) {
        info.maxSlippage = maxSlippage;
        info.endTimestamp = endTimestamp;
        info.maxSupply = maxSupply;
        info.virtualBscan = virtualBscan;
        info.virtualUsdt = virtualUsdt;
        info.bscan = address(bscan);
        info.usdt = address(usdt);
        info.tradingFeeRate = tradingFeeRate;
        info.feeReceiver = feeReceiver;
        info.bscanSupply = bscanSupply;
        info.usdtBalance = usdtBalance;
        info.bscanSoldSupply = bscanSoldSupply;
        info.bscanPrice = uniswapPool != address(0)
            ? _uniswapBscanPrice()
            : _bscanPumpPrice();
        info.releaseDuration = releaseDuration;
        info.releaseStartTime = releaseStartTime;
        info.releasedPercent = pumpReleasedPercent();
        info.projectFeeRate = projectFeeRate;
        info.burnRate = burnRate;
        info.signerAddress1 = signerAddress1;
        info.signerAddress2 = signerAddress2;
        info.uniswapPool = uniswapPool;
        info.positionTokenId = positionTokenId;
        info.uniswapV3PositionManager = address(uniswapV3PositionManager);
        info.supplyMinted = supplyMinted;
        info.timestamp = block.timestamp;
    }

    struct UserInfo {
        uint supply;
        uint supplyWithdrawn;
        uint supplyAvailable;
        uint usdtBalance;
        uint bscanBalance;
        uint settledMiningIncome;
        uint totalMiningIncome;
        uint principal;
        uint releasedPrincipal;
        uint startTimestamp;
        uint principalWithdrawn;
        uint timestamp;
    }

    function getUserInfo(
        address user
    ) external view returns (UserInfo memory info) {
        info.supply = usersSupply[user];
        info.supplyWithdrawn = usersSupplyWithdrawn[user];
        info.supplyAvailable = getWithdrawAvaliable(user);

        info.usdtBalance = usdt.balanceOf(user);
        info.bscanBalance = bscan.balanceOf(user);
        info.settledMiningIncome = usersSettledMiningIncome[user];
        info.totalMiningIncome = usersTotalMiningIncome[user];

        info.principal = usersMining[user].principal;
        info.releasedPrincipal = getReleasedPrincipal(user);
        info.startTimestamp = usersMining[user].startTimestamp;
        info.principalWithdrawn = usersMining[user].withdrawn;

        info.timestamp = block.timestamp;
    }
}
