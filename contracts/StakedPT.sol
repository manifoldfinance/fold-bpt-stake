// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

// Import necessary contracts and libraries
import "./Owned.sol";
import "solmate/mixins/ERC4626.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/utils/SafeTransferLib.sol";
import "./interfaces/IBooster.sol";
import "./interfaces/IRewards.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IVirtualRewards.sol";
import "./interfaces/IStash.sol";
import "./interfaces/IMevEth.sol";
import "./interfaces/IWETH.sol";

/**
 * @title StakedPT
 * @dev StakedPT is a contract that represents staked PT / LP (Pool Token / Liquidity Provider) tokens,
 * allowing users to stake their LP tokens to earn rewards in another token (cvxtoken).
 * This contract extends ERC4626, implements ReentrancyGuard, and is Owned.
 * Ref: https://docs.convexfinance.com/convexfinanceintegration/booster
 */
abstract contract StakedPT is ERC4626, ReentrancyGuard, Owned {
    using SafeTransferLib for ERC20;

    // Immutables
    /// @notice underlying token(ex. the curve lp token)
    address public immutable lptoken;
    /// @notice convex deposit token(a 1:1 token representing an lp deposit)
    address public immutable cvxtoken;
    /// @notice main deposit contract for LP tokens
    IBooster public immutable booster;
    /// @notice main reward contract for the pool
    IRewards public immutable crvRewards;
    /// @notice Wrapped Ether (WETH) contract
    IWETH public immutable weth;
    /// @notice Pool ID in the rewards pool contract
    uint256 public immutable pid;

    IMevEth internal constant mevEth = IMevEth(0x24Ae2dA0f361AA4BE46b48EB19C91e02c5e4f27E);
    uint256 internal constant MIN_ZAP = 0.01 ether;

    // Globals
    address public treasury;
    uint256 public minLockDuration;
    mapping(address => uint256) public lastDepositTimestamp;

    // Events
    event UpdateTreasury(address indexed treasury);
    event UpdateMinLockDuration(uint256 duration);
    event CompoundRewards(uint256 assets);

    // Custom errors
    error ZeroShares();
    error TimeLocked();
    error AmountMismatch();
    error WithdrawMoreThanMax();

    /**
     * @dev Constructor to initialize the StakedBPT contract.
     * @param _lptoken Address of the LP token
     * @param _cvxtoken convex deposit token(a 1:1 token representing an lp deposit)
     * @param _booster Address of the booster contract
     * @param _treasury Address of the treasury
     * @param _owner Address of the contract owner
     * @param _minLockDuration Minimum lock duration for staked LP tokens
     * @param _weth Address of the Wrapped Ether (WETH) contract
     * @param _pid Pool ID in the rewards pool contract
     */
    constructor(
        address _lptoken,
        address _cvxtoken,
        address _booster,
        address _treasury,
        address _owner,
        uint256 _minLockDuration,
        address _weth,
        uint256 _pid
    )
        ERC4626(
            ERC20(_cvxtoken),
            string(abi.encodePacked("Staked ", IERC20(_lptoken).name())),
            string(abi.encodePacked("stk", IERC20(_lptoken).symbol()))
        )
        Owned(_owner)
    {
        booster = IBooster(_booster);

        treasury = _treasury;
        minLockDuration = _minLockDuration;
        pid = _pid;
        weth = IWETH(_weth);

        IBooster.PoolInfo memory info = booster.poolInfo(_pid);
        lptoken = _lptoken;
        cvxtoken = _cvxtoken;
        crvRewards = IRewards(info.crvRewards);

        // Emit initialization events
        emit UpdateTreasury(_treasury);
        emit UpdateMinLockDuration(_minLockDuration);
    }

    /**
     * @dev View function to get the total assets held by the contract.
     * @return uint256 representing the total assets held by the contract.
     */
    function totalAssets() public view virtual override returns (uint256) {
        return crvRewards.balanceOf(address(this));
    }

    /**
     * @dev Update the treasury address. Only callable by the owner.
     * @param _treasury New treasury address.
     */
    function updateTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;

        emit UpdateTreasury(_treasury);
    }

    /**
     * @dev Update the minimum lock duration for staked LP tokens. Only callable by the owner.
     * @param _minLockDuration New minimum lock duration.
     */
    function updateMinLockDuration(uint256 _minLockDuration) external onlyOwner {
        minLockDuration = _minLockDuration;

        emit UpdateMinLockDuration(_minLockDuration);
    }

    function _deposit(address receiver) internal returns (uint256 shares) {
        uint256 assets = IERC20(cvxtoken).balanceOf(address(this));

        // Check for rounding error since we round down in previewDeposit.
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();

        _updateDepositTimestamp(receiver, shares);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    /**
     * @dev Deposit LP tokens to stake and receive AUR / CVX rewards.
     * @param lptokenAmount Amount of LP tokens to deposit.
     * @param receiver Address to receive the staked LP tokens.
     * @return shares Number of shares representing the staked LP tokens.
     */
    function depositLP(uint256 lptokenAmount, address receiver) public virtual returns (uint256 shares) {
        ERC20(lptoken).safeTransferFrom(msg.sender, address(this), lptokenAmount);

        // Stake BPT to receive cvxtoken
        IERC20(lptoken).approve(address(booster), lptokenAmount);
        booster.deposit(pid, lptokenAmount, false);

        // stake cvxtoken
        shares = _deposit(receiver);
    }

    function withdrawLP(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual returns (uint256 lptokenAmount) {
        if (shares > maxRedeem(owner)) revert WithdrawMoreThanMax();

        uint256 assets = previewRedeem(shares);

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        if (lastDepositTimestamp[owner] + minLockDuration > block.timestamp) revert TimeLocked();

        // Receive LP
        crvRewards.withdraw(assets, false);
        IERC20(cvxtoken).approve(address(booster), assets);
        booster.withdraw(pid, assets);

        _burn(owner, shares);

        // Transfer LP
        lptokenAmount = IERC20(lptoken).balanceOf(address(this));
        ERC20(lptoken).safeTransfer(receiver, lptokenAmount);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev Internal function executed after a successful deposit.
     * @param assets Amount of cvxtoken received after staking BPT.
     */
    function afterDeposit(uint256 assets, uint256) internal override {
        IERC20(cvxtoken).approve(address(crvRewards), assets);
        crvRewards.stake(assets);
    }

    /**
     * @dev Internal function executed before a withdrawal to check withdrawal conditions.
     * @param assets Amount of cvxtoken to be withdrawn.
     */
    function beforeWithdraw(uint256 assets, uint256) internal override {
        // Receive cvxtoken
        crvRewards.withdraw(assets, false);
    }

    function harvest() external {
        booster.earmarkRewards(pid);
        crvRewards.getReward();
        address token = crvRewards.rewardToken();
        uint256 amount = IERC20(token).balanceOf(address(this));
        uint256 amountOut;
        if (amount > 0) {
            // swap for weth
            amountOut = swapReward(token, amount);
        }
        amountOut += _claimExtras();
        amountOut = _sendProtocolFee(amountOut);
        _zapSwappedRewards(amountOut);
    }

    function _claimExtras() internal virtual returns (uint256 amountOut) {
        uint256 len = crvRewards.extraRewardsLength();
        if (len > 0) {
            for (uint256 i; i < len; i = _inc(i)) {
                address virtualRewards = crvRewards.extraRewards(i);
                address token = _getStashToken(virtualRewards);
                uint256 amount = IERC20(token).balanceOf(address(this));
                if (amount > 0) {
                    amountOut += swapReward(token, amount);
                }
            }
        }
    }

    function swapReward(address token, uint256 amountIn) internal virtual returns (uint256 amountOut) {}

    function _zapSwappedRewards(uint256 amount) internal virtual {}

    function _sendProtocolFee(uint256 wethBal) internal returns (uint256 amountRemaining) {
        // send 10% to treasury
        ERC20(address(weth)).safeTransfer(treasury, wethBal / 10);
        amountRemaining = (wethBal * 90) / 100;
    }

    function _getStashToken(address virtualRewards) internal virtual returns (address stashToken) {
        address stash = IVirtualRewards(virtualRewards).rewardToken();
        stashToken = IStash(stash).baseToken();
    }

    function _inc(uint256 i) internal pure returns (uint256 j) {
        unchecked {
            j = i + 1;
        }
    }

    // override ERC4626 functions to update deposit timestamp

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256 shares) {
        // Set the deposit timestamp for the user
        _updateDepositTimestamp(receiver, previewDeposit(assets));
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public virtual override returns (uint256 assets) {
        // Set the deposit timestamp for the user
        _updateDepositTimestamp(receiver, shares);
        assets = super.mint(shares, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256 shares) {
        if (lastDepositTimestamp[owner] + minLockDuration > block.timestamp) revert TimeLocked();
        shares = super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256 assets) {
        if (lastDepositTimestamp[owner] + minLockDuration > block.timestamp) revert TimeLocked();
        assets = super.redeem(shares, receiver, owner);
    }

    function _updateDepositTimestamp(address account, uint256 shares) internal {
        // Set the deposit timestamp for the user
        uint256 prevBalance = balanceOf[account];
        uint256 lastDeposit = lastDepositTimestamp[account];
        if (prevBalance == 0 || lastDeposit == 0) {
            lastDepositTimestamp[account] = block.timestamp;
        } else {
            // multiple deposits, so weight timestamp by amounts
            unchecked {
                lastDepositTimestamp[account] =
                    lastDeposit +
                    ((block.timestamp - lastDeposit) * shares) /
                    (prevBalance + shares);
            }
        }
    }

    function _updateTransferTimestamp(address account, uint256 shares) internal {
        // Set the transfer timestamp for the user
        uint256 newBalance = balanceOf[account];
        uint256 lastDeposit = lastDepositTimestamp[account];
        if (newBalance == 0 || lastDeposit < (block.timestamp - lastDeposit)) {
            lastDepositTimestamp[account] = 0;
        } else {
            // multiple deposits, so weight timestamp by amounts
            unchecked {
                lastDepositTimestamp[account] =
                    lastDeposit -
                    ((block.timestamp - lastDeposit) * shares) /
                    (newBalance + shares);
            }
        }
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool success) {
        _updateDepositTimestamp(to, amount);
        success = super.transfer(to, amount);
        _updateTransferTimestamp(msg.sender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool success) {
        _updateDepositTimestamp(to, amount);
        success = super.transferFrom(from, to, amount);
        _updateTransferTimestamp(from, amount);
    }
}
