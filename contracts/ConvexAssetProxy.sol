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
    /// @notice address of the convex Booster contract
    IConvexBooster public booster;

    /// @notice address of the convex rewards contract
    IConvexBaseRewardPool public rewardsContract;

    /// @notice whether this proxy is paused or not
    bool public paused;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/
    /// @notice the pool id (in Convex's system) of the underlying token
    uint256 public immutable pid;

    /// @notice the number of decimals in our vault
    uint256 public immutable vaultDecimals;

    /// @notice Address of the deposit token 'reciepts' that are given to us
    /// by the booster contract when we deposit the underlying token
    IERC20 public immutable convexDepositToken;

    /************************************************
     *  EVENTS, ERRORS, MODIFIERS
     ***********************************************/

    /**
     * @notice Sets immutables & storage variables
     * @param _booster address of convex booster for underlying token
     * @param _rewardsContract address of convex rewards contract for underlying token
     * @param _convexDepositToken address of convex deposit token reciept minted by booster
     * @param _pid pool id of the underlying token (in the context of Convex's system)
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
        // Approve the booster so it can pull tokens from this address
        _token.approve(booster, type(uint256).max);

        // We want our shares decimals to be the same as the convex deposit token decimals
        require(
            decimals() == IERC20(convexDepositToken).decimals(),
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
        uint256 sharesToMint = (amount * totalSupply()) /
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
        // Withdraws shares from the vault. Max loss is set at 100% as
        // the minimum output value is enforced by the calling
        // function in the WrappedPosition contract.
        uint256 amountReceived = vault.withdraw(_shares, _destination, 10000);

        // Amount underlying token out = (shares to burn / total shares) * total underlying token controlled by this contract
        uint256 underlyingOut = (_shares *
            rewardsContract.balanceOf(address(this))) / totalSupply();

        // We need to withdraw from the rewards contract & send to the destination
        // Boolean indicates that we don't want to collect rewards (this saves the user gas)
        uint256 amountUnderlyingToWithdraw = _sharesToUnderlying(_shares);
        rewardsContract.withdrawAndUnwrap(amountUnderlyingToWithdraw, false);

        // Transfer underlying LP tokens to user
        token.transfer(_destination, amountUnderlyingToWithdraw);

        // Return the amount of underlying
        return amountUnderlyingToWithdraw;
    }

    /// @notice Get the underlying amount of tokens per shares given
    /// @param _amount The amount of shares you want to know the value of
    /// @return Value of shares in underlying token
    function _sharesToUnderlying(uint256 _amount)
        internal
        view
        override
        returns (uint256)
    {
        // We may have to convert before using the vault price per share
        if (conversionRate != 0) {
            // Imitate the _withdraw logic and convert this amount to yearn vault2 shares
            _amount = (_amount * 1e18) / conversionRate;
        }
        return (_amount * _pricePerShare()) / (10**vaultDecimals);
    }

    /// @notice Get the price per share in the vault
    /// @return The price per share in units of underlying;
    function _pricePerShare() internal view returns (uint256) {
        return vault.pricePerShare();
    }

    /// @notice Function to reset approvals for the proxy
    function approve() external {
        token.approve(address(vault), 0);
        token.approve(address(vault), type(uint256).max);
    }

    /// @notice Allows an authorized address or the owner to pause this contract
    /// @param pauseStatus true for paused, false for not paused
    /// @dev the caller must be authorized
    function pause(bool pauseStatus) external onlyAuthorized {
        paused = pauseStatus;
    }

    /// @notice Function to transition between two yearn vaults
    /// @param newVault The address of the new vault
    /// @param minOutputShares The min of the new yearn vault's shares the wp will receive
    /// @dev WARNING - This function has the capacity to steal all user funds from this
    ///                contract and so it should be ensured that the owner is a high quorum
    ///                governance vote through the time lock.
    function transition(IYearnVault newVault, uint256 minOutputShares)
        external
        onlyOwner
    {
        // Load the current vault's price per share
        uint256 currentPricePerShare = _pricePerShare();
        // Load the new vault's price per share
        uint256 newPricePerShare = newVault.pricePerShare();
        // Load the current conversion rate or set it to 1
        uint256 newConversionRate = conversionRate == 0 ? 1e18 : conversionRate;
        // Calculate the new conversion rate, note by multiplying by the old
        // conversion rate here we implicitly support more than 1 upgrade
        newConversionRate =
            (newConversionRate * newPricePerShare) /
            currentPricePerShare;
        // We now withdraw from the old yearn vault using max shares
        // Note - Vaults should be checked in the future that they still have this behavior
        vault.withdraw(type(uint256).max, address(this), 10000);
        // Approve the new vault
        token.approve(address(newVault), type(uint256).max);
        // Then we deposit into the new vault
        uint256 currentBalance = token.balanceOf(address(this));
        uint256 outputShares = newVault.deposit(currentBalance, address(this));
        // We enforce a min output
        require(outputShares >= minOutputShares, "Not enough output");
        // Change the stored variables
        vault = newVault;
        // because of the truncation yearn vaults can't have a larger diff than ~ billion
        // times larger
        conversionRate = uint88(newConversionRate);
    }
}
