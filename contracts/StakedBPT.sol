// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@solmate/mixins/ERC4626.sol";
import "@solmate/auth/Owned.sol";
import "@solmate/utils/ReentrancyGuard.sol";
import "@solmate/utils/SafeTransferLib.sol";
import "./interfaces/IBooster.sol";
import "./interfaces/IRewards.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IVirtualRewards.sol";
import "./interfaces/IStash.sol";

// Take BPT -> Stake on Aura -> Someone need to pay to harvest rewards -> Send to treasury multisig
contract StakedBPT is ERC4626, ReentrancyGuard, Owned {
    using SafeTransferLib for ERC20;

    address public immutable lptoken;
    address public immutable cvxtoken;
    IBooster public immutable booster;
    IRewards public immutable crvRewards;
    address public treasury;
    uint256 public minLockDuration;
    uint256 public immutable pid;
    mapping(address => uint256) public lastDepositTimestamp;

    event UpdateTreasury(address indexed treasury);
    event UpdateMinLockDuration(uint256 duration);

    // Custom errors
    error ZeroShares();
    error TimeLocked();

    constructor(
        address _lptoken,
        address _cvxtoken,
        address _booster,
        address _treasury,
        address _owner,
        uint256 _minLockDuration,
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

        IBooster.PoolInfo memory info = booster.poolInfo(_pid);
        lptoken = _lptoken;
        cvxtoken = _cvxtoken;
        crvRewards = IRewards(info.crvRewards);

        emit UpdateTreasury(_treasury);
        emit UpdateMinLockDuration(_minLockDuration);
    }

    function totalAssets() public view virtual override returns (uint256) {
        return crvRewards.balanceOf(address(this));
    }

    function updateTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;

        emit UpdateTreasury(_treasury);
    }

    function updateMinLockDuration(uint256 _minLockDuration) external onlyOwner {
        minLockDuration = _minLockDuration;

        emit UpdateMinLockDuration(_minLockDuration);
    }

    ///
    /// LP functions
    ///

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

    /// Hooks for regular assets

    function afterDeposit(uint256 assets, uint256) internal override {
        IERC20(cvxtoken).approve(address(crvRewards), assets);
        crvRewards.stake(assets);
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        // Receive cvxtoken
        crvRewards.withdraw(assets, false);
    }

    function harvest() public {
        booster.earmarkRewards(pid);
        crvRewards.getReward();
        uint256 len = crvRewards.extraRewardsLength();
        address[] memory rewardTokens = new address[](len + 1);
        rewardTokens[0] = crvRewards.rewardToken();
        for (uint256 i; i < len; i++) {
            IStash stash = IStash(IVirtualRewards(crvRewards.extraRewards(i)).rewardToken());
            rewardTokens[i + 1] = stash.baseToken();
        }

        transferTokens(rewardTokens);
    }

    function transferTokens(address[] memory tokens) internal nonReentrant {
        for (uint256 i; i < tokens.length; ) {
            ERC20(tokens[i]).safeTransfer(treasury, IERC20(tokens[i]).balanceOf(address(this)));
            unchecked {
                ++i;
            }
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
