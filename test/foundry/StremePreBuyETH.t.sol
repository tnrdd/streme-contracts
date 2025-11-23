// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    StremePreBuyETH
} from "../../contracts/postlp/prebuy/StremePreBuyETH.sol";
import {
    StremePreBuyFactory,
    IStremePreBuyETH
} from "../../contracts/postlp/prebuy/StremePreBuyFactory.sol";
import { Streme } from "../../contracts/Streme.sol";
import { StremeVault } from "../../contracts/hook/vault/StremeVault.sol";
import {
    StremeDeployV2,
    IStreme,
    IStremeAllocationHook
} from "../../contracts/extras/StremeDeployV2.sol";

contract StremePreBuyETHTest is Test {
    StremePreBuyETH preBuyImplementation;
    StremePreBuyETH preBuy;
    StremePreBuyFactory preBuyFactory;
    address preBuyTokenAddress;
    address stremeManager = vm.envAddress("STREME_MANAGER");
    address stremeAllocationHook = vm.envAddress("STREME_ALLOCATION_HOOK");
    address lpFactory = vm.envAddress("STREME_LP_FACTORY");
    address tokenFactory = vm.envAddress("STREME_SUPER_TOKEN_FACTORY");
    Streme streme = Streme(vm.envAddress("STREME"));
    StremeVault stremeVault = StremeVault(vm.envAddress("STREME_VAULT"));
    StremeDeployV2 stremeDeployV2 =
        StremeDeployV2(vm.envAddress("STREME_PUBLIC_DEPLOYER_V2"));
    IERC20 weth = IERC20(vm.envAddress("WETH"));
    address george = makeAddr("george");
    address allocationTeam = makeAddr("allocationTeam");
    address allocationComm = makeAddr("allocationComm");

    bytes32 preBuySalt;
    string preBuyTokenName = "PreBuy Token";
    string preBuyTokenSymbol = "PBT";

    uint256 constant MIN_DEPOSIT = 0.01 ether;
    uint256 constant MAX_DEPOSIT = 10 ether;
    uint256 constant TOTAL_CAP = 20 ether;

    function setUp() public {
        vm.createSelectFork({ blockNumber: 38385016, urlOrAlias: "base" });

        preBuyImplementation = new StremePreBuyETH();
        preBuyFactory = new StremePreBuyFactory(
            IStremePreBuyETH(address(preBuyImplementation))
        );
        address deployer = address(this);
        (bytes32 salt, address tokenAddress) = streme.generateSalt(
            preBuyTokenSymbol, deployer, tokenFactory, address(weth)
        );

        preBuySalt = salt;
        preBuyTokenAddress = tokenAddress;

        IStremePreBuyETH.PreBuySettings memory preBuySettings =
            IStremePreBuyETH.PreBuySettings({
                minDeposit: MIN_DEPOSIT,
                maxDeposit: MAX_DEPOSIT,
                totalCap: TOTAL_CAP,
                lockupDuration: 7 days,
                vestingDuration: 90 days
            });
        preBuy = StremePreBuyETH(
            address(
                preBuyFactory.createPreBuy(
                    preBuyTokenAddress, preBuySettings, address(this)
                )
            )
        );

        vm.deal(george, 10 ether);
    }

    function test_deployment() public view {
        assertTrue(
            address(preBuyImplementation) != address(0),
            "PrebuyImplementation address should not be the zero address"
        );
        assertTrue(
            address(preBuyFactory) != address(0),
            "PrebuyFactory address should not be the zero address"
        );
        assertTrue(
            preBuyTokenAddress != address(0),
            "Predicted token address should not be the zero address"
        );
    }

    function test_deposit(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        preBuy.deposit{ value: depositAmount }();

        uint256 balance = preBuy.deposits(address(this));

        assertEq(
            depositAmount, balance, "Balance should be equal to deposit amount"
        );
    }

    function test_deposit_multipleUsers(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        preBuy.deposit{ value: depositAmount }();

        uint256 balance = preBuy.deposits(address(this));

        assertEq(
            depositAmount, balance, "Balance should be equal to deposit amount"
        );

        vm.warp(block.timestamp + 12);
        vm.prank(george);

        preBuy.deposit{ value: depositAmount }();

        balance = preBuy.deposits(address(this));

        assertEq(
            depositAmount, balance, "Balance should be equal to deposit amount"
        );
    }

    function test_withdraw(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, MIN_DEPOSIT * 2, MAX_DEPOSIT);

        uint256 withdrawAmount = depositAmount / 2;
        uint256 expectedBalance = depositAmount - withdrawAmount;

        preBuy.deposit{ value: depositAmount }();

        vm.warp(block.timestamp + 12);

        preBuy.withdraw(withdrawAmount);

        uint256 balance = preBuy.deposits(address(this));

        assertEq(
            balance,
            expectedBalance,
            "Balance should be equal to deposit amount minus the withdrawn amount"
        );
    }

    function test_membersWithUnits(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        preBuy.deposit{ value: depositAmount }();

        (address[] memory members, uint128[] memory units) =
            preBuy.membersWithUnits();

        assertEq(members[0], address(this));
        assertEq(units[0], depositAmount);
    }

    function test_registerPostLpHook() public {
        vm.prank(stremeManager);
        streme.registerPostLPHook(address(preBuy), true);

        bool isRegistered = streme.postLPHooks(address(preBuy));

        assertTrue(isRegistered, "Post LP Hook should be registered");
    }

    function test_revert_depositBelowMin(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1 wei, MIN_DEPOSIT - 1);

        vm.expectRevert("Amount must be gte minDeposit");
        preBuy.deposit{ value: depositAmount }();
    }

    function test_revert_depositAboveMax(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, MAX_DEPOSIT + 1, 100 ether);

        vm.expectRevert("Amount must be lte maxDeposit");
        preBuy.deposit{ value: depositAmount }();
    }

    function test_revert_depositExceedsCap() public {
        preBuy.deposit{ value: MAX_DEPOSIT }();

        vm.prank(george);
        preBuy.deposit{ value: MAX_DEPOSIT }();

        vm.expectRevert("Total cap exceeded");
        preBuy.deposit{ value: MIN_DEPOSIT }();
    }

    function test_revert_depositWhenPaused() public {
        preBuy.pause();

        vm.expectRevert();
        preBuy.deposit{ value: 1 ether }();
    }

    function test_revert_withdrawZeroAmount() public {
        preBuy.deposit{ value: 1 ether }();

        vm.expectRevert("Amount must be greater than zero");
        preBuy.withdraw(0);
    }

    function test_revert_withdrawInsufficientBalance(uint256 withdrawAmount)
        public
    {
        preBuy.deposit{ value: 1 ether }();

        withdrawAmount = bound(withdrawAmount, 1 ether + 1, 100 ether);

        vm.expectRevert("Insufficient balance");
        preBuy.withdraw(withdrawAmount);
    }

    function test_revert_withdrawLeavingDust() public {
        preBuy.deposit{ value: 1 ether }();

        uint256 withdrawAmount = 1 ether - (MIN_DEPOSIT / 2);

        vm.expectRevert("Balance must be gte minDeposit or zero");
        preBuy.withdraw(withdrawAmount);
    }

    function test_revert_withdrawWhenInactive() public {
        __deployWithAllocations(MIN_DEPOSIT);

        vm.expectRevert("Pre-buy is not active");
        preBuy.withdraw(0.5 ether);
    }

    function test_deployWithAllocations(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        (address pool, address box) = __deployWithAllocations(depositAmount);

        assertTrue(
            pool != address(0), "Pool address should not be the zero address"
        );
        assertTrue(
            box != address(0), "Box address should not be the zero address"
        );

        uint256 boxBalance = IERC20(preBuyTokenAddress).balanceOf(box);

        assertGt(boxBalance, 0, "Box balance should be more than zero");
    }

    function test_claim(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        (address pool,) = __deployWithAllocations(depositAmount);

        vm.warp(block.timestamp + 14 days);

        stremeVault.claim(preBuyTokenAddress, address(preBuy));

        string memory getMemberFlowRateSig = "getMemberFlowRate(address)";
        (bool success, bytes memory data) = pool.call(
            abi.encodeWithSignature(getMemberFlowRateSig, address(this))
        );
        assertTrue(success, "getMemberFlowRate call should succeed");
        int96 flowRate = abi.decode(data, (int96));

        assertGt(
            flowRate, 0, "First depositor flow rate should be more than zero"
        );

        (success, data) =
            pool.call(abi.encodeWithSignature(getMemberFlowRateSig, george));
        assertTrue(success, "getMemberFlowRate call should succeed");
        flowRate = abi.decode(data, (int96));

        assertGt(
            flowRate, 0, "Second depositor flow rate should be more than zero"
        );
    }

    function test_claimAll(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        (address pool,) = __deployWithAllocations(depositAmount);

        vm.warp(block.timestamp + 14 days);

        stremeVault.claim(preBuyTokenAddress, address(preBuy));

        vm.warp(block.timestamp + 91 days);

        string memory claimAllSig = "claimAll(address)";
        (bool success,) =
            pool.call(abi.encodeWithSignature(claimAllSig, address(this)));
        assertTrue(success, "claimAll call should succeed");
        uint256 balance = IERC20(preBuyTokenAddress).balanceOf(address(this));

        assertGt(balance, 0, "First depositor balance should be more than zero");

        vm.prank(george);
        (success,) = pool.call(abi.encodeWithSignature(claimAllSig, george));

        assertTrue(success, "claimAll call should succeed");

        balance = IERC20(preBuyTokenAddress).balanceOf(george);

        assertGt(
            balance, 0, "Second depositor balance should be more than zero"
        );
    }

    function __deployWithAllocations(uint256 depositAmount)
        public
        returns (address pool, address box)
    {
        vm.startPrank(stremeManager);
        streme.registerPostLPHook(address(preBuy), true);
        vm.stopPrank();

        preBuy.deposit{ value: depositAmount }();

        vm.startPrank(george);
        preBuy.deposit{ value: depositAmount }();
        vm.stopPrank();

        IStreme.PoolConfig memory poolConfig = IStreme.PoolConfig({
            tick: -230400, pairedToken: address(weth), devBuyFee: 10000
        });
        IStreme.PreSaleTokenConfig memory tokenConfig =
            IStreme.PreSaleTokenConfig({
                _name: preBuyTokenName,
                _symbol: preBuyTokenSymbol,
                _supply: 1e11 ether,
                _fee: 10000,
                _salt: preBuySalt,
                _deployer: address(this),
                _fid: 8685,
                _image: "none",
                _castHash: "none",
                _poolConfig: poolConfig
            });

        (bytes32 salt, address tokenAddress) = streme.generateSalt(
            tokenConfig._symbol,
            tokenConfig._deployer,
            tokenFactory,
            address(weth)
        );

        tokenConfig._salt = salt;

        assertEq(tokenAddress, preBuyTokenAddress);

        IStremeAllocationHook.AllocationConfig[] memory allocationConfigs =
            new IStremeAllocationHook.AllocationConfig[](3);

        allocationConfigs[0] = IStremeAllocationHook.AllocationConfig({
            allocationType: IStremeAllocationHook.AllocationType.Vault,
            admin: allocationTeam,
            percentage: 20,
            data: abi.encode(30 days, 365 days)
        });
        allocationConfigs[1] = IStremeAllocationHook.AllocationConfig({
            allocationType: IStremeAllocationHook.AllocationType.Vault,
            admin: allocationComm,
            percentage: 20,
            data: abi.encode(7 days, 0)
        });
        allocationConfigs[2] = IStremeAllocationHook.AllocationConfig({
            allocationType: IStremeAllocationHook.AllocationType.Staking,
            admin: address(0),
            percentage: 5,
            data: abi.encode(1 days, 365 days)
        });

        stremeDeployV2.deployWithAllocations(
            tokenFactory,
            stremeAllocationHook,
            lpFactory,
            address(preBuy),
            tokenConfig,
            allocationConfigs
        );

        (,,,,,, pool, box) =
            stremeVault.allocation(preBuyTokenAddress, address(preBuy));
    }

    receive() external payable { }
}
