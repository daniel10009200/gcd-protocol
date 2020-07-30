// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.6.6;

import "./helpers/ERC20SafeTransfer.sol";
import "./helpers/SafeMath.sol";
import "./Vault.sol";
import "./Parameters.sol";
import "./UniswapOracle.sol";
import "./Liquidator.sol";
import "./helpers/Math.sol";


contract VaultManager is Auth {
    using ERC20SafeTransfer for address;
    using SafeMath for uint;

    Vault public vault;
    OracleLike public uniswapOracle;
    Liquidator public liquidator;
    address public COL;

    /**
     * @dev Trigger when spawns are happened
    **/
    event Spawn(address indexed collateral, address indexed user, uint oracleType);

    /**
     * @dev Trigger when params updates are happened
    **/
    event Update(address indexed collateral, address indexed user);

    /**
     * @dev Trigger when params joins are happened
    **/
    event Join(address indexed collateral, address indexed user, uint main, uint col, uint usdp);

    /**
     * @dev Trigger when params exits are happened
    **/
    event Exit(address indexed collateral, address indexed user, uint main, uint col, uint usdp);

    /**
     * @dev Trigger when destroying is happened
    **/
    event Destroy(address indexed collateral, address indexed user);

    /**
     * @param _vault The address of the Vault
     * @param _liquidator The liquidator contract address
     * @param _parameters The address of the contract with system parameters
     * @param _uniswapOracle The address of Uniswap-based Oracle
     * @param _col COL token address
     **/
    constructor(address _vault, address _liquidator, address _parameters, address _uniswapOracle, address _col) Auth(_parameters) public {
        vault = Vault(_vault);
        liquidator = Liquidator(_liquidator);
        uniswapOracle = OracleLike(_uniswapOracle);
        COL = _col;
    }

    /**
      * @notice Cannot be used for already spawned positions
      * @notice Token using as main collateral must be whitelisted
      * @notice Depositing tokens must be pre-approved to vault address
      * @dev Spawns new positions
      * @dev Adds collaterals to non-spawned positions
      * @notice position actually spawns when usdpAmount > 0
      * @param token The address of token using as main collateral
      * @param mainAmount The amount of main collateral to deposit
      * @param colAmount The amount of COL token to deposit
      * @param usdpAmount The amount of USDP token to borrow
      * @param oracleType The type of an oracle. Initially, only Uniswap is possible (1)
      **/
    function spawn(address token, uint mainAmount, uint colAmount, uint usdpAmount, uint oracleType) external {
        // check whether the position is spawned
        require(vault.getDebt(token, msg.sender) == 0, "USDP: SPAWNED_POSITION");

        // USDP minting triggers the spawn of a position
        if (usdpAmount > 0) {

            // oracle availability check
            require(parameters.isOracleTypeEnabled(oracleType), "USDP: WRONG_ORACLE_TYPE");

            vault.spawn(token, msg.sender, oracleType);

            // fire an event
            emit Spawn(token, msg.sender, oracleType);
        }

        _join(token, mainAmount, colAmount, usdpAmount);
    }

    /**
     * @notice Position should be spawned (USDP minted) to call this method
     * @notice Depositing tokens must be pre-approved to vault address
     * @notice Token using as main collateral must be whitelisted
     * @dev Deposits collaterals to spawned positions
     * @dev Borrows USDP
     * @param token The address of token using as main collateral
     * @param mainAmount The amount of main collateral to deposit
     * @param colAmount The amount of COL token to deposit
     * @param usdpAmount The amount of USDP token to borrow
     **/
    function join(address token, uint mainAmount, uint colAmount, uint usdpAmount) external {

        // check the existence of a position
        require(vault.getDebt(token, msg.sender) > 0, "USDP: POSITION_DOES_NOT_EXIST");

        // USDP minting triggers the update of a position
        if (usdpAmount > 0)
            _updatePosition(token);

        _join(token, mainAmount, colAmount, usdpAmount);
    }

    function _join(address token, uint mainAmount, uint colAmount, uint usdpAmount) internal {

        // check utility of tx
        require(mainAmount.add(colAmount) > 0 || usdpAmount > 0, "USDP: USELESS_TX");


        if (usdpAmount > 0) {
            // mint USDP to user
            vault.addDebt(token, msg.sender, usdpAmount);
        }

        if (mainAmount > 0)
            vault.addMainCollateral(token, msg.sender, mainAmount);

        if (colAmount > 0)
            vault.addColToken(token, msg.sender, colAmount);

        ensureCollateralProportion(token, msg.sender);

        // fire an event
        emit Join(token, msg.sender, mainAmount, colAmount, usdpAmount);
    }

    /**
      * @notice Tx sender must have a sufficient USDP balance to pay the debt
      * @notice Token approwal is NOT needed
      * @dev Repays total debt and withdraws collaterals
      * @param token The address of token using as main collateral
      * @param mainAmount The amount of main collateral token to withdraw
      * @param colAmount The amount of COL token to withdraw
      **/
    function repayAll(address token, uint mainAmount, uint colAmount) external {
        uint usdpAmount = vault.getDebt(token, msg.sender);
        exit(token, mainAmount, colAmount, usdpAmount);
    }

    /**
      * @notice Tx sender must have a sufficient USDP balance to pay the debt
      * @dev Withdraws collateral
      * @dev Repays specified amount of debt
      * @param token The address of token using as main collateral
      * @param mainAmount The amount of main collateral token to withdraw
      * @param colAmount The amount of COL token to withdraw
      * @param usdpAmount The amount of USDP token to repay
      **/
    function exit(address token, uint mainAmount, uint colAmount, uint usdpAmount) public {
        require(mainAmount.add(colAmount) > 0 || usdpAmount > 0, "USDP: USELESS_TX");

        if (mainAmount > 0)
            // withdraws main collateral to user address
            vault.subMainCollateral(token, msg.sender, mainAmount);

        if (colAmount > 0)
            // withdraws COL tokens to user's address
            vault.subColToken(token, msg.sender, colAmount);

        if (usdpAmount > 0)
            // burns USDP from user's balance
            vault.subDebt(token, msg.sender, usdpAmount);

        // revert if the position is undercollateralized
        require(liquidator.isSafePosition(token, msg.sender), "USDP: UNDERCOLLATERALIZED_POSITION");

        if (vault.getDebt(token, msg.sender) == 0) {
            // clear unused storage
            vault.destroy(token, msg.sender);
            // fire an event
            emit Destroy(token, msg.sender);
        }
        else if (mainAmount > 0 || colAmount > 0) {
            ensureCollateralProportion(token, msg.sender);
            _updatePosition(token);
        }

        emit Exit(token, msg.sender, mainAmount, colAmount, usdpAmount);
    }


    // update position parameters to current
    function _updatePosition(address token) internal {
        vault.update(token, msg.sender);

        // fire an event
        emit Update(token, msg.sender);
    }

    function ensureCollateralProportion(address token, address user) internal {

        // COL token value of the position in USD
        uint colUsd = uniswapOracle.tokenToUsd(COL, vault.colToken(token, user));

        // main collateral value of the position in USD
        uint mainUsd = uniswapOracle.tokenToUsd(token, vault.collaterals(token, user));

        // USD limit of main collateral in position
        uint mainUsdLimit;
        if (parameters.minColPercent() == 0) {
            mainUsdLimit = mainUsd;
        } else {
            mainUsdLimit = colUsd * (100 - parameters.minColPercent()) / parameters.minColPercent();
            require(mainUsd <= mainUsdLimit, "USDP: INCORRECT_COLLATERALIZATION");
        }

        // USD limit of COL in position
        uint colUsdLimit;
        if (parameters.maxColPercent() == 100) {
            colUsdLimit = colUsd;
        } else {
            colUsdLimit = mainUsd * parameters.maxColPercent() / (100 - parameters.maxColPercent());
            require(colUsd <= colUsdLimit, "USDP: INCORRECT_COLLATERALIZATION");
        }

        // USD withdrawable limit
        uint usdLimit = colUsd.add(mainUsd).mul(parameters.initialCollateralRatio(token)).div(100);

        // Ensure collateralization & collateral partition
        require(vault.getDebt(token, user) <= usdLimit, "USDP: INCORRECT_COLLATERALIZATION");
    }
}
