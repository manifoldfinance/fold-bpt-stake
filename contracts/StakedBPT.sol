// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

// Import necessary contracts and libraries
import "contracts/StakedPT.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IBPT.sol";

/**
 * @title StakedBPT
 * @dev StakedBPT is a contract that represents staked Balancer LP (Liquidity Provider) tokens,
 * allowing users to stake their LP tokens to earn rewards in another token (cvxtoken).
 * This contract extends ERC4626, implements ReentrancyGuard, and is Owned.
 */
contract StakedBPT is StakedPT {
    using SafeTransferLib for ERC20;

    /// @notice Balancer Vault contract
    IVault immutable bal;
    /// @dev BAL gov token for reward swapping
    address internal constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;
    /// @notice Pool ID for Balancer pool
    bytes32 public immutable poolId;
    /// @dev PoolID for BAL/WETH to exchange rewards
    bytes32 internal constant balPoolId = 0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014;
    /// @dev PoolID for AUR/WETH to exchange rewards
    bytes32 internal constant aurPoolId = 0xcfca23ca9ca720b6e98e3eb9b6aa0ffc4a5c08b9000200000000000000000274;

    /**
     * @dev Constructor to initialize the StakedBPT contract.
     * @param _lptoken Address of the LP token
     * @param _cvxtoken convex deposit token(a 1:1 token representing an lp deposit)
     * @param _booster Address of the booster contract
     * @param _treasury Address of the treasury
     * @param _owner Address of the contract owner
     * @param _minLockDuration Minimum lock duration for staked LP tokens
     * @param _weth Address of the Wrapped Ether (WETH) contract
     * @param _vault Address of the Balancer Vault contract
     * @param _pid Pool ID in the rewards pool contract
     * @param _poolId Pool ID for Balancer pool
     */
    constructor(
        address _lptoken,
        address _cvxtoken,
        address _booster,
        address _treasury,
        address _owner,
        uint256 _minLockDuration,
        address _weth,
        address _vault,
        uint256 _pid,
        bytes32 _poolId
    ) StakedPT(_lptoken, _cvxtoken, _booster, _treasury, _owner, _minLockDuration, _weth, _pid) {
        bal = IVault(_vault);
        poolId = _poolId;

        // approve max for balancer vault
        weth.approve(_vault, type(uint256).max);
        mevEth.approve(_vault, type(uint256).max);
    }

    /**
     * @notice Calculates alternative token amountIn required for zap
     * @dev Assumes: 2 token pool, 18 decimals
     * @param token Token address of known amount in
     * @param amountIn Known amount In of token
     * @return amountInAlt Amount In of alternative token required for zap
     * @return bptOut Expected BPT out amount
     */
    function getAltTokenAmountInRequired(
        address token,
        uint256 amountIn
    ) external view returns (uint256 amountInAlt, uint256 bptOut) {
        (address[] memory tokens, uint256[] memory balances, ) = bal.getPoolTokens(poolId);
        uint256 totalSupply = ERC20(lptoken).totalSupply();
        uint256 len = tokens.length;
        for (uint256 i; i < len; i = _inc(i)) {
            if (tokens[i] == token) {
                bptOut = (amountIn * totalSupply) / balances[i];
                break;
            }
        }
        for (uint256 i; i < len; i = _inc(i)) {
            if (tokens[i] != token) {
                amountInAlt = (balances[i] * bptOut) / totalSupply;

                break;
            }
        }
    }

    /**
     * @notice Calculates expected amounts out of tokens given bpt amount to redeem
     * @dev Assumes: 2 token pool, 18 decimals
     * @param bptOut BPT amount to redeem
     * @return amountsIn Amounts Out expected for tokens in LP
     */
    function calcAllTokensInGivenExactBptOut(uint256 bptOut) external view returns (uint256[] memory amountsIn) {
        /************************************************************************************
        // tokensInForExactBptOut                                                          //
        //                              /   bptOut   \                                     //
        // amountsIn[i] = balances[i] * | ------------ |                                   //
        //                              \  totalBPT  /                                     //
        ************************************************************************************/
        // We adjust the order of operations to minimize error amplification, assuming that
        // balances[i], totalBPT > 1 (which is usually the case).
        // Tokens in, so we round up overall.
        (, uint256[] memory balances, ) = bal.getPoolTokens(poolId);
        uint256 totalBPT = ERC20(lptoken).totalSupply();
        amountsIn = new uint256[](balances.length);
        for (uint256 i = 0; i < balances.length; i++) {
            amountsIn[i] = (balances[i] * bptOut) / totalBPT;
        }

        return amountsIn;
    }

    /**
     * @notice Zap into the Balancer pool by providing tokens and receiving staked LP tokens in return.
     * @dev Assumes: 2 token pool, 18 decimals, one sided liquidity provision (with a trace amount of other token, eg eth)
     * @param amounts Array of amounts of tokens to be provided.
     * @param receiver Address to receive the staked LP tokens.
     * @param lptokenAmount Amount of lp to expect.
     * @return shares Number of shares representing the staked LP tokens.
     */
    function zapBPT(
        uint256[] calldata amounts,
        address receiver,
        uint256 lptokenAmount
    ) external payable nonReentrant returns (uint256 shares) {
        (address[] memory tokens, , ) = bal.getPoolTokens(poolId);
        uint256 value = msg.value;
        for (uint256 i; i < tokens.length; i = _inc(i)) {
            if (tokens[i] == address(weth) && value > 0) {
                if (amounts[i] != value) revert AmountMismatch();
                weth.deposit{value: value}();
            } else {
                ERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
        }

        bytes memory userData = abi.encode(3, lptokenAmount);

        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
            assets: tokens,
            maxAmountsIn: amounts,
            userData: userData,
            fromInternalBalance: false
        });

        bal.joinPool(poolId, address(this), address(this), request);

        // Stake BPT to receive cvxtoken
        uint256 amount = IERC20(lptoken).balanceOf(address(this));
        IERC20(lptoken).approve(address(booster), amount);
        booster.deposit(pid, amount, false);

        // stake cvxtoken
        shares = _deposit(receiver);

        // refund dust
        for (uint256 i; i < tokens.length; i = _inc(i)) {
            address token = tokens[i];
            amount = IERC20(token).balanceOf(address(this));
            // if token is weth, check refund is more than value transfer fee
            if (token == address(weth) && 50000 * block.basefee > amount) {
                continue;
            }
            ERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /**
     * @dev Zap out of the Balancer pool by redeeming staked LP tokens and receiving underlying tokens in return.
     * @param shares Number of shares representing the staked LP tokens to be redeemed.
     * @param receiver Address to receive the redeemed underlying tokens.
     * @param owner Address of the owner initiating the withdrawal.
     * @param minAmountsOut Minimum amounts of underlying tokens to be received in the redemption.
     * @return amountsOut Array of amounts representing the redeemed underlying tokens.
     */
    function zipBPT(
        uint256 shares,
        address receiver,
        address owner,
        uint256[] calldata minAmountsOut
    ) public virtual returns (uint256[] memory amountsOut) {
        if (shares > maxRedeem(owner)) revert WithdrawMoreThanMax();

        uint256 assets = previewRedeem(shares);

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        if (lastDepositTimestamp[owner] + minLockDuration > block.timestamp) revert TimeLocked();

        // Receive BPT
        crvRewards.withdraw(assets, false);
        IERC20(cvxtoken).approve(address(booster), assets);
        booster.withdraw(pid, assets);

        _burn(owner, shares);

        // Exit BPT
        (address[] memory tokens, , ) = bal.getPoolTokens(poolId);
        {
            bytes memory userData = abi.encode(1, IERC20(lptoken).balanceOf(address(this)));
            IVault.ExitPoolRequest memory request = IVault.ExitPoolRequest({
                assets: tokens,
                minAmountsOut: minAmountsOut,
                userData: userData,
                toInternalBalance: false
            });

            bal.exitPool(poolId, address(this), payable(address(this)), request);
        }
        amountsOut = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; i = _inc(i)) {
            amountsOut[i] = IERC20(tokens[i]).balanceOf(address(this));
            ERC20(tokens[i]).safeTransfer(receiver, amountsOut[i]);
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev swap reward token for weth for compound staking
    function swapReward(address tokenIn, uint256 amountIn) internal virtual override returns (uint256 amountOut) {
        bytes32 id;
        if (tokenIn == BAL) {
            id = balPoolId;
        } else {
            id = aurPoolId;
        }
        IVault.SingleSwap memory singleSwap = IVault.SingleSwap(
            id,
            IVault.SwapKind.GIVEN_IN,
            tokenIn,
            address(weth),
            amountIn,
            new bytes(0)
        );
        IVault.FundManagement memory fund = IVault.FundManagement(address(this), false, payable(address(this)), false);
        ERC20(tokenIn).approve(address(bal), amountIn);
        amountOut = bal.swap(singleSwap, fund, 1, block.timestamp + 120);
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

        // step 1: get optimal amounts of token0 and token1 for LP
        uint256 bptOut;
        address[] memory tokens;
        uint256[] memory amountsIn;
        {
            uint256[] memory balances;
            (tokens, balances, ) = bal.getPoolTokens(poolId);
            uint256 totalSupply = ERC20(lptoken).totalSupply();
            uint256 len = tokens.length;
            // NB assuming one of the tokens is mevEth or weth (works foe MevEth/Weth and Weth/Fold and mevEth/Fold)
            for (uint256 i; i < len; i = _inc(i)) {
                if (tokens[i] == address(mevEth)) {
                    // MevEth/Weth and mevEth/Fold are mevEth heavy (>80%)
                    // todo: find way to remove hard coded 80%
                    // Note: likely to be some dust in weth, which can be used up on the next harvest
                    bptOut = (mevEth.previewDeposit((amount * 80) / 100) * totalSupply) / balances[i];
                    break;
                } else if (tokens[i] == address(weth)) {
                    // weth/fold 50 : 50
                    bptOut = (amount * totalSupply) / (2 * balances[i]);
                    break;
                }
            }
            // use optimal amounts to swap weth for tokens
            amountsIn = new uint256[](len);
            for (uint256 i = 0; i < len; i++) {
                amountsIn[i] = (balances[i] * bptOut) / totalSupply;
                if (tokens[i] == address(mevEth) && amountsIn[i] > 10 ether) {
                    // default to swap if low amount otherwise use mevEth directly
                    weth.approve(address(mevEth), mevEth.previewMint(amountsIn[i]));
                    mevEth.mint(amountsIn[i], address(this));
                } else if (tokens[i] != address(weth)) {
                    // swap weth -> token
                    IVault.SingleSwap memory singleSwap = IVault.SingleSwap(
                        poolId,
                        IVault.SwapKind.GIVEN_IN,
                        address(weth),
                        tokens[i],
                        mevEth.previewMint(amountsIn[i]),
                        new bytes(0)
                    );
                    IVault.FundManagement memory fund = IVault.FundManagement(
                        address(this),
                        false,
                        payable(address(this)),
                        false
                    );
                    bal.swap(singleSwap, fund, 1, block.timestamp + 120);
                }
            }
            // adjust amounts by balances for max stake
            for (uint256 i = 0; i < len; i++) {
                amountsIn[i] = ERC20(tokens[i]).balanceOf(address(this));
            }
        }

        // step 2: zap tokens for LP
        {
            bytes memory userData = abi.encode(3, bptOut);
            IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
                assets: tokens,
                maxAmountsIn: amountsIn,
                userData: userData,
                fromInternalBalance: false
            });
            bal.joinPool(poolId, address(this), address(this), request);
        }

        // step 3: Stake BPT to receive cvxtoken
        {
            amount = IERC20(lptoken).balanceOf(address(this));
            IERC20(lptoken).approve(address(booster), amount);
            booster.deposit(pid, amount, false);
        }

        // step 4: stake cvxtoken
        {
            uint256 assets = IERC20(cvxtoken).balanceOf(address(this));
            emit CompoundRewards(assets);
            afterDeposit(assets, 0);
        }
    }
}
