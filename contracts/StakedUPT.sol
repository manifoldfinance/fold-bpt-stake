// SPDX-License-Identifier: MIT

pragma solidity =0.7.6;

import "./Owned.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "@solmate/utils/ReentrancyGuard.sol";

/**
 * @title StakedUPT
 * @dev StakedUPT is a contract that lock users' Uniswap LP stakes (V3 only)
 *
 * similar rationale https://docs.uniswap.org/contracts/v3/guides/liquidity-mining/overview
 *
 * All the validators that are connected to the Manifold relay can ONLY connect
 * to the Manifold relay (for mevAuction). If there's a service outage (of the relay)
 * Manifold needs to be able to cover the cost (of lost opportunity) for validators
 * missing out on blocks. Stakers are underwriting this risk of (captive insurance).
 *
 * Contract keeps track of the durations of each deposit. Rewards are paid individually
 * to each NFT (multiple deposits may be made of several V3 positions). The duration of
 * the deposit as well as the share of total liquidity deposited in the vault determines
 * how much the reward will be. It's paid from the WETH balance of the contract owner.
 *
 */

contract StakedUPT is ReentrancyGuard, Owned {
    // minimum duration of being in the vault before withdraw can be called (triggering reward payment)
    uint public minLockDuration;
    uint public weeklyReward;
    uint public immutable deployed; // timestamp when contract was deployed

    mapping(uint => uint) public totalsUSDC; // week # -> liquidity
    uint public totalLiquidityUSDC; // in UniV3 liquidity units
    uint public maxTotalUSDC; // in the same units

    mapping(uint => uint) public totalsWETH; // week # -> liquidity
    uint public totalLiquidityWETH; // for the WETH<>FOLD pool
    uint public maxTotalWETH;

    IWETH public immutable weth;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    mapping(address => mapping(uint => uint)) public depositTimestamps; // for liquidity providers

    // ERC20 addresses
    address constant FOLD = 0xd084944d3c05CD115C09d072B9F44bA3E0E45921;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Uniswap's NonFungiblePositionManager (one for all new pools)
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    event SetWeeklyReward(uint256 reward);
    event SetMinLockDuration(uint256 duration);

    event SetMaxTotalUSDC(uint256 maxTotal);
    event SetMaxTotalWETH(uint256 maxTotal);

    event Deposit(uint tokenId, address owner);
    event Withdrawal(uint tokenId, address owner, uint rewardPaid);

    /* --- Variable container struct  ---
    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

    struct LocalVariables_deposit {
        address token0;
        address token1;
        uint128 liquidity;
    }
    struct LocalVariables_withdraw {
        LocalVariables_deposit d;
        uint reward;
        uint totalThisWeek;
        uint timestamp;
        uint week_iterator;
        uint current_week;
    }

    /**
     * @dev Update the weekly reward. Amount in WETH.
     * @param _newReward New weekly reward.
     */
    function setWeeklyReward(uint256 _newReward) external onlyOwner {
        weeklyReward = _newReward;
        emit SetWeeklyReward(_newReward);
    }

    /**
     * @dev Update the minimum lock duration for staked LP tokens.
     * @param _newMinLockDuration New minimum lock duration.(in weeks)
     */
    function setMinLockDuration(uint256 _newMinLockDuration) external onlyOwner {
        require(_newMinLockDuration % 1 weeks == 0, "UniStaker::deposit: Duration must be in units of weeks");
        minLockDuration = _newMinLockDuration;
        emit SetMinLockDuration(_newMinLockDuration);
    }

    /**
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>USDC pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotalUSDC New max total.
     */
    function setMaxTotalUSDC(uint256 _newMaxTotalUSDC) external onlyOwner {
        maxTotalUSDC = _newMaxTotalUSDC;
        emit SetMaxTotalUSDC(_newMaxTotalUSDC);
    }

    /**
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>WETH pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotalWETH New max total.
     */
    function setMaxTotalWETH(uint256 _newMaxTotalWETH) external onlyOwner {
        maxTotalWETH = _newMaxTotalWETH;
        emit SetMaxTotalWETH(_newMaxTotalWETH);
    }

    constructor() Owned(msg.sender) {
        deployed = block.timestamp;
        minLockDuration = 1 weeks;

        maxTotalWETH = type(uint256).max;
        maxTotalUSDC = type(uint256).max;

        weeklyReward = 1_000_000_000_000; // 0.000001 WETH
        weth = IWETH(WETH);

        nonfungiblePositionManager = INonfungiblePositionManager(NFPM); // UniV3
    }

    function _getPositionInfo(uint tokenId) internal returns (address token0, address token1, uint128 liquidity) {
        (, , token0, token1, , , , liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);
    }

    function _rollOverWeek() internal returns (uint current_week) {
        current_week = (block.timestamp - deployed) / 1 weeks;
        if (totalsWETH[current_week] == 0) {
            // we have just entered a new week
            uint week = current_week;
            // iterate backwards to find the nearest week with an existing total
            while (week > 0) {
                week -= 1;
                if (totalsWETH[week] > 0) {
                    totalsWETH[current_week] = totalsWETH[week];
                    break;
                }
            }
        }
    }

    /**
     * @dev Withdraw UniV3 LP deposit from vault (changing the owner back to original)
     */
    function withdrawToken(uint256 tokenId) external returns (LocalVariables_withdraw memory LV) {
        LV.timestamp = depositTimestamps[msg.sender][tokenId]; // verify that a deposit exists
        require(LV.timestamp > 0, "UniStaker::withdraw: no owner exists for this tokenId");
        require( // how long this deposit has been in the vault
            (block.timestamp - LV.timestamp) > minLockDuration,
            "UniStaker::withdraw: minimum duration for the deposit has not elapsed yet"
        );
        LV.current_week = _rollOverWeek();
        LV.week_iterator = (LV.timestamp - deployed) / 1 weeks; // staker's first week
        // transfer ownership back to the original LP token owner
        nonfungiblePositionManager.transferFrom(address(this), msg.sender, tokenId);

        (LV.d.token0, , , LV.d.liquidity) = _getPositionInfo(tokenId);

        if (LV.d.token0 == WETH) {
            while (LV.week_iterator <= LV.current_week) {
                LV.totalThisWeek = totalsWETH[LV.week_iterator];
                if (LV.totalThisWeek > 0) {
                    // need to check lest div by 0
                    // staker's share of rewards for given week
                    LV.reward += (weeklyReward * LV.d.liquidity) / LV.totalThisWeek;
                }
                LV.week_iterator += 1;
            }
            totalsWETH[LV.current_week] -= LV.d.liquidity;
            totalLiquidityWETH -= LV.d.liquidity;
        } else if (LV.d.token0 == USDC) {
            while (LV.week_iterator <= LV.current_week) {
                LV.totalThisWeek = totalsUSDC[LV.week_iterator];
                if (LV.totalThisWeek > 0) {
                    // need to check lest div by 0
                    // staker's share of rewards for given week
                    LV.reward += (weeklyReward * LV.d.liquidity) / LV.totalThisWeek;
                }
                LV.week_iterator += 1;
            }
            totalsUSDC[LV.current_week] -= LV.d.liquidity;
            totalLiquidityUSDC -= LV.d.liquidity;
        }
        weth.transfer(msg.sender, LV.reward);

        delete depositTimestamps[msg.sender][tokenId];

        emit Withdrawal(tokenId, msg.sender, LV.reward);
    }

    /**
     * @dev This is one way of treating deposits.
     * Instead of deposit function implementation,
     * user might manually transfer their NFT
     * and this would trigger onERC721Received.
     * Stakers underwrite captive insurance for
     * the relay (against outages in mevAuction)
     */

    function deposit(uint tokenId) external returns (LocalVariables_deposit memory LV) {
        // transfer ownership of LP share to this contract
        nonfungiblePositionManager.transferFrom(msg.sender, address(this), tokenId);

        (LV.d.token0, LV.d.token1, LV.d.liquidity) = _getPositionInfo(tokenId);

        require(LV.d.token1 == FOLD, "UniStaker::deposit: improper token id");

        // usually this means that the owner of the position already closed it
        require(LV.d.liquidity > 0, "UniStaker::deposit: cannot deposit empty amount");

        LV.current_week = _rollOverWeek();
        if (LV.d.token0 == WETH) {
            totalLiquidityWETH += LV.d.liquidity;
            require(totalLiquidityWETH <= maxTotalWETH, "UniStaker::deposit: totalLiquidity exceed max");
            totalsWETH[LV.current_week] += LV.d.liquidity;
        } else if (LV.d.token0 == USDC) {
            totalLiquidityUSDC += LV.d.liquidity;
            require(totalLiquidityUSDC <= maxTotalUSDC, "UniStaker::deposit: totalLiquidity exceed max");
            totalsUSDC[LV.current_week] += LV.d.liquidity;
        } else {
            require(false, "UniStaker::deposit: improper token id");
        }
        depositTimestamps[msg.sender][tokenId] = block.timestamp;

        emit Deposit(tokenId, msg.sender);
    }
}
