// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@solmate/mixins/ERC4626.sol";
import "@solmate/auth/Owned.sol";
import "@solmate/utils/ReentrancyGuard.sol";
import "@solmate/utils/SafeTransferLib.sol";
import "./interfaces/ICrvDepositor.sol";
import "./interfaces/IBasicRewards.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IVirtualRewards.sol";
import "./interfaces/IStash.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IBPT.sol";

// Take BPT -> Stake on Aura -> Someone need to pay to harvest rewards -> Send to treasury multisig
contract StakedBPT is ERC4626, ReentrancyGuard, Owned {
    using SafeTransferLib for ERC20;

    address public immutable bpt;
    address public immutable auraBal;
    address public immutable depositor;
    address public immutable pool;
    IWETH public immutable weth;
    IVault public immutable bal;
    address public treasury;
    uint256 public minLockDuration;
    uint256 public pid;
    mapping(address => uint256) public lastDepositTimestamp;
    bytes32 public immutable poolId;

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
        address _weth,
        address _vault,
        uint256 _pid,
        bytes32 _poolId
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
        pid = _pid;
        weth = IWETH(_weth);
        bal = IVault(_vault);
        poolId = _poolId;

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
    /// BPT functions
    ///

    function depositBPT(uint256 bptAmount, address receiver) public virtual returns (uint256 shares) {
        ERC20(bpt).safeTransferFrom(msg.sender, address(this), bptAmount);

        // Stake BPT to receive auraBal
        IERC20(bpt).approve(depositor, bptAmount);
        ICrvDepositor(depositor).deposit(pid, bptAmount, false);

        uint256 assets = IERC20(auraBal).balanceOf(address(this));

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    /// Hooks for regular assets

    function afterDeposit(uint256 assets, uint256) internal override {
        IERC20(auraBal).approve(pool, assets);
        IBasicRewards(pool).stake(assets);

        lastDepositTimestamp[msg.sender] = block.timestamp;
    }

    /// @dev Zap pool token => BPT => AuraBPT => StakedAuraBPT
    ///      Assumes: 2 token pool, 18 decimals, one sided liquidity provision (with a trace amount of other token, eg eth)
    function zapBPT(uint256[] memory amounts, address receiver) external payable nonReentrant returns (uint256 shares) {
        (address[] memory tokens, uint256[] memory balances, ) = bal.getPoolTokens(poolId);
        uint256[] memory decimals = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            require(amounts[i] > 0, "StakedBPT: amount is zero");
            if (tokens[i] == address(weth) && msg.value > 0) {
                require(amounts[i] == msg.value, "StakedBPT: amount mismatch");
                weth.deposit{value: msg.value}();
            } else {
                ERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
            decimals[i] = IERC20(tokens[i]).decimals();
            IERC20(tokens[i]).approve(address(bal), amounts[i]);
        }

        uint256 bptAmount;
        {
            uint256 bptTotalSupply = IBPT(bpt).totalSupply();
            uint256 price = IBPT(bpt).getPrice();
            bptAmount = calculateBptDesired(bptTotalSupply, price, balances, amounts);
        }

        bytes memory userData = abi.encode(3, bptAmount);

        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
            assets: tokens,
            maxAmountsIn: amounts,
            userData: userData,
            fromInternalBalance: false
        });
        address sender = address(this);
        address recipient = sender;
        bal.joinPool(poolId, sender, recipient, request);

        // Stake BPT to receive auraBal
        uint256 amount = IERC20(bpt).balanceOf(address(this));
        IERC20(bpt).approve(depositor, amount);
        ICrvDepositor(depositor).deposit(pid, amount, false);

        uint256 assets = IERC20(auraBal).balanceOf(address(this));

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);

        // refund dust
        for (uint256 i; i < tokens.length; i++) {
            ERC20(tokens[i]).safeTransfer(msg.sender, IERC20(tokens[i]).balanceOf(address(this)));
        }
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        require(lastDepositTimestamp[owner] + minLockDuration <= block.timestamp, "StakedBPT: locked");

        // Receive auraBal
        IBasicRewards(pool).withdraw(assets, false);
    }

    function harvest() public {
        ICrvDepositor(depositor).earmarkRewards(pid);
        IBasicRewards(pool).getReward();
        uint256 len = IBasicRewards(pool).extraRewardsLength();
        address[] memory rewardTokens = new address[](len + 1);
        rewardTokens[0] = IBasicRewards(pool).rewardToken();
        for (uint256 i; i < len; i++) {
            IStash stash = IStash(IVirtualRewards(IBasicRewards(pool).extraRewards(i)).rewardToken());
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

    /// @dev simplified bptOut calculation modified from https://github.com/gyrostable/app/blob/main/src/utils/pools/calculateBptDesired.ts
    ///      Assumes: 2 token pool, 18 decimals, one sided liquidity provision
    function calculateBptDesired(
        uint256 totalShares,
        uint256 price0in1,
        uint256[] memory balances,
        uint256[] memory amounts
    ) internal pure returns (uint256 bptOut) {
        uint256 inputValue;
        if (amounts[0] > amounts[1]) {
            inputValue = amounts[0] * price0in1;
        } else {
            inputValue = amounts[1] * 10 ** 18;
        }
        uint256 totalValue = (balances[0] * price0in1 + balances[1] * 10 ** 18) / 10 ** 18;
        uint256 multiplier = inputValue / totalValue;
        bptOut = (totalShares * multiplier) / 10 ** 18;
    }
}
