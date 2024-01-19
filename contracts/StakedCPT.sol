// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./StakedPT.sol";
import "./interfaces/ITokenWrapper.sol";
import "./interfaces/ICurveV2Pool.sol";

/**
 * @title StakedCPT
 * @dev StakedCPT is a contract that represents staked Curve LP (Liquidity Provider) tokens,
 * allowing users to stake their LP tokens to earn rewards in another token (cvxtoken).
 * This contract extends ERC4626, implements ReentrancyGuard, and is Owned.
 */
contract StakedCPT is StakedPT {
    using SafeTransferLib for ERC20;

    /// @notice Curve pool contract
    ICurveV2Pool immutable pool;
    /// @dev CRV address
    address internal constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    /// @dev Curve CRV/WETH pool for swapping rewards out
    ICurveV2Pool internal constant crvPool = ICurveV2Pool(0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14);
    /// @dev Curve CVX/WETH pool for swapping rewards out
    ICurveV2Pool internal constant cvxPool = ICurveV2Pool(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4);

    /**
     * @dev Constructor to initialize the StakedCPT contract.
     * @param _lptoken Address of the LP token
     * @param _cvxtoken convex deposit token(a 1:1 token representing an lp deposit)
     * @param _booster Address of the booster contract
     * @param _treasury Address of the treasury
     * @param _owner Address of the contract owner
     * @param _minLockDuration Minimum lock duration for staked LP tokens
     * @param _weth Address of the Wrapped Ether (WETH) contract
     * @param _pid Pool ID in the rewards pool contract
     * @param _pool Pool address for Curve pool
     */
    constructor(
        address _lptoken,
        address _cvxtoken,
        address _booster,
        address _treasury,
        address _owner,
        uint256 _minLockDuration,
        address _weth,
        uint256 _pid,
        address _pool
    ) StakedPT(_lptoken, _cvxtoken, _booster, _treasury, _owner, _minLockDuration, _weth, _pid) {
        pool = ICurveV2Pool(_pool);

        weth.approve(address(mevEth), type(uint256).max);
        mevEth.approve(_pool, type(uint256).max);
    }

    /**
     * @dev Zap into the Curve pool by providing tokens and receiving staked LP tokens in return.
     * @param amounts Array of amounts of tokens to be provided.
     * @param receiver Address to receive the staked LP tokens.
     * @return shares Number of shares representing the staked LP tokens.
     */
    function zapCPT(
        uint256[2] calldata amounts,
        address receiver
    ) external payable nonReentrant returns (uint256 shares) {
        address[2] memory tokens;
        tokens[0] = pool.coins(0);
        tokens[1] = pool.coins(1);
        uint256 value = msg.value;
        for (uint256 i; i < tokens.length; i = _inc(i)) {
            if (amounts[i] == 0) continue;
            if (tokens[i] == address(weth) && value > 0) {
                if (amounts[i] != value) revert AmountMismatch();
                weth.deposit{value: value}();
            } else {
                ERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
            IERC20(tokens[i]).approve(address(pool), amounts[i]);
        }

        uint256 lptokenAmount = pool.calc_token_amount(amounts);

        lptokenAmount = pool.add_liquidity(amounts, (lptokenAmount * 99) / 100, false, address(this));

        // Stake CPT to receive cvxtoken
        IERC20(lptoken).approve(address(booster), lptokenAmount);
        booster.deposit(pid, lptokenAmount, false);

        // stake cvxtoken
        shares = _deposit(receiver);

        // refund dust
        for (uint256 i; i < tokens.length; i = _inc(i)) {
            address token = tokens[i];
            uint256 amount = IERC20(token).balanceOf(address(this));
            // if token is weth, check refund is more than value transfer fee
            if (token == address(weth) && 50000 * block.basefee > amount) {
                continue;
            }
            ERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /**
     * @dev Zap out of the Curve pool by redeeming staked LP tokens and receiving underlying tokens in return.
     * @param shares Number of shares representing the staked LP tokens to be redeemed.
     * @param receiver Address to receive the redeemed underlying tokens.
     * @param owner Address of the owner initiating the withdrawal.
     * @param minAmountsOut Minimum amounts of underlying tokens to be received in the redemption.
     * @return amountsOut Array of amounts representing the redeemed underlying tokens.
     */
    function zipCPT(
        uint256 shares,
        address receiver,
        address owner,
        uint256[2] calldata minAmountsOut
    ) public virtual returns (uint256[] memory amountsOut) {
        if (shares > maxRedeem(owner)) revert WithdrawMoreThanMax();

        uint256 assets = previewRedeem(shares);

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        if (lastDepositTimestamp[owner] + minLockDuration > block.timestamp) revert TimeLocked();

        // Receive CPT
        crvRewards.withdraw(assets, false);
        IERC20(cvxtoken).approve(address(booster), assets);
        booster.withdraw(pid, assets);

        _burn(owner, shares);

        // Exit CPT
        address[] memory tokens = new address[](2);
        tokens[0] = pool.coins(0);
        tokens[1] = pool.coins(1);
        if (minAmountsOut[0] == 0) {
            pool.remove_liquidity_one_coin(assets, 1, minAmountsOut[1]);
        } else if (minAmountsOut[1] == 0) {
            pool.remove_liquidity_one_coin(assets, 0, minAmountsOut[0]);
        } else {
            pool.remove_liquidity(assets, minAmountsOut);
        }
        amountsOut = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; i = _inc(i)) {
            amountsOut[i] = IERC20(tokens[i]).balanceOf(address(this));
            ERC20(tokens[i]).safeTransfer(receiver, amountsOut[i]);
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _getStashToken(address virtualRewards) internal override returns (address stashToken) {
        address stash = IVirtualRewards(virtualRewards).rewardToken();
        stashToken = ITokenWrapper(stash).token();
    }

    /// @dev swap reward token for weth for compound staking
    function swapReward(address tokenIn, uint256 amountIn) internal virtual override returns (uint256 amountOut) {
        if (tokenIn == CRV) {
            // CRV
            ERC20(tokenIn).approve(address(crvPool), amountIn);
            amountOut = crvPool.exchange(2, 1, amountIn, 1, false, address(this));
        } else {
            // assume CVX
            ERC20(tokenIn).approve(address(cvxPool), amountIn);
            amountOut = cvxPool.exchange(1, 0, amountIn, 1, false);
            // weth.deposit{value: amountOut}();
        }
    }

    /// @dev zap weth rewards into LP, then stake
    /// note: assumes weth is one of the tokens
    function _zapSwappedRewards(uint256 amount) internal virtual override {
        {
            uint256 wethBal = weth.balanceOf(address(this));
            if (amount > wethBal) return;
            if (wethBal < MIN_ZAP) return;
            if (amount < wethBal) amount = wethBal;
        }

        // step 1: swap weth for mevEth fully
        uint256 shares = mevEth.deposit(amount, address(this));
        uint256[2] memory amounts;
        {
            address[2] memory tokens;
            tokens[0] = pool.coins(0);
            tokens[1] = pool.coins(1);
            for (uint256 i; i < tokens.length; i = _inc(i)) {
                if (tokens[i] == address(mevEth)) {
                    amounts[i] = shares;
                }
            }
        }

        // step 2: zap tokens for LP
        {
            uint256 lptokenAmount = pool.calc_token_amount(amounts);
            lptokenAmount = pool.add_liquidity(amounts, (lptokenAmount * 99) / 100, false, address(this));
            // step 3: Stake CPT to receive cvxtoken
            IERC20(lptoken).approve(address(booster), lptokenAmount);
            booster.deposit(pid, lptokenAmount, false);
        }

        // step 4: stake cvxtoken
        {
            uint256 assets = IERC20(cvxtoken).balanceOf(address(this));
            emit CompoundRewards(assets);
            afterDeposit(assets, 0);
        }
    }
}
