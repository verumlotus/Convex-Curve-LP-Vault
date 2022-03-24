// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./interfaces/IERC20.sol";
import "./WrappedConvexPosition.sol";
import "./libraries/Authorizable.sol";
import "./interfaces/external/IConvexBooster.sol";
import "./interfaces/external/IConvexBaseRewardPool.sol";
import "./interfaces/external/ISwapRouter.sol";

/**
 * @title Convex Asset Proxy
 * @notice Proxy for depositing Curve LP shares into Convex's system, and providing a shares based abstraction of ownership
 */
contract ConvexAssetProxy is WrappedConvexPosition, Authorizable {
    /************************************************
     *  STORAGE
     ***********************************************/
    /// @notice whether this proxy is paused or not
    bool public paused;

    /// @notice % fee keeper collects when calling harvest().
    /// Upper bound is 1000 (i.e 25 would be 2.5% of the total rewards)
    uint256 public keeperFee;

    /// @notice Contains multi-hop Uniswap V3 paths for trading CRV, CVX, & any other reward tokens
    /// index 0 is CRV path, index 1 is CVX path
    /// the order of other reward tokens should match the order of the basePoolRewards.extraRewards array
    bytes[] public swapPaths;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/
    /// @notice the pool id (in Convex's system) of the underlying token
    uint256 public immutable pid;

    /// @notice address of the convex Booster contract
    IConvexBooster public immutable booster;

    /// @notice address of the convex rewards contract
    IConvexBaseRewardPool public immutable rewardsContract;

    /// @notice Address of the deposit token 'reciepts' that are given to us
    /// by the booster contract when we deposit the underlying token
    IERC20 public immutable convexDepositToken;

    /// @notice Uniswap V3 router contract
    ISwapRouter public immutable router;

    /// @notice address of CRV, CVX, DAI, USDC, USDT
    IERC20 public constant crv =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant cvx =
        IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 public constant dai =
        IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public constant usdc =
        IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public constant usdt =
        IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    /************************************************
     *  EVENTS, STRUCTS, MODIFIERS
     ***********************************************/
    /// @notice struct that helps define parameters for a swap
    struct SwapHelper {
        address token; // reward token we are swapping
        uint256 deadline;
        uint256 amountOutMinimum;
    }

    // TODO: Emit events in important places

    /**
     * @notice Sets immutables & storage variables
     * @param _booster address of convex booster for underlying token
     * @param _rewardsContract address of convex rewards contract for underlying token
     * @param _convexDepositToken address of convex deposit token reciept minted by booster
     * @param _router address of Uniswap v3 router
     * @param _pid pool id of the underlying token (in the context of Convex's system)
     * @param _keeperFee the fee that a keeper recieves from calling harvest()
     * @param _crvSwapPath swap path for CRV token
     * @param _cvxSwapPath swap path for CVX token
     * @param _token The underlying token. This token should revert in the event of a transfer failure
     * @param _name The name of the token (shares) created by this contract
     * @param _symbol The symbol of the token (shares) created by this contract
     * @param _governance Governance address that can perform critical functions
     * @param _pauser Address that can pause this contract
     */
    constructor(
        IConvexBooster _booster,
        IConvexBaseRewardPool _rewardsContract,
        IERC20 _convexDepositToken,
        ISwapRouter _router,
        uint256 _pid,
        uint256 _keeperFee,
        bytes memory _crvSwapPath,
        bytes memory _cvxSwapPath,
        IERC20 _token,
        string memory _name,
        string memory _symbol,
        address _governance,
        address _pauser
    ) WrappedConvexPosition(_token, _name, _symbol) Authorizable() {
        // Authorize the pauser
        _authorize(_pauser);
        // set the owner
        setOwner(_governance);
        // Set the booster
        booster = _booster;
        // Set the rewards contract
        rewardsContract = _rewardsContract;
        // Set convexDepositToken
        convexDepositToken = _convexDepositToken;
        // Set uni v3 router address
        router = _router;
        // Set the pool id
        pid = _pid;
        // set keeper fee
        keeperFee = _keeperFee;
        // Add the swap paths
        swapPaths.push(_crvSwapPath);
        swapPaths.push(_cvxSwapPath);
        // Approve the booster so it can pull tokens from this address
        _token.approve(address(_booster), type(uint256).max);

        // We want our shares decimals to be the same as the convex deposit token decimals
        require(
            decimals == IERC20(_convexDepositToken).decimals(),
            "Inconsistent decimals"
        );
    }

    /// @notice Checks that the contract has not been paused
    modifier notPaused() {
        require(!paused, "Paused");
        _;
    }

    /**
     * @notice Deposits underlying token into booster contract & auto stakes the deposit tokens received in the rewardContract
     * @return Tuple (the shares to mint, amount of underlying token deposited)
     */
    function _deposit() internal override notPaused returns (uint256, uint256) {
        // Get the amount deposited
        uint256 amount = token.balanceOf(address(this));

        // // See how many deposit tokens we currently have
        // uint256 depositTokensBefore = rewardsContract.balanceOf(address(this));

        // Shares to be minted = (amount deposited * total shares) / total underlying token controlled by this contract
        // Note that convex deposit receipt tokens and underlying are in a 1:1 relationship
        // i.e for every 1 underlying we deposit we'd be credited with 1 deposit receipt token
        // So we can calculate the total amount deposited in underlying by querying for our balance of deposit receipt token
        uint256 sharesToMint = (amount * totalSupply) /
            rewardsContract.balanceOf(address(this));

        // Deposit underlying tokens
        // Last boolean indicates whether we want the Booster to auto-stake our deposit tokens in the reward contract for us
        booster.deposit(pid, amount, true);

        // Return the amount of shares the user has produced, and the amount used for it.
        return (sharesToMint, amount);
    }

    /**
     * @notice Calculates the amount of underlying token out & transfers it to _destination
     * @dev Shares must be burned AFTER this function is called to ensure bookkeeping is correct
     * @param _shares The number of wrapped position shares to withdraw
     * @param _destination The address to send the output funds
     * @return returns the amount of underlying tokens withdrawn
     */
    function _withdraw(
        uint256 _shares,
        address _destination,
        uint256
    ) internal override notPaused returns (uint256) {
        // We need to withdraw from the rewards contract & send to the destination
        // Boolean indicates that we don't want to collect rewards (this saves the user gas)
        uint256 amountUnderlyingToWithdraw = _sharesToUnderlying(_shares);
        rewardsContract.withdrawAndUnwrap(amountUnderlyingToWithdraw, false);

        // Transfer underlying LP tokens to user
        token.transfer(_destination, amountUnderlyingToWithdraw);

        // Return the amount of underlying
        return amountUnderlyingToWithdraw;
    }

    /**
     * @notice Get the underlying amount of tokens per shares given
     * @param _shares The amount of shares you want to know the value of
     * @return Value of shares in underlying token
     */
    function _sharesToUnderlying(uint256 _shares)
        internal
        view
        override
        returns (uint256)
    {
        return (_shares * _pricePerShare()) / (10**decimals);
    }

    /**
     * @notice Get the amount of underlying per share in the vault
     * @return returns the amount of underlying tokens per share
     */
    function _pricePerShare() internal view returns (uint256) {
        // Underlying per share = (1 / total Shares) * total amount of underlying controlled
        return
            ((10**decimals) * rewardsContract.balanceOf(address(this))) /
            totalSupply;
    }

    /**
     * @notice Reset approval for booster contract
     */
    function approve() external {
        token.approve(address(booster), 0);
        token.approve(address(booster), type(uint256).max);
    }

    /**
     * @notice Allows an authorized address or the owner to pause this contract
     * @param pauseStatus true for paused, false for not paused
     * @dev the caller must be authorized
     */
    function pause(bool pauseStatus) external onlyAuthorized {
        paused = pauseStatus;
    }

    /**
     * @notice sets a new keeper fee, only callable by owner
     * @param newFee the new keeper fee to set
     */
    function setKeeperFee(uint256 newFee) external onlyOwner {
        keeperFee = newFee;
    }

    /**
     * @notice Allows an authorized address to add a swap path
     * @param path new path to use for swapping
     * @dev the caller must be authorized
     */
    function addSwapPath(bytes calldata path) external onlyAuthorized {
        // Push dummy path to expand array, then call setPath
        swapPaths.push("");
        setSwapPath(swapPaths.length - 1, path);
    }

    /**
     * @notice Allows an authorized address to delete a swap path
     * @dev note we only allow deleting the last path to avoid a gap in our array
     * If a path besides the last path must be deleted, deletePath & addSwapPath will have to be called
     * in an appropriate order
     */
    function deleteSwapPath() external onlyAuthorized {
        delete swapPaths[swapPaths.length - 1];
    }

    /**
     * @notice Allows an authorized address to set the swap path for this contract
     * @param index index in swapPaths array to overwrite
     * @param path new path to use for swapping
     * @dev the caller must be authorized
     */
    function setSwapPath(uint256 index, bytes memory path)
        public
        onlyAuthorized
    {
        // Multihop paths are of the form [tokenA, fee, tokenB, fee, tokenC, ... finalToken]
        // Let's ensure that a compromised authorized address cannot rug
        // by verifying that the input & output tokens are whitelisted (ie output is part of 3CRV pool - DAI, USDC, or USDT)
        address inputToken;
        address outputToken;
        uint256 lengthOfPath = path.length;
        assembly {
            // skip length (first 32 bytes) to load in the next 32 bytes. Now truncate to get only first 20 bytes
            // Address is 20 bytes, and truncates by taking the last 20 bytes of a 32 byte word.
            // So, we shift right by 12 bytes (96 bits)
            inputToken := shr(96, mload(add(path, 0x20)))
            // get the last 20 bytes of path
            // This is skip first 32 bytes, move to end of path array, then move back 20 to start of final outputToken address
            // Truncate to only get first 20 bytes
            outputToken := shr(
                96,
                mload(sub(add(add(path, 0x20), lengthOfPath), 0x14))
            )
        }

        if (index == 0 || index == 1) {
            require(
                inputToken == address(crv) || inputToken == address(cvx),
                "Invalid input token"
            );
        }

        require(
            outputToken == address(dai) ||
                outputToken == address(usdc) ||
                outputToken == address(usdt),
            "Invalid output token"
        );

        // Set the swap path
        swapPaths[index] = path;
    }

    /**
     * @notice harvest logic to collect rewards in CRV, CVX, etc. The caller will receive a % of rewards (set by keeperFee)
     * @param SwapParams a list of structs, one for each swap to be made, defining useful parameters
     * @dev keeper will receive all rewards in the underlying token
     * @dev most importantly, each SwapParams should have a reasonable amountOutMinimum to prevent egregious sandwich attacks or frontrunning
     * @dev we must have a swapPaths path for each reward token we wish to swap
     */
    function harvest(SwapHelper[] memory swapHelpers) external onlyAuthorized {
        // Collect our rewards, will also collect extra rewards
        rewardsContract.getReward();

        SwapHelper memory currParamHelper;
        ISwapRouter.ExactInputParams memory params;
        uint256 rewardTokenEarned;

        // Let's swap all the tokens we need to
        for (uint256 i = 0; i < swapHelpers.length; i++) {
            currParamHelper = swapHelpers[i];
            IERC20 rewardToken = IERC20(currParamHelper.token);

            // Check to make sure that this isn't the underlying token or the deposit token
            require(
                address(rewardToken) != address(token) &&
                    address(rewardToken) != address(convexDepositToken),
                "Attempting to swap underlying or deposit token"
            );

            rewardTokenEarned = rewardToken.balanceOf(address(this));
            if (rewardTokenEarned > 0) {
                // Approve router to use our rewardToken
                rewardToken.approve(address(router), rewardTokenEarned);

                // Create params for the swap
                currParamHelper = swapHelpers[i];
                params = ISwapRouter.ExactInputParams({
                    path: swapPaths[i],
                    recipient: address(this),
                    deadline: currParamHelper.deadline,
                    amountIn: rewardTokenEarned,
                    amountOutMinimum: currParamHelper.amountOutMinimum
                });
                router.exactInput(params);
            }
        }
    }
}
