// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";



contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 3 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL_TO_REDEEM =  1 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT_TO_BREAK_HEALTH_FACTOR = 15 ether;


    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, , ) = config.activeNetworkConfig();
        
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }


    
    ///////////////////////////
    //// Constructor Tests ////
    ///////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesentMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPricedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }


    /////////////////////
    //// Price Tests ////
    /////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 30000e18;
        uint256 expectedEth = 15e18;
        uint256 actualEth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedEth, actualEth);
    }

    /////////////////////////////////
    //// depositCollateral Tests ////
    /////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public{
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, STARTING_ERC20_BALANCE);

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);

        vm.stopPrank();

    } 

    modifier depositedCollateral() {
         vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(totalDscMinted , expectedTotalDscMinted);
        assertEq(collateralValueInUsd,expectedCollateralValueInUsd);
    }


    /////////////////////////////////
    ////////  mintDsc Tests  ////////
    /////////////////////////////////

    modifier dscMinted()  {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);

        _;
    }

    function testCanMintDscAndUpdatesUserBalance() public dscMinted {
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);


        assertEq(totalDscMinted , AMOUNT_DSC_TO_MINT);
    }

    //////////////////////////////////
    ////////  Burn Dsc Tests  ////////
    //////////////////////////////////


    function testCanBurnDscAndUpdatesUserBalance() public dscMinted {
        vm.startPrank(USER);    
            dsc.approve(address(dsce), AMOUNT_COLLATERAL);
            dsce.burnDsc(AMOUNT_DSC_TO_MINT);
         vm.stopPrank();

        (uint256 totalDscMintedAfter,) = dsce.getAccountInformation(USER);

        assertEq(totalDscMintedAfter, 0);
    }


    ///////////////////////////////////////////
    ////////  Redeem collateral Tests  ////////
    ///////////////////////////////////////////

    function testRedeemCollateralFailsIfItsBreaksHealthFactor() public dscMinted{
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);

    }

    function testCollateralIsRedemeed() public dscMinted {
        (, uint256 collateralDepositedBefore) = dsce.getAccountInformation(USER);

        console.log("Collateral deposited Before: ", collateralDepositedBefore);


        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL_TO_REDEEM);

        (, uint256 collateralDepositedAfter) = dsce.getAccountInformation(USER);


        console.log("Collateral deposited After: ", collateralDepositedAfter);

        assert(collateralDepositedBefore - 2000e18 == collateralDepositedAfter);

    }

    function testRedeemCollateralForDsc() public dscMinted {

        (uint256 dscMintedBefore, uint256 collateralDepositedBefore) = dsce.getAccountInformation(USER);

        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_DSC_TO_MINT);

        dsce.redeemCollateralForDsc(weth,AMOUNT_COLLATERAL, AMOUNT_DSC_TO_MINT);
        vm.stopPrank();

        (uint256 dscMintedAfter, uint256 collateralDepositedAfter) = dsce.getAccountInformation(USER);

        console.log("Dsc minted after",dscMintedAfter);
        console.log("Collateral deposited after",collateralDepositedAfter);

        console.log("Dsc minted Before",dscMintedBefore);
        console.log("Collateral deposited Before",collateralDepositedBefore);

        assert(collateralDepositedAfter == 0);
        assert(dscMintedAfter == 0);


    }

    function testLiquidationRevertIfHealthFactorIsOk() public dscMinted{
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_DSC_TO_MINT);
    } 

    function testLiquidateRedeeemsCollateralAndBurnDsc() public {

        uint256 healthFactor1 = dsce.getHealthFactor(USER);
        console.log("Health factor: ", healthFactor1);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(AMOUNT_DSC_TO_MINT_TO_BREAK_HEALTH_FACTOR + 100 ether);
        vm.stopPrank();

        uint256 healthFactor2 = dsce.getHealthFactor(USER);
        console.log("Health factor: ", healthFactor2);

        

        dsce.liquidate(weth, USER, 40 ether);

        uint256 healthFactor3 = dsce.getHealthFactor(USER);
        console.log("Health factor: ", healthFactor3);

    }


}