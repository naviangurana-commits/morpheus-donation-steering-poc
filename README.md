# Morpheus DistributorV2 — Donation-Steered Emission (Net-Profit PoC)

Fork PoC for a Morpheus bug bounty submission (terms v2, mor.org/bug-bounty).

**Bug:** `DistributorV2.distributeRewards` measures each deposit pool's yield as the
raw growth of the pool's measured asset balance at the Distributor (the aToken for
AAVE pools, the token itself for NONE pools) since `lastUnderlyingBalance`, and
splits the period's fixed MOR emission pro-rata to those "yields". A plain transfer
of the measured asset to the Distributor is indistinguishable from organic yield.
A dominant staker of a small pool can donate the measured asset just before a
distribution and capture a matching share of the emission. The donation is swept
to protocol-owned liquidity, so it is a real cost — this PoC proves the captured
MOR exceeds that cost at every tested size.

**Result at fork block 26,273,884** (USDT pool `0x3B51989212BEdaB926794D6bf8e9E991218cf116`,
attacker ≈90% staker; MOR/USD $0.8880, CoinGecko 2026-10-25):

| Window | Donation | Attacker MOR (control → attack) | Gain | Net |
|---|---|---|---|---|
| 7 days | $250 | 883.49 → 5,298.38 | 4,414.89 MOR | **+$3,670** |
| 7 days | $1,000 | 883.49 → 9,599.37 | 8,715.88 MOR | **≈ +$6,740** |
| 30 days | $4,000 | 3,777.39 → 40,197.60 | 36,420.20 MOR | **+$28,341** |

(Full 3×3 window × donation matrix is printed by the test run; every cell is
net-positive. The attack is permissionless and repeatable every distribution
period — `minRewardsDistributePeriod` is 1 day.)

## Run it

Requires [Foundry](https://book.getfoundry.sh/) and a mainnet RPC URL
(archive access not required at the shipped pin's age; re-pin `FORK_BLOCK`
to a recent block if your RPC prunes state).

```bash
export MAINNET_RPC_URL="https://ethereum-rpc.publicnode.com"   # or your own RPC
forge test -vvv
```

Expected: 2 tests pass — `test_T0_PoolProbe` (verifies the Distributor proxy
implementation `0x52f76e8be3dFABcC3b0DEd02882A22BE47DADE03` and inventories all
index-0 pools) and `test_T2_SteeringEconomics` (the A/B matrix above, ending in
the verdict asserts: pool emission share moved, and best net > 0).

The shipped test file has `FORK_BLOCK = 26_273_884` and
`TARGET_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116` (the USDT pool,
smallest index-0 pool by TVL at the pin) already set.

## Harness notes (what is and isn't simulated)

- The only impersonated address is the attacker account the test creates.
  `deal()` funds it with the stake + donation capital — that capital is a
  stated precondition and cost of the attack, not a protocol gift. No protocol
  account (owner, multisig, keepers) is ever impersonated, and no protocol
  contract is mocked, etched, or storage-written.
- Time warps make Chainlink answers stale; the harness re-publishes each
  external aggregator's **own pin-block answer** with a fresh timestamp
  (`_freshenFeeds`). Prices are never invented.
- Each matrix cell runs from an identical snapshot: control distribution vs
  donation distribution, so the donation is the only difference.
- AAVE-strategy donation path is the real one available to any attacker:
  supply the underlying to Aave, transfer the received aTokens to the
  Distributor.

## Dedup note

The Code4rena QA report (item [01]) qualitatively noted that unexpected
transfers of a yield asset could be counted as yield. It did not demonstrate
an execution, did not show the captured emission can exceed the donation
despite the sweep of donations to protocol-owned liquidity, and quantified no
loss. This PoC's contribution is the fork-verified, net-profit economics
against the deployed contracts.
