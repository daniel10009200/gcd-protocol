// SPDX-License-Identifier: bsl-1.1

/*
  Copyright 2020 Unit Protocol: Artem Zakharov (az@unit.xyz).
*/
pragma solidity ^0.8.15;

import "./VaultParameters.sol";
import "./helpers/TransferHelper.sol";
import "./GCD.sol";
import "./interfaces/IWETH.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';

/**
 * @title Vault
 * @notice Vault is the core of GCD Protocol GCD Stablecoin system
 * @notice Vault stores and manages collateral funds of all positions and counts debts
 * @notice Only Vault can manage supply of GCD token
 * @notice Vault will not be changed/upgraded after initial deployment for the current stablecoin version
 **/
contract Vault is Initializable, UUPSUpgradeable, AuthInitializable {

    // WETH token address
    address payable public weth;

    uint public constant DENOMINATOR_1E5 = 1e5;

    uint public constant DENOMINATOR_1E2 = 1e2;

    // GCD token address
    address public gcd;

    // collaterals whitelist
    mapping(address => mapping(address => uint)) public collaterals;

    // user debts
    mapping(address => mapping(address => uint)) public debts;

    // block number of liquidation trigger
    mapping(address => mapping(address => uint)) public liquidationBlock;

    // initial price of collateral
    mapping(address => mapping(address => uint)) public liquidationPrice;

    // debts of tokens
    mapping(address => uint) public tokenDebts;

    // stability fee pinned to each position
    mapping(address => mapping(address => uint)) public stabilityFee;

    // liquidation fee pinned to each position, 0 decimals
    mapping(address => mapping(address => uint)) public liquidationFee;

    // type of using oracle pinned for each position
    mapping(address => mapping(address => uint)) public oracleType;

    // timestamp of the last update
    mapping(address => mapping(address => uint)) public lastUpdate;

    modifier notLiquidating(address asset, address user) {
        require(liquidationBlock[asset][user] == 0, "GCD Protocol: LIQUIDATING_POSITION");
        _;
    }

    /**
     * @param _parameters The address of the system parameters
     * @param _gcd GCD token address
     **/
    function initialize(
        address _parameters, 
        address _gcd, 
        address payable _weth
    ) public initializer {
        initializeAuth(_parameters);
        gcd = _gcd;
        weth = _weth;
    }

    /**
      * Restricted upgrades function
     **/
    function _authorizeUpgrade(address) internal override onlyManager {}

    // only accept ETH via fallback from the WETH contract
    receive() external payable {
        require(msg.sender == weth, "GCD Protocol: RESTRICTED");
    }

    /**
     * @dev Updates parameters of the position to the current ones
     * @param asset The address of the main collateral token
     * @param user The owner of a position
     **/
    function update(address asset, address user) public hasVaultAccess notLiquidating(asset, user) {

        // calculate fee using stored stability fee
        uint debtWithFee = getTotalDebt(asset, user);
        tokenDebts[asset] = tokenDebts[asset] - debts[asset][user] + debtWithFee;
        debts[asset][user] = debtWithFee;

        stabilityFee[asset][user] = vaultParameters.stabilityFee(asset);
        liquidationFee[asset][user] = vaultParameters.liquidationFee(asset);
        lastUpdate[asset][user] = block.timestamp;
    }

    /**
     * @dev Creates new position for user
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @param _oracleType The type of an oracle
     **/
    function spawn(address asset, address user, uint _oracleType) external hasVaultAccess notLiquidating(asset, user) {
        oracleType[asset][user] = _oracleType;
        delete liquidationBlock[asset][user];
    }

    /**
     * @dev Clears unused storage variables
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     **/
    function destroy(address asset, address user) public hasVaultAccess notLiquidating(asset, user) {
        delete stabilityFee[asset][user];
        delete oracleType[asset][user];
        delete lastUpdate[asset][user];
        delete liquidationFee[asset][user];
    }

    /**
     * @notice Tokens must be pre-approved
     * @dev Adds main collateral to a position
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @param amount The amount of tokens to deposit
     **/
    function depositMain(address asset, address user, uint amount) external hasVaultAccess notLiquidating(asset, user) {
        collaterals[asset][user] = collaterals[asset][user] + amount;
        TransferHelper.safeTransferFrom(asset, user, address(this), amount);
    }

    /**
     * @dev Converts ETH to WETH and adds main collateral to a position
     * @param user The address of a position's owner
     **/
    function depositEth(address user) external payable notLiquidating(weth, user) {
        IWETH(weth).deposit{value: msg.value}();
        collaterals[weth][user] = collaterals[weth][user] + msg.value;
    }

    /**
     * @dev Withdraws main collateral from a position
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @param amount The amount of tokens to withdraw
     **/
    function withdrawMain(address asset, address user, uint amount) external hasVaultAccess notLiquidating(asset, user) {
        collaterals[asset][user] = collaterals[asset][user] - amount;
        TransferHelper.safeTransfer(asset, user, amount);
    }

    /**
     * @dev Withdraws WETH collateral from a position converting WETH to ETH
     * @param user The address of a position's owner
     * @param amount The amount of ETH to withdraw
     **/
    function withdrawEth(address payable user, uint amount) external hasVaultAccess notLiquidating(weth, user) {
        collaterals[weth][user] = collaterals[weth][user] - amount;
        IWETH(weth).withdraw(amount);
        TransferHelper.safeTransferETH(user, amount);
    }

    /**
     * @dev Increases position's debt and mints GCD token
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @param amount The amount of GCD to borrow
     **/
    function borrow(
        address asset,
        address user,
        uint amount
    )
    external
    hasVaultAccess
    notLiquidating(asset, user)
    returns(uint)
    {
        require(vaultParameters.isOracleTypeEnabled(oracleType[asset][user], asset), "GCD Protocol: WRONG_ORACLE_TYPE");
        update(asset, user);
        debts[asset][user] = debts[asset][user] + amount;
        tokenDebts[asset] = tokenDebts[asset] + amount;

        // check GCD limit for token
        require(tokenDebts[asset] <= vaultParameters.tokenDebtLimit(asset), "GCD Protocol: ASSET_DEBT_LIMIT");

        GCD(gcd).mint(user, amount);

        return debts[asset][user];
    }

    /**
     * @dev Decreases position's debt and burns GCD token
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @param amount The amount of GCD to repay
     * @return updated debt of a position
     **/
    function repay(
        address asset,
        address user,
        uint amount
    )
    external
    hasVaultAccess
    notLiquidating(asset, user)
    returns(uint)
    {
        uint debt = debts[asset][user];
        debts[asset][user] = debt - amount;
        tokenDebts[asset] = tokenDebts[asset] - amount;
        GCD(gcd).burn(user, amount);

        return debts[asset][user]; //!
    }

    /**
     * @dev Transfers fee to foundation
     * @param asset The address of the fee asset
     * @param user The address to transfer funds from
     * @param amount The amount of asset to transfer
     **/
    function chargeFee(address asset, address user, uint amount) external hasVaultAccess notLiquidating(asset, user) {
        if (amount != 0) {
            TransferHelper.safeTransferFrom(asset, user, vaultParameters.foundation(), amount);
        }
    }

    /**
     * @dev Deletes position and transfers collateral to liquidation system
     * @param asset The address of the main collateral token
     * @param positionOwner The address of a position's owner
     * @param initialPrice The starting price of collateral in GCD
     **/
    function triggerLiquidation(
        address asset,
        address positionOwner,
        uint initialPrice
    )
    external
    hasVaultAccess
    notLiquidating(asset, positionOwner)
    {
        // reverts if oracle type is disabled
        require(vaultParameters.isOracleTypeEnabled(oracleType[asset][positionOwner], asset), "GCD Protocol: WRONG_ORACLE_TYPE");

        // fix the debt
        debts[asset][positionOwner] = getTotalDebt(asset, positionOwner);

        liquidationBlock[asset][positionOwner] = block.number;
        liquidationPrice[asset][positionOwner] = initialPrice;
    }

    /**
     * @dev Internal liquidation process
     * @param asset The address of the main collateral token
     * @param positionOwner The address of a position's owner
     * @param mainAssetToLiquidator The amount of main asset to send to a liquidator
     * @param mainAssetToPositionOwner The amount of main asset to send to a position owner
     * @param repayment The repayment in GCD
     * @param penalty The liquidation penalty in GCD
     * @param liquidator The address of a liquidator
     **/
    function liquidate(
        address asset,
        address positionOwner,
        uint mainAssetToLiquidator,
        uint mainAssetToPositionOwner,
        uint repayment,
        uint penalty,
        address liquidator
    )
        external
        hasVaultAccess
    {
        require(liquidationBlock[asset][positionOwner] != 0, "GCD Protocol: NOT_TRIGGERED_LIQUIDATION");

        uint mainAssetInPosition = collaterals[asset][positionOwner];
        uint mainAssetToFoundation = mainAssetInPosition - mainAssetToLiquidator - mainAssetToPositionOwner;

        delete liquidationPrice[asset][positionOwner];
        delete liquidationBlock[asset][positionOwner];
        delete debts[asset][positionOwner];
        delete collaterals[asset][positionOwner];

        destroy(asset, positionOwner);

        // charge liquidation fee and burn GCD
        if (repayment > penalty) {
            if (penalty != 0) {
                TransferHelper.safeTransferFrom(gcd, liquidator, vaultParameters.foundation(), penalty);
            }
            GCD(gcd).burn(liquidator, repayment - penalty);
        } else {
            if (repayment != 0) {
                TransferHelper.safeTransferFrom(gcd, liquidator, vaultParameters.foundation(), repayment);
            }
        }

        // send the part of collateral to a liquidator
        if (mainAssetToLiquidator != 0) {
            TransferHelper.safeTransfer(asset, liquidator, mainAssetToLiquidator);
        }

        // send the rest of collateral to a position owner
        if (mainAssetToPositionOwner != 0) {
            TransferHelper.safeTransfer(asset, positionOwner, mainAssetToPositionOwner);
        }

        if (mainAssetToFoundation != 0) {
            TransferHelper.safeTransfer(asset, vaultParameters.foundation(), mainAssetToFoundation);
        }
    }

    /**
     * @notice Only manager can call this function
     * @dev Changes broken oracle type to the correct one
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @param newOracleType The new type of an oracle
     **/
    function changeOracleType(address asset, address user, uint newOracleType) external onlyManager {
        oracleType[asset][user] = newOracleType;
    }

    /**
     * @dev Calculates the total amount of position's debt based on elapsed time
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @return user debt of a position plus accumulated fee
     **/
    function getTotalDebt(address asset, address user) public view returns (uint) {
        uint debt = debts[asset][user];
        if (liquidationBlock[asset][user] != 0) return debt;
        uint fee = calculateFee(asset, user, debt);
        return debt + fee;
    }

    /**
     * @dev Calculates the amount of fee based on elapsed time and repayment amount
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @param amount The repayment amount
     * @return fee amount
     **/
    function calculateFee(address asset, address user, uint amount) public view returns (uint) {
        uint sFeePercent = stabilityFee[asset][user];
        uint timePast = block.timestamp - lastUpdate[asset][user];

        return amount * sFeePercent * timePast/ (365 days) / DENOMINATOR_1E5;
    }
}
