// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CrawlyieldToken} from "src/CrawlyieldToken.sol";

// The vendored forge-std predates this Foundry 1.8 cheatcode. Reading through a call prevents
// Solidity from reusing a cached block.chainid value across vm.chainId in the fork-replay test.
interface VmChainIdReader {
    function getChainId() external view returns (uint256);
}

/// @notice Signatures use an independently constructed domain, never the token's reported hash.
/// forge-config: default.fuzz.runs = 1000
contract CrawlyieldTokenPermitTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant EXISTING_APPROVAL = 7 ether;
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    CrawlyieldToken internal token;
    address internal owner;
    uint256 internal ownerKey;
    address internal spender = makeAddr("permit-spender");
    address internal relayer = makeAddr("permit-relayer");

    function setUp() public {
        (owner, ownerKey) = makeAddrAndKey("permit-boundary-owner");
        token = new CrawlyieldToken();
        token.transfer(owner, INITIAL_SUPPLY);
        vm.prank(owner);
        token.approve(spender, EXISTING_APPROVAL);
    }

    function test_domainMatchesNameVersionChainAndTokenAddress() public view {
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), _currentChainId()));
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        assertEq(fields, bytes1(0x0f));
        assertEq(name, "Crawlyield");
        assertEq(version, "1");
        assertEq(chainId, _currentChainId());
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function test_signatureValidAtExactDeadline() public {
        uint256 deadline = vm.getBlockTimestamp() + 100;
        Signature memory signature = _sign(spender, 1, 0, deadline);
        vm.warp(deadline);
        _submit(spender, 1, deadline, signature);
        assertEq(token.allowance(owner, spender), 1);
        assertEq(token.nonces(owner), 1);
    }

    function test_expiredSignaturePreservesNonceAndExistingAllowance() public {
        uint256 deadline = vm.getBlockTimestamp() + 100;
        Signature memory signature = _sign(spender, 1, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        _submit(spender, 1, deadline, signature);
        _assertUnchanged();
    }

    function test_zeroValuePermitRevokesAllowance() public {
        uint256 deadline = type(uint256).max;
        _submit(spender, 0, deadline, _sign(spender, 0, 0, deadline));
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.nonces(owner), 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(owner, relayer, 1);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY);
    }

    function test_maxValueAndDeadlinePermitSupportsTransferAndBurn() public {
        uint256 maximum = type(uint256).max;
        _submit(spender, maximum, maximum, _sign(spender, maximum, 0, maximum));
        vm.startPrank(spender);
        assertTrue(token.transferFrom(owner, relayer, 1));
        token.burnFrom(owner, 1);
        vm.stopPrank();
        assertEq(token.allowance(owner, spender), maximum);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - 2);
        assertEq(token.balanceOf(relayer), 1);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 1);
        assertEq(token.nonces(owner), 1);
    }

    function test_zeroSpenderRejectionDoesNotConsumeNonce() public {
        uint256 deadline = type(uint256).max;
        Signature memory signature = _sign(address(0), 1, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        _submit(address(0), 1, deadline, signature);
        _assertUnchanged();
        assertEq(token.allowance(owner, address(0)), 0);

        // Failure must leave nonce zero usable by a corrected authorization.
        _submit(spender, 1, deadline, _sign(spender, 1, 0, deadline));
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 1);
    }

    function test_malformedSignatureCannotAuthorizeZeroOwner() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), spender, 1, type(uint256).max, 27, bytes32(0), bytes32(0));
        assertEq(token.nonces(address(0)), 0);
        assertEq(token.allowance(address(0), spender), 0);
        _assertUnchanged();
    }

    function test_invalidVPreservesNonceAndAllowance() public {
        uint256 deadline = type(uint256).max;
        Signature memory signature = _sign(spender, 1, 0, deadline);
        signature.v = 0;
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        _submit(spender, 1, deadline, signature);
        _assertUnchanged();
    }

    function test_highSMalleatedSignatureRejectedAndOriginalRemainsUsable() public {
        uint256 deadline = type(uint256).max;
        Signature memory original = _sign(spender, 1, 0, deadline);
        bytes32 highS = bytes32(SECP256K1_ORDER - uint256(original.s));
        Signature memory malleated = Signature(original.v == 27 ? 28 : 27, original.r, highS);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        _submit(spender, 1, deadline, malleated);
        _assertUnchanged();

        _submit(spender, 1, deadline, original);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 1);
    }

    function test_successivePermitsShareOwnerNonceAcrossSpenders() public {
        uint256 deadline = type(uint256).max;
        Signature memory stale = _sign(relayer, 2, 0, deadline);
        _submit(spender, 1, deadline, _sign(spender, 1, 0, deadline));

        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(relayer, 2, deadline, stale);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, relayer), 0);

        _submit(relayer, 2, deadline, _sign(relayer, 2, 1, deadline));
        assertEq(token.nonces(owner), 2);
        assertEq(token.allowance(owner, spender), 1);
        assertEq(token.allowance(owner, relayer), 2);
    }

    function test_signatureCannotBeUsedOnAnotherToken() public {
        CrawlyieldToken other = new CrawlyieldToken();
        uint256 deadline = type(uint256).max;
        Signature memory signature = _sign(spender, 1, 0, deadline);
        assertNotEq(token.DOMAIN_SEPARATOR(), other.DOMAIN_SEPARATOR());

        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        other.permit(owner, spender, 1, deadline, signature.v, signature.r, signature.s);
        assertEq(other.nonces(owner), 0);
        assertEq(other.allowance(owner, spender), 0);
        _assertUnchanged();

        _submit(spender, 1, deadline, signature);
        assertEq(token.nonces(owner), 1);
    }

    function test_chainChangeInvalidatesOldDomainAndAcceptsNewDomain() public {
        uint256 originalChain = _currentChainId();
        uint256 newChain = originalChain ^ 1;
        uint256 deadline = type(uint256).max;
        Signature memory oldSignature = _sign(spender, 1, 0, deadline);
        bytes32 originalDomain = token.DOMAIN_SEPARATOR();

        vm.chainId(newChain);
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), newChain));
        assertNotEq(token.DOMAIN_SEPARATOR(), originalDomain);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(spender, 1, deadline, oldSignature);
        _assertUnchanged();

        _submit(spender, 1, deadline, _sign(spender, 1, 0, deadline));
        assertEq(token.nonces(owner), 1);
        vm.chainId(originalChain);
        assertEq(token.DOMAIN_SEPARATOR(), originalDomain);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(spender, 1, deadline, oldSignature);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 1);
    }

    function testFuzz_permitBindsEverySignedField(uint256 value, uint8 field) public {
        uint256 deadline = vm.getBlockTimestamp() + 100;
        field = uint8(bound(field, 0, 4));
        Signature memory signature = _sign(spender, value, field == 4 ? 1 : 0, deadline);
        address submittedOwner = field == 0 ? relayer : owner;
        address submittedSpender = field == 1 ? relayer : spender;
        uint256 submittedValue = field == 2 ? value ^ 1 : value;
        uint256 submittedDeadline = field == 3 ? deadline + 1 : deadline;

        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(
            submittedOwner, submittedSpender, submittedValue, submittedDeadline, signature.v, signature.r, signature.s
        );
        _assertUnchanged();
        assertEq(token.nonces(relayer), 0);
        assertEq(token.allowance(owner, relayer), 0);
        assertEq(token.allowance(relayer, spender), 0);
    }

    function testFuzz_validPermitChangesOnlyApprovalAndNonceAndCannotReplay(uint256 value, uint256 deadline) public {
        deadline = bound(deadline, vm.getBlockTimestamp(), type(uint256).max);
        Signature memory signature = _sign(spender, value, 0, deadline);
        vm.prank(relayer);
        _submit(spender, value, deadline, signature);
        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), 1);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(relayer), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);

        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(spender, value, deadline, signature);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), value);
    }

    function _assertUnchanged() internal view {
        assertEq(token.nonces(owner), 0, "invalid permit consumed nonce");
        assertEq(token.allowance(owner, spender), EXISTING_APPROVAL, "invalid permit changed approval");
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(relayer), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function _submit(address to, uint256 value, uint256 deadline, Signature memory signature) internal {
        token.permit(owner, to, value, deadline, signature.v, signature.r, signature.s);
    }

    function _sign(address to, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (Signature memory signature)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(address(token), _currentChainId()), structHash));
        (signature.v, signature.r, signature.s) = vm.sign(ownerKey, digest);
    }

    function _domain(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Crawlyield"), keccak256("1"), chainId, verifyingContract));
    }

    function _currentChainId() internal view returns (uint256) {
        return VmChainIdReader(address(vm)).getChainId();
    }
}
