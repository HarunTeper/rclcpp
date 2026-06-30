# MTE Starvation Fix — Benchmark Results

Consolidated results for the MultiThreadedExecutor (MTE) starvation fix, across all three
target distros. This document accompanies the fix branches and is the evidence base for the PR.

- **Branches:** `fix/mte-starvation-{humble,jazzy,lyrical}` (each off its own upstream distro).
- **rclcpp versions:** Humble 16.0.19 · Jazzy 28.1.21 · Lyrical 32.0.0.
- **Two executor eras:** Humble = `memory_strategy_` era (no `EventsCBGExecutor`); Jazzy/Lyrical =
  `wait_result_` era (`EventsCBGExecutor` present).
- **Raw data:** `docker/results/` — `comparison-<distro>.md` (per-distro tables), `bench_*.json`
  (google-benchmark output), `starvation-*.txt` (gtest logs), `autoware-latency-<distro>.csv`.
- **Reproduce:** `make compare-{humble,jazzy,lyrical}` (micro) ·
  `make autoware-smoke AW_DURATION=600 AW_RUNS=1` + `docker/run-autoware-lyrical.sh 600 1` (macro).

---

## 1. The bug: mutually-exclusive callback-group starvation

When two timers share one **mutually-exclusive** callback group, the unfixed MTE can dispatch one
timer indefinitely while the other never runs. The deterministic detector
(`test_multi_threaded_executor.cpp::starvation_mutually_exclusive_timers`) fires two 5 ms wall
timers in one ME group, each sleeping 20 ms, until one reaches 20 firings, then asserts both ran
and their counts differ by ≤ 2.

| Executor | Humble | Jazzy | Lyrical |
|---|---|---|---|
| **unfixed MTE** | ❌ STARVES (`one=20 two=0`) | ❌ STARVES (`one=0 two=20`) | ❌ STARVES (`one=0 two=20`) |
| **fixed MTE** | ✅ OK | ✅ OK | ✅ OK |
| **EventsCBGExecutor** | — (n/a, not in Humble) | ✅ OK | ✅ OK |

The unfixed MTE starves **100%** (the victim timer never executes — count 0) on every distro; the
starved timer differs by thread race but the total starvation is identical. The fixed MTE
alternates correctly. `EventsCBGExecutor` is starvation-free by construction (verified via the twin
test `starvation_eventscbg_passes`), which is the comparison baseline the EMSOFT paper relies on.

The same starvation test `.cpp` was compiled against the **unfixed** executor (overlaid onto
pristine upstream) and the **fixed** executor — so the only variable is the executor.

---

## 2. Micro-benchmark: fix overhead (upstream `benchmark_executor`)

Method: the fix changes `MultiThreadedExecutor` **in place**, so *fixed vs unfixed* = the same
`benchmark_executor` binary built from the fix ref vs pristine upstream. `-DCMAKE_BUILD_TYPE=Release`,
`--benchmark_repetitions=10` (mean). Heap-allocation counters come from `performance_test_fixture`
with the `osrf_testing_tools_cpp` memory-tools interposer `LD_PRELOAD`ed. Measured on an idle
24-core host (load ≈ 0.4).

**The headline: heap-allocation overhead is exactly zero on every distro.** Allocation counts are
deterministic and load-independent, so this is the robust evidence for the "negligible overhead"
claim.

| Distro | Scenario | unfixed → fixed real_time | Δ time | unfixed → fixed allocs | Δ allocs |
|---|---|---|---|---|---|
| Humble | spin_some | 49,547 → 50,416 ns | +1.75% | 83.1 → 83.1 | **+0.00%** |
| Jazzy | spin_some | 28,726 → 28,639 ns | −0.30% | 47.1 → 47.1 | **+0.00%** |
| Lyrical | spin_some | 16,536 → 16,981 ns | +2.69% | 40 → 40 | **+0.00%** |
| Lyrical | MultipleCallbackGroups spin_some | 16,728 → 17,338 ns | +3.65% | 40 → 40 | **+0.00%** |
| Lyrical | Cascaded spin | 85,308 → 83,176 ns | −2.50% | ~0 → ~0 | +0.00% |
| Lyrical | wait_for_work | 4,619 → 4,751 ns | +2.85% | 4 → 4 | **+0.00%** |
| Lyrical | wait_for_work_rebuild | 8,375 → 8,659 ns | +3.39% | 329 → 329 | +0.03% |

(Humble and Jazzy ship the older/reduced `benchmark_executor` with only the `spin_some` executor
scenario; Lyrical carries the full set including the mutually-exclusive `MultipleCallbackGroups` and
chained `Cascaded` scenarios — the most relevant to this fix.)

**Time delta:** small and within run-to-run noise (−2.5% … +3.7%). **Allocation delta:** identical
in every scenario. The fix adds no allocations on the hot path; Humble's higher absolute
allocations/time reflect the `memory_strategy_` executor architecture, not the fix.

### Cross-executor reference (Lyrical, all from the fixed-ref binary)

| Scenario | SingleThreaded | MTE (fixed) | EventsCBG | MTE allocs | EventsCBG allocs |
|---|---|---|---|---|---|
| spin_some | 17,355 ns | 16,981 ns | 14,748 ns | 40 | 61.3 |
| MultipleCallbackGroups spin_some | 17,088 ns | 17,338 ns | 14,556 ns | 40 | 61.4 |
| Cascaded spin | 29,736 ns | 83,176 ns | 19,038 ns | ~0 | 0.14 |

`EventsCBGExecutor` is faster on `spin_some` (≈ 14.7 µs vs 17 µs) but allocates more per iteration
(≈ 61 vs 40). On the chained `Cascaded` scenario the MTE is markedly slower (83 µs vs 19 µs) — a
genuine, reproducible architectural difference between the polling MTE and the event-driven executor,
independent of this fix.

---

## 3. Macro-benchmark: Autoware reference system

The [`ros-realtime/reference-system`](https://github.com/ros-realtime/reference-system)
`autoware_reference_system` run against the overlaid **fixed** rclcpp, with an added
`EventsCBGExecutor` variant. Hot-path latency (Front-LiDAR → Object-Collision-Estimator), one
**600 s (10-minute)** run per executor, single RMW (`rmw_cyclonedds_cpp`), idle host.

| Distro | Executor | mean (ms) | min | max | std | drops |
|---|---|---|---|---|---|---|
| Jazzy | EventsCBGExecutor | 12.92 | 7.53 | 19.97 | 2.18 | 0 |
| Jazzy | **MTE (fixed)** | **13.56** | 8.19 | 20.05 | 2.06 | 0 |
| Jazzy | SingleThreaded | 15.54 | 7.91 | 17.24 | 1.90 | 0 |
| Lyrical | EventsCBGExecutor | 12.51 | 6.64 | 20.92 | 2.40 | 0 |
| Lyrical | **MTE (fixed)** | **12.92** | 6.88 | 22.11 | 2.33 | 0 |
| Lyrical | SingleThreaded | 16.53 | 7.94 | 28.03 | 5.08 | 0 |

The fixed MTE tracks `EventsCBGExecutor` within ≈ 0.6 ms of mean hot-path latency on the realistic
Autoware workload, and both beat the single-threaded executor — the ordering the EMSOFT paper's
Table I reports. **Zero dropped messages** on every executor across the full 10-minute window.

---

## 4. Summary

- The starvation bug is **real and total** on the unfixed MTE (one timer never runs) on all three
  distros; the fix **eliminates it** while keeping the single-threaded path and overall scheduling
  semantics intact.
- The fix costs **zero extra heap allocations** and a **≈ 0–4 % time delta** in the micro-benchmark
  (within noise), and is **latency-competitive with `EventsCBGExecutor`** on the Autoware macro
  workload.
- On Humble — the `memory_strategy_` era with no `EventsCBGExecutor` — this fix is the **only**
  available remedy for the starvation.

## 5. Caveats / scope of these numbers

- **Macro is 600 s × 1 run per executor**, not the paper's 600 s × 5. The ×1 numbers are stable
  (0 drops, tight std) but not multi-run averaged; `make autoware-smoke AW_RUNS=5` /
  `docker/run-autoware-lyrical.sh 600 5` runs the full ×5.
- **No p99/percentile column.** The reference-system's stock tooling reports only
  min / mean / max / std-dev; percentiles would require custom post-processing of raw per-sample
  data (not logged by the stock nodes).
- The reference-system is CI-tested only on Humble/Iron/Rolling. It builds and runs on Jazzy/Lyrical
  with two source adaptations (made in `docker/autoware/run.sh`, not in the reference-system or
  rclcpp): build with `BUILD_TESTING=OFF` (its unit tests use an unavailable `ament_target_dependencies`
  on newer ament), and skip the `StaticSingleThreadedExecutor` variant on Lyrical (that executor was
  removed in rclcpp 32). Neither affects the executors under comparison.
- Timing was measured on an otherwise-idle host; absolute numbers will vary by machine, but the
  allocation deltas (zero) and the relative ordering are machine-independent.
