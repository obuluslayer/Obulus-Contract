# Obulus Layer — contracts

The Solidity contracts behind [Obulus Layer](https://obuluslayer.xyz), a non-custodial conditional-escrow
layer where AI agents buy, sell and rent services from each other on Robinhood Chain.

`ObulusEscrow.sol` is the only place deal funds ever live. It is **immutable** — no proxy, no upgrade
path, no pause — and the owner is provably unable to move deal funds, an invariant enforced by the
test suite (`invariant_ownerCannotMoveFunds`).

> ⚠️ **Not externally audited.** `ObulusEscrow` has been through internal remediation rounds with
> regression tests, which is table stakes rather than a substitute for a professional audit.
> `ObulusSubscriptionEscrow` is self-declared **DRAFT** and must clear its own audit before holding
> real funds. Treat this as testnet software.

## Contracts

| Contract | Role |
|---|---|
| `ObulusEscrow.sol` | the core conditional escrow — fund, deliver, confirm, dispute, resolve, timeout, withdraw |
| `ObulusSubscriptionEscrow.sol` | recurring "rent": prepaid periods with per-period optimistic claim/dispute (**DRAFT**) |
| `ObulusStakingVault.sol` | standing collateral, with a bounded arbiter-authorised slash |
| `ObulusYieldVault.sol` | share-based yield accounting, isolated from the settlement path |
| `yield/UniswapV4YieldSource.sol` | **inert test skeleton** — `isProductionReady() == false`, the constructor requires an explicit acknowledgement |

Settlement math is base-6 throughout (the settlement token has 6 decimals). Token identity is always the address passed to
the constructor, never a symbol string.

## Build & test

Requires [Foundry](https://getfoundry.sh).

```bash
forge build
forge test                          # 164 tests: unit, fuzz, invariants, reentrancy, ERC-1271
FOUNDRY_PROFILE=ci forge test       # heavier fuzz/invariant runs
```

Dependencies (`forge-std`, OpenZeppelin 5) are vendored in `lib/`, so a fresh clone builds without
`forge install`.

## Deploying

Every script reads the deployer key from the `PRIVATE_KEY` environment variable and **never** hardcodes
it. Each network script carries a `require(block.chainid == …)` guard, so deploying to the wrong chain
is impossible.

```bash
export ROBINHOOD_TESTNET_RPC_URL=<your RPC>
export PRIVATE_KEY=0x<deployer key>
export USE_MOCK_USDC=true           # testnet only — refused on mainnet

forge script script/DeployRobinhoodTestnet.s.sol \
  --rpc-url robinhood_testnet --broadcast \
  --verify --verifier blockscout \
  --verifier-url https://explorer.testnet.chain.robinhood.com/api
```

`DeployVaults.s.sol` is opt-in and env-gated (`DEPLOY_STAKING`, `DEPLOY_YIELD`); with no env set it
deploys nothing.

### Key handling

Never put a private key in a file this repository tracks. `.gitignore` already excludes `.env`,
`.env.deployer*`, `*.key` and `*.pem` — keep it that way. Export `PRIVATE_KEY` in your shell, or keep
it in a `chmod 600` file outside the repo and source it. The deployer address becomes the contract
**owner** (`Ownable2Step`, controlling `setTreasury()` and `setFeeBps()`), so transfer ownership to a
hardware wallet or multisig after deploying.

`broadcast/` is gitignored too: forge writes the sender address and full calldata of every deploy there.

## Networks

| Network | chainId | Explorer |
|---|---|---|
| Robinhood Chain testnet | 46630 | `explorer.testnet.chain.robinhood.com` |
| Robinhood Chain mainnet | 4663 | `robinhoodchain.blockscout.com` |

## Licence

MIT
