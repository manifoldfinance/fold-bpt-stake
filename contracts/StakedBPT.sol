// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ICrvDepositor.sol";
import "./interfaces/IBasicRewards.sol";
import "./interfaces/IVirtualRewards.sol";
import "./interfaces/IStash.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IBPT.sol";
import "./library/BPTCalculator.sol";

// Take BPT -> Stake on Aura -> Someone need to pay to harvest rewards -> Send to treasury multisig
contract StakedBPT is ERC4626, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

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
        weth = IWETH(_weth);
        bal = IVault(_vault);
        poolId = _poolId;

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

    function zapBPT(uint256[] memory amounts, address receiver) external payable nonReentrant {
        (address[] memory tokens, uint256[] memory balances, ) = bal.getPoolTokens(poolId);
        for (uint256 i; i < tokens.length; i++) {
            require(amounts[i] > 0, "StakedBPT: amount is zero");
            if (tokens[i] == address(weth) && msg.value > 0) {
                require(amounts[i] == msg.value, "StakedBPT: amount mismatch");
                weth.deposit{value: msg.value}();
            } else {
                IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
            IERC20(tokens[i]).approve(address(bal), amounts[i]);
        }

        uint256 bptAmount;
        {
            uint256 bptTotalSupply = IBPT(bpt).getActualSupply();
            uint256 swapFeePercentage = IBPT(bpt).getSwapFeePercentage();
            uint256[] memory normalizedWeights = getNormalizedWeights();
            bptAmount = BPTCalculator.calculateBPTOut(
                bptTotalSupply,
                swapFeePercentage,
                amounts,
                balances,
                normalizedWeights
            );
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
        amount = IERC20(bpt).balanceOf(address(this));
        IERC20(bpt).approve(depositor, amount);
        ICrvDepositor(depositor).deposit(pid, amount, false);

        uint256 aurBal = IERC20(auraBal).balanceOf(address(this));
        _doDeposit(msg.sender, receiver, aurBal, previewDeposit(aurBal));
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

    // // Function to calculate BPT out given exact tokens in
    // function calcBptOutGivenExactTokensIn(
    //     uint256 amp,
    //     uint256[] memory balances,
    //     uint256[] memory amountsIn,
    //     uint256 bptTotalSupply,
    //     uint256 swapFeePercentage
    // ) internal pure returns (uint256) {
    //     // BPT out, so we round down overall.
    //     // First loop calculates the sum of all token balances, which will be used to calculate the current weights of each token, relative to this sum
    //     uint256 sumBalances = 0;
    //     for (uint256 i = 0; i < balances.length; i++) {
    //         sumBalances += balances[i];
    //     }

    //     // Calculate the weighted balance ratio without considering fees
    //     uint256[] memory balanceRatiosWithFee = new uint256[](amountsIn.length);
    //     // The weighted sum of token balance ratios without fee
    //     uint256 invariantRatioWithFees = 0;
    //     for (uint256 i = 0; i < balances.length; i++) {
    //         uint256 currentWeight = (balances[i] * 1e18) / sumBalances;
    //         balanceRatiosWithFee[i] = (balances[i] + amountsIn[i]) * 1e18 / balances[i];
    //         invariantRatioWithFees += (balanceRatiosWithFee[i] * currentWeight) / 1e18;
    //     }

    //     // Second loop calculates new amounts in, taking into account the fee on the percentage excess
    //     uint256[] memory newBalances = new uint256[](balances.length);
    //     for (uint256 i = 0; i < balances.length; i++) {
    //         uint256 amountInWithoutFee;

    //         // Check if the balance ratio is greater than the ideal ratio to charge fees or not
    //         if (balanceRatiosWithFee[i] > invariantRatioWithFees) {
    //             uint256 nonTaxableAmount = (balances[i] * (invariantRatioWithFees - 1e18)) / 1e18;
    //             uint256 taxableAmount = amountsIn[i] - nonTaxableAmount;
    //             amountInWithoutFee = nonTaxableAmount + (taxableAmount * (1e18 - swapFeePercentage)) / 1e18;
    //         } else {
    //             amountInWithoutFee = amountsIn[i];
    //         }

    //         newBalances[i] = balances[i] + amountInWithoutFee;
    //     }

    //     // Get current and new invariants, taking swap fees into account
    //     uint256 currentInvariant = calculateInvariant(amp, balances, true);
    //     uint256 newInvariant = calculateInvariant(amp, newBalances, false);
    //     uint256 invariantRatio = (newInvariant * 1e18) / currentInvariant;

    //     // If the invariant didn't increase for any reason, we simply don't mint BPT
    //     if (invariantRatio > 1e18) {
    //         return (bptTotalSupply * (invariantRatio - 1e18)) / 1e18;
    //     } else {
    //         return 0;
    //     }
    // }

    // // Constants
    // uint256 internal constant AMP_PRECISION = 1000;

    // // Function to calculate the invariant using the Newton-Raphson approximation
    // // Function to calculate the invariant using the Newton-Raphson approximation
    // function calculateInvariant(
    //     uint256 amplificationParameter,
    //     uint256[] memory balances,
    //     bool roundUp
    // ) internal pure returns (uint256) {
    //     // We support rounding up or down.

    //     uint256 sum = 0;
    //     uint256 numTokens = balances.length;
    //     for (uint256 i = 0; i < numTokens; i++) {
    //         sum += balances[i];
    //     }

    //     if (sum == 0) {
    //         return 0;
    //     }

    //     uint256 prevInvariant = 0;
    //     uint256 invariant = sum;
    //     uint256 ampTimesTotal = amplificationParameter * numTokens;

    //     for (uint256 i = 0; i < 255; i++) {
    //         uint256 P_D = numTokens * balances[0];
    //         for (uint256 j = 1; j < numTokens; j++) {
    //             P_D = (P_D * balances[j] * numTokens) / invariant;
    //         }

    //         prevInvariant = invariant;
    //         invariant = (numTokens * invariant * invariant + ampTimesTotal * sum * P_D) /
    //             (numTokens + 1 + (ampTimesTotal - AMP_PRECISION) * P_D / AMP_PRECISION);

    //         if (invariant > prevInvariant) {
    //             if ((invariant - prevInvariant) <= 1) {
    //                 return invariant;
    //             }
    //         } else if ((prevInvariant - invariant) <= 1) {
    //             return invariant;
    //         }
    //     }

    //     revert("STABLE_GET_BALANCE_DIDNT_CONVERGE");
    // }

    // function _calculateInvariant(uint256[] memory normalizedWeights, uint256[] memory balances)
    //     internal
    //     pure
    //     returns (uint256 invariant)
    // {
    //     /**********************************************************************************************
    //     // invariant               _____                                                             //
    //     // wi = weight index i      | |      wi                                                      //
    //     // bi = balance index i     | |  bi ^   = i                                                  //
    //     // i = invariant                                                                             //
    //     **********************************************************************************************/

    //     invariant = 1;
    //     for (uint256 i = 0; i < normalizedWeights.length; i++) {
    //         invariant = invariant.mulDown(balances[i].powDown(normalizedWeights[i]));
    //     }

    //     // _require(invariant > 0, Errors.ZERO_INVARIANT);
    // }
}
