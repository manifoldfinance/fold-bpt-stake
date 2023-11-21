// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@solmate/mixins/ERC4626.sol";
import "@solmate/auth/Owned.sol";
import "@solmate/utils/ReentrancyGuard.sol";
import "@solmate/utils/SafeTransferLib.sol";
import "./interfaces/ICrvDepositor.sol";
import "./interfaces/IBasicRewards.sol";
import "./interfaces/IERC20.sol";

// Take BPT -> Stake on Aura -> Someone need to pay to harvest rewards -> Send to treasury multisig
contract StakedBPT is ERC4626, ReentrancyGuard, Owned {
    using SafeTransferLib for ERC20;

    address public immutable bpt;
    address public immutable auraBal;
    address public immutable depositor;
    address public immutable pool;
    address public treasury;
    uint256 public minLockDuration;
    mapping(address => uint256) public lastDepositTimestamp;

    event UpdateTreasury(address indexed treasury);
    event UpdateMinLockDuration(uint256 duration);

    constructor(
        address _bpt,
        address _auraBal,
        address _depositor,
        address _pool,
        address _treasury,
        uint256 _minLockDuration,
        address _owner
    )
        ERC4626(
            ERC20(_auraBal),
            string(abi.encodePacked("Staked ", IERC20(_bpt).name())),
            string(abi.encodePacked("stk", IERC20(_bpt).symbol()))
        )
        Owned(_owner)
    {
        bpt = _bpt;
        auraBal = _auraBal;
        depositor = _depositor;
        pool = _pool;
        treasury = _treasury;
        minLockDuration = _minLockDuration;

        emit UpdateTreasury(_treasury);
        emit UpdateMinLockDuration(_minLockDuration);
    }

    function totalAssets() public view virtual override returns (uint256) {
        return IBasicRewards(pool).balanceOf(address(this));
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
    /// BPT overloaded functions
    /// 

    function depositBPT(uint256 assets, address receiver) public virtual returns (uint256 shares) {
        ERC20(bpt).safeTransferFrom(msg.sender, address(this), amount);

        // Stake BPT to receive auraBal
        IERC20(bpt).approve(depositor, amount);
        ICrvDepositor(depositor).deposit(amount, true);

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mintBPT(uint256 shares, address receiver) public virtual returns (uint256 assets) {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// Hooks for regular assets

    function depositBPT(uint256 amount, address receiver) external nonReentrant {
        require(amount > 0, "StakedBPT: amount is zero");

        ERC20(bpt).safeTransferFrom(msg.sender, address(this), amount);

        // Stake BPT to receive auraBal
        IERC20(bpt).approve(depositor, amount);
        ICrvDepositor(depositor).deposit(amount, true);

        uint256 assets = IERC20(auraBal).balanceOf(address(this));
    }

    function afterDeposit(uint256 assets, uint256) internal override { 
        IERC20(auraBal).approve(pool, assets);
        IBasicRewards(pool).stake(assets);

        lastDepositTimestamp[msg.sender] = block.timestamp;
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        require(lastDepositTimestamp[owner] + minLockDuration <= block.timestamp, "StakedBPT: locked");

        // Receive auraBal
        IBasicRewards(pool).withdraw(assets, false);
    }

    function harvest() public nonReentrant {
        IBasicRewards(pool).getReward();

        address rewardToken = IBasicRewards(pool).rewardToken();
        ERC20(rewardToken).safeTransfer(treasury, IERC20(rewardToken).balanceOf(address(this)));
    }

    function transferTokens(address[] memory tokens) public nonReentrant {
        for (uint256 i; i < tokens.length; ) {
            ERC20(tokens[i]).safeTransfer(treasury, IERC20(tokens[i]).balanceOf(address(this)));
            unchecked {
                ++i;
            }
        }
    }
}
