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
    /// @notice Pool ID for Balancer pool
    bytes32 public immutable poolId;

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
        uint256[] memory decimals = new uint256[](tokens.length);
        uint256 value = msg.value;
        for (uint256 i; i < tokens.length; i = _inc(i)) {
            // require(amounts[i] > 0, "StakedBPT: amount is zero");
            if (tokens[i] == address(weth) && value > 0) {
                if (amounts[i] != value) revert AmountMismatch();
                weth.deposit{value: value}();
            } else {
                ERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
            decimals[i] = IERC20(tokens[i]).decimals();
            IERC20(tokens[i]).approve(address(bal), amounts[i]);
        }

        bytes memory userData = abi.encode(3, lptokenAmount);

        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
            assets: tokens,
            maxAmountsIn: amounts,
            userData: userData,
            fromInternalBalance: false
        });
        address sender = address(this);
        address recipient = sender;
        bal.joinPool(poolId, sender, recipient, request);

        // Stake BPT to receive cvxtoken
        uint256 amount = IERC20(lptoken).balanceOf(address(this));
        IERC20(lptoken).approve(address(booster), amount);
        booster.deposit(pid, amount, false);

        uint256 assets = IERC20(cvxtoken).balanceOf(address(this));

        // Check for rounding error since we round down in previewDeposit.
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);

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
}
