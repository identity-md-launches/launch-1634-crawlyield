// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CrawlyieldToken} from "src/CrawlyieldToken.sol";
import {CrawlyieldHandler} from "test/handlers/CrawlyieldHandler.sol";

/// @notice Random sequences cover all six public state-changing token functions and their failures.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract CrawlyieldTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    CrawlyieldHandler internal handler;
    CrawlyieldToken internal token;

    function setUp() public {
        handler = new CrawlyieldHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.burnFrom.selector;
        selectors[5] = handler.permit.selector;
        selectors[6] = handler.permitThenRejectReplay.selector;
        selectors[7] = handler.rejectOverBalance.selector;
        selectors[8] = handler.rejectDelegatedOverspend.selector;
        selectors[9] = handler.rejectZeroRecipient.selector;
        selectors[10] = handler.rejectZeroSpender.selector;
        selectors[11] = handler.rejectWrongSigner.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Conservation: supply is exactly tracked balances; burns account for every lost unit.
    function invariant_supplyEqualsBalancesAndOnlyExplicitBurnsReduceIt() public view {
        uint256 balances;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            balances += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), balances, "tokens escaped the closed actor set");
        assertEq(token.totalSupply() + handler.burned(), INITIAL_SUPPLY, "unaccounted mint or burn");
        assertEq(handler.burned(), handler.directlyBurned() + handler.delegatedBurned());
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// @dev Checking each actor detects theft or misdirected transfers that preserve total supply.
    function invariant_eachBalanceMatchesAuthorizedMovements() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "holder balance drift");
        }
    }

    /// @dev Rejections must not consume approvals/nonces; unrelated spenders remain unaffected.
    function invariant_allowancesAndNoncesMatchAuthorizations() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address owner = handler.actors(i);
            assertEq(token.nonces(owner), handler.expectedNonce(owner), "permit nonce drift");
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < handler.ACTOR_COUNT(); ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender), "allowance drift");
            }
        }
    }

    function invariant_metadataAndMintCapRemainUnchanged() public view {
        assertEq(token.name(), "Crawlyield");
        assertEq(token.symbol(), "CRAWL");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), INITIAL_SUPPLY);
    }

    /// @dev Guarantees every handler can execute, including positive delegated movements and burns.
    ///      This does not depend on randomly choosing a particular action in a campaign.
    function test_handlerExercisesEveryActionWithMeaningfulStateChanges() public {
        handler.transfer(0, 1, 17);
        handler.approve(1, 2, 19);
        handler.transferFrom(1, 2, 3, 17);
        handler.burn(3, 17);
        handler.burnFrom(1, 2, 17);
        handler.permit(2, 3, 19);
        handler.permitThenRejectReplay(2, 0, 19);
        handler.rejectOverBalance(0, 1, type(uint256).max, false);
        handler.rejectOverBalance(0, 1, type(uint256).max, true);
        handler.rejectDelegatedOverspend(1, 2, 3, false);
        handler.rejectDelegatedOverspend(1, 2, 3, true);
        handler.rejectZeroRecipient(2, 3, 17, false);
        handler.rejectZeroRecipient(2, 3, 17, true);
        handler.rejectZeroSpender(0, 19);
        handler.rejectWrongSigner(2, 3, 19);

        assertGt(handler.transferred(), 0);
        assertGt(handler.delegatedTransferred(), 0);
        assertGt(handler.directlyBurned(), 0);
        assertGt(handler.delegatedBurned(), 0);
        assertEq(handler.permits(), 2);
        assertEq(handler.rejectedCalls(), 9);
        invariant_supplyEqualsBalancesAndOnlyExplicitBurnsReduceIt();
        invariant_eachBalanceMatchesAuthorizedMovements();
        invariant_allowancesAndNoncesMatchAuthorizations();
        invariant_metadataAndMintCapRemainUnchanged();
    }
}
