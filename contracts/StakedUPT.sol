// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./Owned.sol";
import "./interfaces/IWETH.sol";

import "@solmate/utils/ReentrancyGuard.sol";
import "./interfaces/INonfungiblePositionManager.sol";

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

    function _getPositionInfo(uint tokenId) internal view returns (address token0, address token1, uint128 liquidity) {
        (, , token0, token1, , , , liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);
    }

    function _rollOverWETH() internal returns (uint current_week) {
        current_week = (block.timestamp - deployed) / 1 weeks;
        // if the vault was emptied then we don't need to roll over past liquidity
        if (totalsWETH[current_week] == 0 && totalLiquidityWETH > 0) {
            totalsWETH[current_week] = totalLiquidityWETH;
        }
    }

    function _rollOverUSDC() internal returns (uint current_week) {
        current_week = (block.timestamp - deployed) / 1 weeks;
        // if the vault was emptied then we don't need to roll over past liquidity
        if (totalsUSDC[current_week] == 0 && totalLiquidityUSDC > 0) {
            totalsUSDC[current_week] = totalLiquidityUSDC;
        }
    }

    /**
     * @dev Withdraw UniV3 LP deposit from vault (changing the owner back to original)
     */
    function withdrawToken(uint256 tokenId) external nonReentrant {
        uint timestamp = depositTimestamps[msg.sender][tokenId]; // verify that a deposit exists
        require(timestamp > 0, "UniStaker::withdraw: no owner exists for this tokenId");
        require( // how long this deposit has been in the vault
            (block.timestamp - timestamp) > minLockDuration,
            "UniStaker::withdraw: minimum duration for the deposit has not elapsed yet"
        );
        (address token0, , uint128 liquidity) = _getPositionInfo(tokenId);
        uint week_iterator = (timestamp - deployed) / 1 weeks;

        // could've deposited right before the end of the week, so need a bit of granularity
        // otherwise an unfairly large portion of rewards may be obtained by staker
        uint so_far = (timestamp - deployed) / 1 hours;
        uint delta = so_far - (week_iterator * 168);

        uint reward = (delta * weeklyReward) / 168; // the first reward may be a fraction of a whole week's worth
        uint totalReward = 0;
        if (token0 == WETH) {
            uint current_week = _rollOverWETH();
            while (week_iterator < current_week) {
                uint totalThisWeek = totalsWETH[week_iterator];
                if (totalThisWeek > 0) {
                    // need to check lest div by 0
                    // staker's share of rewards for given week
                    totalReward += (reward * liquidity) / totalThisWeek;
                }
                week_iterator += 1;
                reward = weeklyReward;
            }
            so_far = (block.timestamp - deployed) / 1 hours;
            delta = so_far - (current_week * 168);
            // the last reward will be a fraction of a whole week's worth
            reward = (delta * weeklyReward) / 168; // because we're in the middle of a current week
            totalReward += (reward * liquidity) / totalLiquidityWETH;
            totalLiquidityWETH -= liquidity;
        } else if (token0 == USDC) {
            uint current_week = _rollOverUSDC();
            while (week_iterator < current_week) {
                uint totalThisWeek = totalsUSDC[week_iterator];
                if (totalThisWeek > 0) {
                    // need to check lest div by 0
                    // staker's share of rewards for given week
                    totalReward += (reward * liquidity) / totalThisWeek;
                }
                week_iterator += 1;
                reward = weeklyReward;
            }
            so_far = (block.timestamp - deployed) / 1 hours;
            delta = so_far - (current_week * 168);
            // the last reward will be a fraction of a whole week's worth
            reward = (delta * weeklyReward) / 168; // because we're in the middle of a current week
            totalReward += (reward * liquidity) / totalLiquidityUSDC;
            totalLiquidityUSDC -= liquidity;
        }
        delete depositTimestamps[msg.sender][tokenId];
        require(weth.transfer(msg.sender, totalReward), "UniStaker::withdraw: transfer failed");
        // transfer ownership back to the original LP token owner
        nonfungiblePositionManager.transferFrom(address(this), msg.sender, tokenId);

        emit Withdrawal(tokenId, msg.sender, totalReward);
    }

    /**
     * @dev This is one way of treating deposits.
     * Instead of deposit function implementation,
     * user might manually transfer their NFT
     * and this would trigger onERC721Received.
     * Stakers underwrite captive insurance for
     * the relay (against outages in mevAuction)
     */
    function deposit(uint tokenId) external nonReentrant {
        (address token0, address token1, uint128 liquidity) = _getPositionInfo(tokenId);

        require(token1 == FOLD, "UniStaker::deposit: improper token id");
        // usually this means that the owner of the position already closed it
        require(liquidity > 0, "UniStaker::deposit: cannot deposit empty amount");

        if (token0 == WETH) {
            totalsWETH[_rollOverWETH()] += liquidity;
            totalLiquidityWETH += liquidity;
            require(totalLiquidityWETH <= maxTotalWETH, "UniStaker::deposit: totalLiquidity exceed max");
        } else if (token0 == USDC) {
            totalsUSDC[_rollOverUSDC()] += liquidity;
            totalLiquidityUSDC += liquidity;
            require(totalLiquidityUSDC <= maxTotalUSDC, "UniStaker::deposit: totalLiquidity exceed max");
        } else {
            require(false, "UniStaker::deposit: improper token id");
        }
        depositTimestamps[msg.sender][tokenId] = block.timestamp;
        // transfer ownership of LP share to this contract
        nonfungiblePositionManager.transferFrom(msg.sender, address(this), tokenId);

        emit Deposit(tokenId, msg.sender);
    }
}
