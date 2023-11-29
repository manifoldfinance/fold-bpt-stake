// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ICrvDepositor.sol";
import "./interfaces/IBasicRewards.sol";
import "./interfaces/IVirtualRewards.sol";
import "./interfaces/IStash.sol";

// Take BPT -> Stake on Aura -> Someone need to pay to harvest rewards -> Send to treasury multisig
contract StakedBPT is ERC4626, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    address public immutable bpt;
    address public immutable auraBal;
    address public immutable depositor;
    address public immutable pool;
    address public treasury;
    uint256 public minLockDuration;
    uint256 public pid;
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
        address _owner,
        uint256 _pid
    )
        ERC4626(IERC20(_auraBal))
        ERC20(
            string(abi.encodePacked("Staked ", ERC20(_bpt).name())),
            string(abi.encodePacked("stk", ERC20(_bpt).symbol()))
        )
    {
        bpt = _bpt;
        auraBal = _auraBal;
        depositor = _depositor;
        pool = _pool;
        treasury = _treasury;
        minLockDuration = _minLockDuration;
        transferOwnership(_owner);
        pid = _pid;

        emit UpdateTreasury(_treasury);
        emit UpdateMinLockDuration(_minLockDuration);
    }

    function totalAssets() public view virtual override returns (uint256) {
        return IBasicRewards(pool).balanceOf(address(this));
    }

    function maxDeposit(address) public pure override returns (uint256) {
        // TODO: could there be any limitations?
        return type(uint256).max;
    }

    function maxMint(address) public pure override returns (uint256) {
        // TODO: could there be any limitations?
        return type(uint256).max;
    }

    function updateTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;

        emit UpdateTreasury(_treasury);
    }

    function updateMinLockDuration(uint256 _minLockDuration) external onlyOwner {
        minLockDuration = _minLockDuration;

        emit UpdateMinLockDuration(_minLockDuration);
    }

    function _transfer(address, address, uint256) internal pure override {
        revert("Transfer not supported");
    }

    function _approve(address, address, uint256) internal pure override {
        revert("Approve not supported");
    }

    function depositBPT(uint256 amount, address receiver) external nonReentrant {
        require(amount > 0, "StakedBPT: amount is zero");

        IERC20(bpt).safeTransferFrom(msg.sender, address(this), amount);

        // Stake BPT to receive auraBal
        IERC20(bpt).approve(depositor, amount);
        ICrvDepositor(depositor).deposit(pid, amount, false);

        uint256 assets = IERC20(auraBal).balanceOf(address(this));
        _doDeposit(msg.sender, receiver, assets, previewDeposit(assets));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        require(assets > 0, "StakedBPT: assets is zero");

        IERC20(auraBal).safeTransferFrom(caller, address(this), assets);

        _doDeposit(caller, receiver, assets, shares);
    }

    function _doDeposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        // Stake auraBal
        IERC20(auraBal).approve(pool, assets);
        IBasicRewards(pool).stake(assets);

        _mint(receiver, shares);
        lastDepositTimestamp[caller] = block.timestamp;

        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        require(lastDepositTimestamp[owner] + minLockDuration <= block.timestamp, "StakedBPT: locked");

        // Receive auraBal
        IBasicRewards(pool).withdraw(assets, false);

        _burn(owner, shares);

        // Transfer auraBal
        IERC20(auraBal).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function withdrawBPT(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        require(assets <= maxWithdraw(owner), "ERC4626: withdraw more than max");

        uint256 shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        require(lastDepositTimestamp[owner] + minLockDuration <= block.timestamp, "StakedBPT: locked");

        // Receive BPT
        IBasicRewards(pool).withdraw(assets, false);
        IERC20(auraBal).approve(depositor, assets);
        ICrvDepositor(depositor).withdraw(pid, assets);

        _burn(owner, shares);

        // Transfer BPT
        IERC20(bpt).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return shares;
    }

    function harvest() public {
        IBasicRewards(pool).getReward();

        uint256 len = IBasicRewards(pool).extraRewardsLength();
        address[] memory rewardTokens = new address[](len + 1);
        rewardTokens[0] = IBasicRewards(pool).rewardToken();
        for (uint256 i; i < len; i++) {
            IStash stash = IStash(IVirtualRewards(IBasicRewards(pool).extraRewards(i)).rewardToken());
            rewardTokens[i + 1] = stash.baseToken();
        }

        // IERC20(rewardToken).safeTransfer(treasury, IERC20(rewardToken).balanceOf(address(this)));
        transferTokens(rewardTokens);
    }

    function transferTokens(address[] memory tokens) internal nonReentrant {
        for (uint256 i; i < tokens.length; ) {
            IERC20(tokens[i]).safeTransfer(treasury, IERC20(tokens[i]).balanceOf(address(this)));
            unchecked {
                ++i;
            }
        }
    }
}
