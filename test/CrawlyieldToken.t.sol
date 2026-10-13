// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {CrawlyieldToken} from "../src/CrawlyieldToken.sol";
import {DeployCrawlyieldToken} from "../script/DeployCrawlyieldToken.s.sol";

/// @notice Stands in for the launch factory: deploys the token so it is `msg.sender` of the
///         constructor, then pays the supply out the way the factory does.
contract FactoryStub {
    CrawlyieldToken public token;

    function deployToken() external {
        token = new CrawlyieldToken();
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract CrawlyieldTokenTest is Test {
    uint256 constant EXPECTED_SUPPLY = 1_000_000_000 ether;
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    CrawlyieldToken token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.prank(deployer);
        token = new CrawlyieldToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Crawlyield");
        assertEq(token.symbol(), "CRAWL");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Crawlyield");
        assertEq(token.TOKEN_SYMBOL(), "CRAWL");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyConstantMatchesBrief() public view {
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleTransferFromZero() public {
        vm.recordLogs();
        vm.prank(deployer);
        CrawlyieldToken fresh = new CrawlyieldToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event on deployment");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), deployer);
        assertEq(abi.decode(logs[0].data, (uint256)), EXPECTED_SUPPLY);
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev The launch deploys from a contract, so `msg.sender` is that contract, not an EOA.
    function test_contractDeployerReceivesSupply() public {
        FactoryStub factory = new FactoryStub();
        factory.deployToken();
        CrawlyieldToken launched = factory.token();
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY);

        // The factory then pays the supply out, and every flow arrives whole.
        uint256 swarm = EXPECTED_SUPPLY / 10;
        assertTrue(factory.send(alice, swarm));
        assertEq(launched.balanceOf(alice), swarm);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY - swarm);
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_deployScriptDeploysSameToken() public {
        DeployCrawlyieldToken deployScript = new DeployCrawlyieldToken();
        CrawlyieldToken scripted = deployScript.deploy();
        assertEq(scripted.name(), "Crawlyield");
        assertEq(scripted.symbol(), "CRAWL");
        assertEq(scripted.decimals(), 18);
        assertEq(scripted.totalSupply(), EXPECTED_SUPPLY);
        // The script contract ran the constructor, so it holds the supply.
        assertEq(scripted.balanceOf(address(deployScript)), EXPECTED_SUPPLY);
        // Runtime bytes differ only by the EIP-712 immutables (cached address and domain separator).
        assertEq(address(scripted).code.length, address(token).code.length, "script deploys different bytecode");
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 1_000 ether);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 5 ether));
        assertEq(token.balanceOf(alice), 5 ether);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        token.transfer(bob, 11 ether);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(alice, bob, 60 ether);
        assertTrue(token.approve(bob, 60 ether));
        assertEq(token.allowance(alice, bob), 60 ether);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 40 ether));
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.balanceOf(carol), 40 ether);
        assertEq(token.allowance(alice, bob), 20 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 30 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(alice, carol, 1 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 10 ether, 11 ether)
        );
        token.transferFrom(alice, carol, 11 ether);
    }

    function test_transferFromRevertsBeyondBalanceEvenWithAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5 ether, 6 ether));
        token.transferFrom(alice, carol, 6 ether);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Burning: supply can only shrink, and only by the holder's own hand
    // ---------------------------------------------------------------------------------------------

    function test_burnReducesSupplyAndBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(0), 40 ether);
        token.burn(40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY - 40 ether);
    }

    function test_burnRevertsBeyondBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    function test_burnFromUsesAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 30 ether);
        vm.prank(bob);
        token.burnFrom(alice, 30 ether);
        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY - 30 ether);
    }

    function test_burnFromRevertsWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        // Not even the deployer may burn a holder's tokens without the holder's approval.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1 ether));
        token.burnFrom(alice, 1 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged role: nothing mints, pauses, freezes, seizes or upgrades
    // ---------------------------------------------------------------------------------------------

    function test_noAdminCallIncreasesSupply() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        address[2] memory callers = [attacker, deployer];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            for (uint256 c = 0; c < callers.length; c++) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, EXPECTED_SUPPLY / 1_000);
        uint256 held = token.balanceOf(alice);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        (bool moved,) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, alice, deployer, 1));
        assertFalse(moved, "deployer moved a holder's balance without approval");
        assertEq(token.balanceOf(alice), held);

        vm.prank(alice);
        assertTrue(token.transfer(bob, held / 2));
        assertEq(token.balanceOf(bob), held / 2);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // EIP-2612 permit
    // ---------------------------------------------------------------------------------------------

    function _signPermit(uint256 key, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(key, digest);
    }

    function test_permitSetsAllowance() public {
        (address owner, uint256 key) = makeAddrAndKey("permit-owner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, bob, 123 ether, 0, deadline);

        vm.prank(carol); // anyone may relay
        token.permit(owner, bob, 123 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 123 ether);
        assertEq(token.nonces(owner), 1);
    }

    function test_permitRevertsWhenExpired() public {
        (address owner, uint256 key) = makeAddrAndKey("permit-owner");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, bob, 1 ether, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
    }

    function test_permitRevertsOnReplay() public {
        (address owner, uint256 key) = makeAddrAndKey("permit-owner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, bob, 1 ether, 0, deadline);
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
    }

    function test_permitRevertsOnWrongSigner() public {
        (address owner,) = makeAddrAndKey("permit-owner");
        (, uint256 otherKey) = makeAddrAndKey("someone-else");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(otherKey, owner, bob, 1 ether, 0, deadline);
        vm.expectRevert();
        token.permit(owner, bob, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation of supply across transfers and burns
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferRevertsAboveBalance(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, EXPECTED_SUPPLY - 1);
        amount = bound(amount, funded + 1, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, funded);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, amount));
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(bob, allowed);
        vm.prank(bob);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, amount)
            );
            token.transferFrom(deployer, carol, amount);
        } else {
            assertTrue(token.transferFrom(deployer, carol, amount));
            assertEq(token.balanceOf(carol), amount);
            assertEq(token.allowance(deployer, bob), allowed - amount);
        }
    }

    function testFuzz_burnOnlyShrinksSupply(uint256 funded, uint256 burned) public {
        funded = bound(funded, 0, EXPECTED_SUPPLY);
        burned = bound(burned, 0, funded);
        vm.prank(deployer);
        token.transfer(alice, funded);
        vm.prank(alice);
        token.burn(burned);
        assertEq(token.balanceOf(alice), funded - burned);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY - burned);
        assertLe(token.totalSupply(), EXPECTED_SUPPLY);
    }
}
