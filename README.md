# Crawlyield (CRAWL)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Field | Value |
| --- | --- |
| Solidity contract | `CrawlyieldToken` (`src/CrawlyieldToken.sol`) |
| `name()` | `Crawlyield` |
| `symbol()` | `CRAWL` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18 minor units) |
| Constructor arguments | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, EVM `cancun` |

## Behaviour

- **Minted once, to the deployer.** The constructor mints the whole supply to `msg.sender` and
  nothing else. There is no `mint` function, no minter role and no owner: the supply can never grow.
- **Plain transfers.** No fee, tax, reflection or burn on transfer. `transfer` and `transferFrom`
  move exactly the amount given, so the launch flows (factory → distributor, distributor → claimant,
  factory → pool seed, trader ↔ pool) arrive whole.
- **No privileged hand.** No pause, blacklist, freeze, lock, seize or upgrade. Nobody but a holder,
  or a spender the holder approved, can move or lock a holder's balance. The runtime contains no
  `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.
- **Holder-only burning.** `burn(amount)` burns the caller's own tokens; `burnFrom(account, amount)`
  burns from an account that approved the caller. Total supply can only shrink.
- **EIP-2612 `permit`.** Gasless approvals through signed typed data (OpenZeppelin `ERC20Permit`).
- **No ether.** The token has no `receive`/`fallback`, so plain ether sends revert.

The constructor makes no external calls and does not require any address to have code, so it
deploys on an empty chain.

## Deployment parameters

The constructor takes **no arguments**. Everything is a named constant in `src/CrawlyieldToken.sol`:

| Constant | Value |
| --- | --- |
| `TOKEN_NAME` | `"Crawlyield"` |
| `TOKEN_SYMBOL` | `"CRAWL"` |
| `DECIMALS` | `18` |
| `TOTAL_SUPPLY` | `1_000_000_000 * 10 ** 18` |

The brief left no number open, so nothing was chosen by the builder.

### IdentityMD launch (how this token is actually deployed)

The launch is performed by IdentityMD's deployer through `ProjectFactory.launchCustom`, not by this
repository. The factory runs the constructor, so **the factory is the deployer and receives the whole
supply**, then pays it out:

- 10% to the launch's MerkleDistributor (the swarm's share);
- 88% (`economics.poolBps = 8800`) seeds the single-sided Uniswap v4 pool paired with IMD
  (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee 12500 (1.25%), tick spacing 60, opening at the
  price derived from `economics.initialMarketCapWei = 2500 IMD` for the whole supply;
- the remaining 2% to `economics.remainderTo = 0x0f44a55663e888bb63618a0c31b68cbc6c01aa71`.

The token exempts nothing because it taxes nothing: every one of those flows moves exactly what it
says. No application contracts are deployed alongside the token. `launch.json` is written by the
manifest step after acceptance; it is deliberately absent from this repository.

### Stand-alone deployment (outside IdentityMD)

`script/DeployCrawlyieldToken.s.sol` exposes `deploy()`, which the tests call directly, and `run()`,
which wraps it in a broadcast. Whoever broadcasts `run()` receives the supply:

```sh
forge script script/DeployCrawlyieldToken.s.sol --rpc-url <rpc> --broadcast
```

This repository does not hold keys and does not broadcast anything on its own.

## After launch

There is nothing to configure: the token has no owner, no setters and no outside dependencies.

## Operational responsibilities

- **The deployer holds everything at first.** On an IdentityMD launch that is the factory, which
  distributes the supply in the same transaction. On a stand-alone deployment, the broadcasting
  wallet holds 100% of CRAWL and is responsible for its custody and distribution.
- **No recovery powers.** Because there is no admin, tokens sent to a wrong address, to the token
  contract itself, or burned cannot be recovered by anyone. Holders are solely responsible for their
  own balances and approvals.
- **Approvals.** Infinite approvals (`type(uint256).max`) are never decremented; holders should
  approve only what they intend to spend, and revoke approvals they no longer need.
- **Permit relays.** A signed `permit` can be submitted by anyone until its deadline; signers should
  use short deadlines.
- **Explorer verification** of the deployed bytecode is the launch deployer's task
  (`forge verify-contract`, with the pinned settings above).

## Assumptions

- The supply is exactly one billion tokens with 18 decimals and never changes upward; burns are
  allowed and reduce it.
- "The deployer" means the account that runs the constructor (`msg.sender`), as the brief says. On
  an IdentityMD launch that is the ProjectFactory; the token does not and must not name a wallet.
- The launch's chain, pool pairing, fee, tick spacing, opening price and economics are fixed by the
  launch policy and are not represented in the token's code.
- Tests passing does not constitute a security audit. The contract is a thin composition of
  OpenZeppelin v5.0.2 `ERC20`, `ERC20Burnable` and `ERC20Permit`, vendored unchanged under
  `lib/openzeppelin-contracts/` (MIT). An independent adversarial review before release is still
  recommended, as it is for any launch.

## Layout

```
foundry.toml                      compiler pins and build settings
remappings.txt                    forge-std and @openzeppelin/contracts remappings
src/CrawlyieldToken.sol           the token
script/DeployCrawlyieldToken.s.sol stand-alone deploy script
test/CrawlyieldToken.t.sol        unit and fuzz tests
lib/forge-std/                    forge-std 1.9.7 (vendored, MIT/Apache-2.0)
lib/openzeppelin-contracts/       the OpenZeppelin v5.0.2 files the token uses (vendored, MIT)
```

## Build and test

```sh
forge build
forge test
forge fmt --check
```

The test suite covers: metadata and supply; the one-time mint to the deployer (EOA and contract
deployer, plus the deploy script); exact transfers and all ERC-20 failure cases (insufficient balance,
insufficient allowance, zero-address receiver/spender); burning and `burnFrom` without approval;
the absence of mint, pause, blacklist, freeze, seize and upgrade entry points (tried from both a
stranger and the deployer); EIP-2612 permit success, expiry, replay and wrong signer; opcode scan of
the runtime for `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`; and fuzzed conservation of supply across
transfers, `transferFrom` and burns. Tests read no environment variables and pass in any order.

Tools run on this task: `forge build`, `forge test` (with the verifier's fuzz seed) and
`forge fmt`. Slither and Mythril were not available and did not run.
