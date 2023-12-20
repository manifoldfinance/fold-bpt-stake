// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

// Import necessary contracts and libraries
import "@solmate/mixins/ERC4626.sol";
import "@solmate/auth/Owned.sol";
import "@solmate/utils/ReentrancyGuard.sol";
import "@solmate/utils/SafeTransferLib.sol";
import "./interfaces/IBooster.sol";
import "./interfaces/IRewards.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IVirtualRewards.sol";
import "./interfaces/IStash.sol";
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

    // Globals
    address public treasury;
    uint256 public minLockDuration;
    mapping(address => uint256) public lastDepositTimestamp;

    // Events
    event UpdateTreasury(address indexed treasury);
    event UpdateMinLockDuration(uint256 duration);

    // Custom errors
    error ZeroShares();
    error TimeLocked();

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
        if (amount > 0) {
            ERC20(token).safeTransfer(treasury, amount);
        }
        _claimExtras();
    }

    function _claimExtras() internal virtual {
        uint256 len = crvRewards.extraRewardsLength();
        if (len > 0) {
            address[] memory rewardTokens = new address[](len);
            for (uint256 i; i < len; i = _inc(i)) {
                address virtualRewards = crvRewards.extraRewards(i);
                rewardTokens[i] = _getStashToken(virtualRewards);
            }
            transferTokens(rewardTokens);
        }
    }

    function _getStashToken(address virtualRewards) internal virtual returns (address stashToken) {
        address stash = IVirtualRewards(virtualRewards).rewardToken();
        stashToken = IStash(stash).baseToken();
    }

    /**
     * @dev Internal function to transfer reward tokens to the treasury.
     * @param tokens Array of reward tokens to be transferred.
     */
    function transferTokens(address[] memory tokens) internal nonReentrant {
        for (uint256 i; i < tokens.length; i = _inc(i)) {
            uint256 amount = IERC20(tokens[i]).balanceOf(address(this));
            if (amount > 0) {
                ERC20(tokens[i]).safeTransfer(treasury, amount);
            }
        }
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
}