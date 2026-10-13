// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CrawlyieldToken} from "src/CrawlyieldToken.sol";

/// @notice Boundary and atomicity checks supplementing the original deployment/launch tests.
/// forge-config: default.fuzz.runs = 1000
contract CrawlyieldTokenEdgeCasesTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    CrawlyieldToken internal token;
    address internal alice = makeAddr("edge-alice");
    address internal bob = makeAddr("edge-bob");
    address internal carol = makeAddr("edge-carol");

    function setUp() public {
        token = new CrawlyieldToken();
    }

    function test_oneWeiAndWholeSupplyRoundTrips() public {
        _roundTrip(1);
        _roundTrip(INITIAL_SUPPLY);
    }

    function test_zeroOperationsFromEmptyHolderEmitEventsAndPreserveSupply() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));

        // Zero delegated operations need no positive allowance, even for an empty holder.
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, carol, 0);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, address(0), 0);
        vm.prank(alice);
        token.burn(0);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, address(0), 0);
        vm.prank(bob);
        token.burnFrom(alice, 0);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_zeroRecipientRejectedEvenForZeroValue() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 0);

        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_invalidRecipientRollsBackDelegatedAllowance() public {
        token.approve(bob, 7);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 7);

        assertEq(token.allowance(address(this), bob), 7);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_approvalReplacesThenRevokesWithoutAffectingOtherSpenders() public {
        token.approve(bob, 12);
        token.approve(carol, 9);
        token.approve(bob, 4);
        assertEq(token.allowance(address(this), bob), 4);
        assertEq(token.allowance(address(this), carol), 9);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 4, 5));
        token.transferFrom(address(this), alice, 5);

        token.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.burnFrom(address(this), 1);

        assertEq(token.allowance(address(this), bob), 0);
        assertEq(token.allowance(address(this), carol), 9);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_maxUintSpendRevertsWithoutPanicOrStateChange() public {
        uint256 maximum = type(uint256).max;
        bytes memory insufficient = abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientBalance.selector, address(this), INITIAL_SUPPLY, maximum
        );
        token.approve(bob, maximum);

        vm.expectRevert(insufficient);
        token.transfer(alice, maximum);
        vm.expectRevert(insufficient);
        token.burn(maximum);
        vm.prank(bob);
        vm.expectRevert(insufficient);
        token.transferFrom(address(this), alice, maximum);
        vm.prank(bob);
        vm.expectRevert(insufficient);
        token.burnFrom(address(this), maximum);

        assertEq(token.allowance(address(this), bob), maximum);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_maxMinusOneAllowanceIsFiniteAcrossTransferAndBurn() public {
        token.approve(bob, type(uint256).max - 1);
        vm.startPrank(bob);
        assertTrue(token.transferFrom(address(this), alice, 1));
        token.burnFrom(address(this), 1);
        vm.stopPrank();

        assertEq(token.allowance(address(this), bob), type(uint256).max - 3);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 1);
    }

    function test_infiniteAllowanceSurvivesRepeatedTransfersAndBurns() public {
        token.approve(bob, type(uint256).max);
        vm.startPrank(bob);
        assertTrue(token.transferFrom(address(this), alice, 1));
        token.burnFrom(address(this), 1);
        assertTrue(token.transferFrom(address(this), alice, 1));
        token.burnFrom(address(this), 1);
        vm.stopPrank();

        assertEq(token.allowance(address(this), bob), type(uint256).max);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - 4);
        assertEq(token.balanceOf(alice), 2);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 2);
    }

    function test_spentAllowanceCannotBeUsedTwiceAcrossTransferAndBurn() public {
        token.approve(bob, 2);
        vm.startPrank(bob);
        assertTrue(token.transferFrom(address(this), alice, 1));
        token.burnFrom(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(this), alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.burnFrom(address(this), 1);
        vm.stopPrank();

        assertEq(token.allowance(address(this), bob), 0);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 1);
    }

    function test_selfTransferStillRequiresSufficientBalance() public {
        token.transfer(alice, 1);
        vm.startPrank(alice);
        token.approve(bob, 2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        token.transfer(alice, 2);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        token.transferFrom(alice, alice, 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.allowance(alice, bob), 2);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_entireSupplyCanBeBurnedOnlyOnce() public {
        token.burn(INITIAL_SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);

        token.burn(0);
        assertTrue(token.transfer(alice, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.burn(1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(alice, 1);
        assertEq(token.totalSupply(), 0);
    }

    function test_delegatedFullBurnExhaustsSupplyAndAllowance() public {
        token.approve(bob, INITIAL_SUPPLY);
        vm.prank(bob);
        token.burnFrom(address(this), INITIAL_SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), bob), 0);
    }

    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        _roundTrip(bound(amount, 0, INITIAL_SUPPLY));
    }

    function testFuzz_failedBalanceCheckRestoresDelegatedAllowance(
        uint256 funded,
        uint256 amount,
        bool infinite,
        bool burn
    ) public {
        funded = bound(funded, 0, INITIAL_SUPPLY);
        amount = bound(amount, funded + 1, type(uint256).max);
        uint256 approved = infinite ? type(uint256).max : amount;
        token.transfer(alice, funded);
        vm.prank(alice);
        token.approve(bob, approved);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, amount));
        if (burn) token.burnFrom(alice, amount);
        else token.transferFrom(alice, carol, amount);

        assertEq(token.allowance(alice, bob), approved, "failed spend consumed approval");
        assertEq(token.balanceOf(alice), funded);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - funded);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testFuzz_failedAllowanceCheckPreservesAllState(uint256 funded, uint256 approved, bool burn) public {
        funded = bound(funded, 1, INITIAL_SUPPLY);
        approved = bound(approved, 0, funded - 1);
        token.transfer(alice, funded);
        vm.prank(alice);
        token.approve(bob, approved);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, approved, approved + 1)
        );
        if (burn) token.burnFrom(alice, approved + 1);
        else token.transferFrom(alice, carol, approved + 1);

        assertEq(token.allowance(alice, bob), approved);
        assertEq(token.balanceOf(alice), funded);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testFuzz_delegatedSelfTransferOnlyConsumesAllowance(uint256 amount) public {
        amount = bound(amount, 0, INITIAL_SUPPLY);
        token.approve(bob, amount);
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), address(this), amount));
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        assertEq(token.allowance(address(this), bob), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testFuzz_delegatedBurnAccountsForExactAmount(uint256 amount, bool infinite) public {
        amount = bound(amount, 0, INITIAL_SUPPLY);
        token.approve(bob, infinite ? type(uint256).max : amount);
        vm.prank(bob);
        token.burnFrom(address(this), amount);
        assertEq(token.totalSupply() + amount, INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - amount);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), bob), infinite ? type(uint256).max : 0);
    }

    function _roundTrip(uint256 amount) internal {
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(bob), amount);
        vm.prank(bob);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }
}
