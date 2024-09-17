// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

/**
 * @title DSCEngine
 * @author Juan Pedro Ventura
 *
 * @dev The system is designed to be as minimal as possible. and have the tokens maintain a 1 token == $1 peg.
 * @dev This stablecoin has the properties:
 *          - Exogenous Collateral
 *          - Dollar Pegged
 *          - Algoritmically Stable
 *
 *
 * @notice Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all DSC.
 *
 * @notice It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
contract DSCEngine is ReentrancyGuard {

    ////////////////////////
    //////   Errors   //////
    ////////////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPricedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////////
    //////   Types   //////
    ///////////////////////
    using OracleLib for AggregatorV3Interface;

    //////////////////////////////
    ////   State Variables   /////
    //////////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus

    uint256 private constant MIN_HEALTH_FACTOR = 1e18;


    //Example   ETH TOKEN ADDRESS      ETH PRICE FEED 
    mapping(address token => address priceFeed) s_priceFeeds; // tokenToPriceFeed

    //Example     [0x123456] => [ETH TOKEN ADDRESS => $20][BTC TOKEN ADDRESS => $430]          
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    mapping (address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////
    //////   Events   //////
    ////////////////////////


    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event collateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo ,address indexed token, uint256 amount);

    ////////////////////////
    ////   Modifiers   /////
    ////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////////
    ////   Functions   /////
    ////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPricedAddressesMustBeSameLength();
        }

        // For example ETH / USD, BTC / USD, MKR / USD, etc

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////////
    /////  External Functions  /////
    ////////////////////////////////


    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stable coin to mint
     * 
     * @notice This function will deposit your collateral and mint DSC in one transactions
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
        ) external {
            depositCollateral(tokenCollateralAddress, amountCollateral);
            mintDsc(amountDscToMint);
        }

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit collateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success)  {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress  The collateral address to redeem
     * @param amountCollateral The amount collateral to redeem
     * @param amountDscToBurn  The amount of DSC to burn
     * 
     * @notice This function burns DSC and redeems underlying collateral in one transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
            burnDsc(amountDscToBurn);
            redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) 
        public
        moreThanZero(amountCollateral)
        nonReentrant 
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);

    }

    /**
     * @param amountDscToMint The amount of decentralized stable coin to mint
     * @notice They must have more collateral value tan the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public  moreThanZero(amount){
        _burnDsc(amount, msg.sender, msg.sender);
    }

    // If we do starte nearing undercollateralization, we need someone to liquidate positions

    // $100 ETH baking $50 DSC
    // $20 ETH back $50 DSC <- DSC isn't worth $1!!!

    // $75 backing $50 DSC
    // Liquidator take $75 baking and burns off the $50 DSC

    // If someone is almost undercollateralized, we will pay you to liquidate them!

    /**
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor should be bellow MIN_HEALTH_FACTOR
     * @param debtToCover  The amount of DSC you want to burn to imporve the users health factor
     * 
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the user funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice a known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * 
     * Follows CEI: Chekcs, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover) 
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check health facotr of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert  DSCEngine__HealthFactorOk();
        }

        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC. 
        // debtToCover: $100
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amount into a treasury

        // 0.05 ETH * 0.1 = 0.005. GETTING 0.055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem,user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
    
        uint256 endingUserHelthFactor = _healthFactor(user);
        if(endingUserHelthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
        
    }

    // Threshold to let's say 150%, so if you have $50 DSC, you must have minimun $75 ETH as collateral.
    // $100 ETH collateral -> $74
    // $50 DSC
    // UNDERCOLLATERALIZED!!!

    // I'll pay back the $50 DSC -> Get all yout collateral!
    // get $74 ETH paying $50 DSC, this person gets $24.

    // Hey, if someone pays back your minted DSC, they can have all your collateral for a discount.

    function getHealthFactor(address _user) external view returns(uint256){
        return _healthFactor(_user);
    }


    ///////////////////////////////////////////////
    /////  Private & Internal View Functions  /////
    ///////////////////////////////////////////////

    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken
     */

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
         s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)  private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        _revertIfHealthFactorIsBroken(from);
        emit collateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    } 

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) internal view  returns(uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if(totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;

        // 500 * 50 = 25000
        // 25000 / 100 = 250
        // 250 * 1e18 = 250000000000000000000
        // 250000000000000000000 / 50

    }

    // 1. Check healt factor (do they have enough collateral?)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    } 

    //////////////////////////////////////////////
    /////  Public & External View Functions  /////
    //////////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        // price of ETH (token)
        // $/ETH ETH ??
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , ,) = priceFeed.stalePriceCheck();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValueInUsd(address user) public view returns(uint256 totalCollateralValueInUsd){
        for(uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price, , ,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from CL will be 1000 * 1e8
        return  ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; 
    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns(address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns(uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

}
