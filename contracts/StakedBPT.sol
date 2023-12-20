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
import "./interfaces/IVault.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IBPT.sol";

/**
 * @title StakedBPT
 * @dev StakedBPT is a contract that represents staked LP (Liquidity Provider) tokens,
 * allowing users to stake their LP tokens to earn rewards in another token (cvxtoken).
 * This contract extends ERC4626, implements ReentrancyGuard, and is Owned.
 */
contract StakedBPT is ERC4626, ReentrancyGuard, Owned {
    using SafeTransferLib for ERC20;

    address public immutable lptoken;
    address public immutable cvxtoken;
    IBooster public immutable booster;
    IRewards public immutable crvRewards;

    uint256 public immutable pid;

    // address public immutable bpt;
    // address public immutable auraBal;
    // address public immutable depositor;
    // address public immutable pool;
    IWETH public immutable weth;
    IVault public immutable bal;
    address public treasury;
    uint256 public minLockDuration;
    bytes32 public immutable poolId;
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
     * @param _cvxtoken Address of the reward token (AUR / CVX)
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
        bal = IVault(_vault);
        poolId = _poolId;

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
            for (uint256 i; i < len; ) {
                address virtualRewards = crvRewards.extraRewards(i);
                rewardTokens[i] = _getStashToken(virtualRewards);
                unchecked {
                    ++i;
                }
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
        for (uint256 i; i < tokens.length; ) {
            uint256 amount = IERC20(tokens[i]).balanceOf(address(this));
            if (amount > 0) {
                ERC20(tokens[i]).safeTransfer(treasury, amount);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Zap into the Balancer pool by providing tokens and receiving staked LP tokens in return.
     *      Assumes: 2 token pool, 18 decimals, one sided liquidity provision (with a trace amount of other token, eg eth)
     * @param amounts Array of amounts of tokens to be provided.
     * @param receiver Address to receive the staked LP tokens.
     * @return shares Number of shares representing the staked LP tokens.
     */
    function zapBPT(uint256[] memory amounts, address receiver) external payable nonReentrant returns (uint256 shares) {
        (address[] memory tokens, uint256[] memory balances, ) = bal.getPoolTokens(poolId);
        uint256[] memory decimals = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; i = _inc(i)) {
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

        uint256 lptokenAmount;
        {
            uint256 lptokenTotalSupply = IBPT(lptoken).totalSupply();
            uint256 price = IBPT(lptoken).getPrice();
            lptokenAmount = calculateBptDesired(lptokenTotalSupply, price, balances, amounts);
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
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

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
        require(shares <= maxRedeem(owner), "ERC4626: withdraw more than max");

        uint256 assets = previewRedeem(shares);

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        require(lastDepositTimestamp[owner] + minLockDuration <= block.timestamp, "StakedBPT: locked");

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

    /**
     * @dev Calculate the desired amount of BPT to be received when zapping into a Balancer pool.
     *      Simplified lptokenOut calculation modified from https://github.com/gyrostable/app/blob/main/src/utils/pools/calculateBptDesired.ts
     * @param totalShares Total supply of the BPT token.
     * @param price0in1 Price of token0 in terms of token1.
     * @param balances Array of token balances in the Balancer pool.
     * @param amounts Array of token amounts being provided.
     * @return bptOut Desired amount of BPT to be received.
     */
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
