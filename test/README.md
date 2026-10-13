# Crawlyield test coverage

The original `CrawlyieldToken.t.sol` remains intact. The additional suites are:

- `CrawlyieldToken.EdgeCases.t.sol`: zero, one minor unit, the full supply, maximum
  integers, allowance replacement/revocation/exhaustion, self-transfers, complete
  burns, and rollback of failed delegated transfers and burns.
- `CrawlyieldToken.Permit.t.sol`: independent EIP-712 domain construction, deadline
  boundaries, field tampering, malformed/malleated signatures, replay across
  nonces/spenders/contracts/chains, and preservation of existing approvals and
  nonces on failure.
- `CrawlyieldToken.Invariant.t.sol` and `handlers/CrawlyieldHandler.sol`: four actors
  randomly call transfers, approvals, delegated transfers, burns, delegated burns,
  and permits, interleaved with explicitly checked rejection paths.

The new stateless fuzz properties run 1,000 cases each. Inline invariant settings
run 256 sequences of up to 128 handler calls, with unexpected reverts treated as
failures. An explicit selector list keeps getters and test utilities out of the
campaign. A deterministic exercise also reaches every action and checks that
successful transfers, delegated spending, burning, and permits do real work.

The independent ledger starts from the brief's 1,000,000,000 × 10^18 units. It is
updated from successful operation inputs, never refreshed from the token's
reported state. After each handler call, the invariants check:

- The sum of all tracked balances equals total supply.
- Total supply plus explicitly burned units equals the original minted amount.
- Each holder's balance matches authorized movements, including self-transfers.
- Every actor/spender allowance and each permit nonce matches authorizations.
- Name, symbol, decimals, and the original mint cap remain unchanged.

The conservation equation includes burns because the accepted token exposes
`burn` and allowance-authorized `burnFrom`; the supplied launch floor permits
voluntary supply reduction. No additional minting is allowed. All successful
recipients remain in the four-actor set, so its balance sum is complete.

Run locally without writing build artifacts outside the disposable scratch area:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache FOUNDRY_FUZZ_SEED=0x5ab85d29731bc39c9c07f0e915a02385b6df8d220db6215f368a47b3c6f6eda8 forge test
```

The suites use only the project's existing dependencies. They require no RPC,
fork, environment mutation inside tests, FFI, or scratch files to compile.
