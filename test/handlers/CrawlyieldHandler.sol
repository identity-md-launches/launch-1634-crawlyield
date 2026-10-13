// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {CrawlyieldToken} from "src/CrawlyieldToken.sol";

/// @notice All recipients and spenders belong to a closed set of four actors.
/// @dev The ledger starts from the requested supply and changes only by successful call inputs.
///      It never copies balances, allowances, nonces, or supply back from the token under test.
contract CrawlyieldHandler is Test {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant ACTOR_COUNT = 4;
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    CrawlyieldToken public immutable token;
    address[4] public actors;
    uint256[4] internal actorKeys;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    mapping(address => uint256) public expectedNonce;
    uint256 public burned;

    // Activity is checked by a deterministic handler exercise, not by probabilistic requirements.
    uint256 public transferred;
    uint256 public delegatedTransferred;
    uint256 public directlyBurned;
    uint256 public delegatedBurned;
    uint256 public permits;
    uint256 public rejectedCalls;

    constructor() {
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            (actors[i], actorKeys[i]) = makeAddrAndKey(string.concat("crawl-invariant-actor-", vm.toString(i)));
        }
        vm.prank(actors[0]);
        token = new CrawlyieldToken();
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(actors[0]), INITIAL_SUPPLY);

        uint256 share = INITIAL_SUPPLY / ACTOR_COUNT;
        expectedBalance[actors[0]] = INITIAL_SUPPLY;
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            vm.prank(actors[0]);
            assertTrue(token.transfer(actors[i], share));
            expectedBalance[actors[0]] -= share;
            expectedBalance[actors[i]] = share;
        }

        // Start with some spendable approvals. Other pairs start at zero, and actions may
        // replace/revoke either kind, so delegated calls exercise both accepted and rejected paths.
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            _approve(actors[i], actors[(i + 1) % ACTOR_COUNT], share);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
        transferred += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), _approvalAmount(amountSeed));
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, _spendable(owner, spender));
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _consumeAllowance(owner, spender, amount);
        _move(owner, to, amount);
        delegatedTransferred += amount;
    }

    function burn(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        vm.prank(owner);
        token.burn(amount);
        expectedBalance[owner] -= amount;
        burned += amount;
        directlyBurned += amount;
    }

    function burnFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, _spendable(owner, spender));
        vm.prank(spender);
        token.burnFrom(owner, amount);
        _consumeAllowance(owner, spender, amount);
        expectedBalance[owner] -= amount;
        burned += amount;
        delegatedBurned += amount;
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        _permit(ownerSeed % ACTOR_COUNT, _actor(spenderSeed), _approvalAmount(amountSeed), false);
    }

    function permitThenRejectReplay(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        _permit(ownerSeed % ACTOR_COUNT, _actor(spenderSeed), _approvalAmount(amountSeed), true);
    }

    function rejectOverBalance(uint256 ownerSeed, uint256 toSeed, uint256 excessSeed, bool burnTokens) external {
        address owner = _actor(ownerSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = bound(excessSeed, balance + 1, type(uint256).max);
        address to = _actor(toSeed);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        if (burnTokens) token.burn(amount);
        else token.transfer(to, amount);
        ++rejectedCalls;
    }

    function rejectDelegatedOverspend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, bool burnTokens)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 amount;
        bytes memory reason;
        if (allowed != type(uint256).max) {
            amount = allowed + 1;
            reason = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        } else {
            amount = expectedBalance[owner] + 1;
            reason = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, owner, expectedBalance[owner], amount
            );
        }
        vm.prank(spender);
        vm.expectRevert(reason);
        if (burnTokens) token.burnFrom(owner, amount);
        else token.transferFrom(owner, to, amount);
        ++rejectedCalls;
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, delegated ? _spendable(owner, spender) : expectedBalance[owner]);
        vm.prank(delegated ? spender : owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        if (delegated) token.transferFrom(owner, address(0), amount);
        else token.transfer(address(0), amount);
        ++rejectedCalls;
    }

    function rejectZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        ++rejectedCalls;
    }

    function rejectWrongSigner(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        uint256 index = ownerSeed % ACTOR_COUNT;
        address owner = actors[index];
        address spender = _actor(spenderSeed);
        uint256 wrongIndex = (index + 1) % ACTOR_COUNT;
        bytes32 digest = _permitDigest(owner, spender, amount);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKeys[wrongIndex], digest);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, actors[wrongIndex], owner));
        token.permit(owner, spender, amount, type(uint256).max, v, r, s);
        ++rejectedCalls;
    }

    function _permit(uint256 index, address spender, uint256 amount, bool replay) internal {
        address owner = actors[index];
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKeys[index], _permitDigest(owner, spender, amount));
        token.permit(owner, spender, amount, type(uint256).max, v, r, s);
        expectedAllowance[owner][spender] = amount;
        ++expectedNonce[owner];
        ++permits;
        if (replay) {
            vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
            token.permit(owner, spender, amount, type(uint256).max, v, r, s);
            ++rejectedCalls;
        }
    }

    function _permitDigest(address owner, address spender, uint256 amount) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Crawlyield"), keccak256("1"), block.chainid, address(token))
        );
        bytes32 message =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, amount, expectedNonce[owner], type(uint256).max));
        return keccak256(abi.encodePacked("\x19\x01", domain, message));
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _consumeAllowance(address owner, address spender, uint256 amount) internal {
        if (expectedAllowance[owner][spender] != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
    }

    function _move(address from, address to, uint256 amount) internal {
        // A transfer to oneself has no balance effect, but transferFrom still spends approval.
        if (from != to) {
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
    }

    function _spendable(address owner, address spender) internal view returns (uint256) {
        uint256 balance = expectedBalance[owner];
        uint256 approved = expectedAllowance[owner][spender];
        return balance < approved ? balance : approved;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _amount(uint256 seed, uint256 maximum) internal pure returns (uint256) {
        uint256 edge = seed % 8;
        if (edge == 0) return 0;
        if (edge == 1) return maximum == 0 ? 0 : 1;
        if (edge == 2) return maximum;
        return bound(seed, 0, maximum);
    }

    function _approvalAmount(uint256 seed) internal pure returns (uint256) {
        uint256 edge = seed % 5;
        if (edge == 0) return 0;
        if (edge == 1) return type(uint256).max;
        if (edge == 2) return type(uint256).max - 1;
        if (edge == 3) return bound(seed, 0, INITIAL_SUPPLY);
        return seed;
    }
}
