Hello, i'm having a problem with the invariant testing, in the defi stable coin section.

When i add the RedeemCollateral function to the handler, it throw this error:

```
[FAIL: invariant_protocolMustHaveMoreValueThanTotalSupply persisted failure revert]
        [Sequence]
                sender=0x00000000000000003e5EfBc2839d13EdCF37C80E addr=[test/fuzz/Handler.t.sol:Handler]0x2e234DAe75C793f67A35089C9d99245E1C58470b calldata=depositCollateral(uint256,uint256) args=[618, 3256]
                sender=0x00000000000000003e5EfBc2839d13EdCF37C80E addr=[test/fuzz/Handler.t.sol:Handler]0x2e234DAe75C793f67A35089C9d99245E1C58470b calldata=redeemCollateral(uint256,uint256) args=[18072799875088069475538553471701580419786045429712979551014427359544886348679 [1.807e76], 3137]
```

This is the code of the handler:

```
// SPDX-License-Identifier: MIT
// Handler is going to narrow down the eay we call function

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";





contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc){
        dsce = _dsce;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    // redeem collateral <-

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral,1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }


    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) {
            return;
        }
        vm.prank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock) {
        collateralSeed = bound(collateralSeed,1, MAX_DEPOSIT_SIZE);
        if (collateralSeed % 2 == 0){
            return weth;
        }
        return wbtc;
    }
}
```

and here the invariant test: 

```
    function invariant_protocolMustHaveMoreValueThanTotalSupply() public {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWethDeposited);

        console.log("weth value: ", wethValue);
        console.log("wbtc value: ", wbtcValue);
        console.log("total supply: ", totalSupply);

        assert (wethValue + wbtcValue >= totalSupply);
    }
```