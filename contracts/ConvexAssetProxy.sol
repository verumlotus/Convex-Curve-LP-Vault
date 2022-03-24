// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./interfaces/IERC20.sol";
import "./WrappedConvexPosition.sol";
import "./libraries/Authorizable.sol";
import "./interfaces/external/IConvexBooster.sol";
import "./interfaces/external/IConvexBaseRewardPool.sol";

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

    /// @notice address of CRV, CVX, DAI, USDC, USDT
    address public constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant cvx = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address public constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /************************************************
     *  EVENTS, ERRORS, MODIFIERS
     ***********************************************/
    // TODO: Emit events in important places

    /**
     * @notice Sets immutables & storage variables
     * @param _booster address of convex booster for underlying token
     * @param _rewardsContract address of convex rewards contract for underlying token
     * @param _convexDepositToken address of convex deposit token reciept minted by booster
     * @param _pid pool id of the underlying token (in the context of Convex's system)
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
        uint256 _pid,
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
        // Set the pool id
        pid = _pid;
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
     * @notice Allows an authorized address to add a swap path
     * @param path new path to use for swapping
     * @dev the caller must be authorized
     */
    function addSwapPath(bytes calldata path) external onlyAuthorized {
        swapPaths.push(path);
    }

    /**
     * @notice Allows an authorized address to set the swap path for this contract
     * @param index index in swapPaths array to overwrite
     * @param path new path to use for swapping
     * @dev the caller must be authorized
     */
    function setSwapPath(uint256 index, bytes memory path)
        external
        onlyAuthorized
    {
        // Multihop paths are of the form [tokenA, fee, tokenB, fee, tokenC, ... finalToken]
        // If the index is 0 (CRV) or 1 (CVX) let's ensure that a compromised authorized address cannot rug
        // by verifying that the input & output tokens are whitelisted (ie output is part of 3CRV pool - DAI, USDC, or USDT)
        if (index == 0 || index == 1) {
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

            require(
                inputToken == crv || inputToken == cvx,
                "Invalid input token"
            );
            require(
                outputToken == dai ||
                    outputToken == usdc ||
                    outputToken == usdt,
                "Invalid output token"
            );
        }

        // Set the swap path
        swapPaths[index] = path;
    }
}
