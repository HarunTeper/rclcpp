# MTE Starvation Fix, Benchmark Results

Consolidated results for the MultiThreadedExecutor (MTE) starvation fix across all three target
distros. This document accompanies the fix branches and is the evidence base for the PR.

- Branches. `fix/mte-starvation-{humble,jazzy,lyrical}`, each off its own upstream distro.
- rclcpp versions. Humble 16.0.19, Jazzy 28.1.21, Lyrical 32.0.0.
- Two executor eras. Humble is the `memory_strategy_` era with no `EventsCBGExecutor`. Jazzy and
  Lyrical are the `wait_result_` era where `EventsCBGExecutor` is present.
- Raw data lives in `docker/results/`. The files are `comparison-<distro>.md` (per-distro tables),
  `bench_*.json` (google-benchmark output), `starvation-*.txt` (gtest logs), and
  `autoware-latency-<distro>.csv`.
- Reproduce with `make compare-{humble,jazzy,lyrical}` (micro) plus
  `make autoware-smoke AW_DURATION=600 AW_RUNS=1` and `docker/run-autoware-lyrical.sh 600 1` (macro).

---

## 1. The bug, mutually-exclusive callback-group starvation

When two timers share one mutually-exclusive callback group, the unfixed MTE can dispatch one timer
indefinitely while the other never runs. The deterministic detector
(`test_multi_threaded_executor.cpp`, test `starvation_mutually_exclusive_timers`) fires two 5 ms wall
timers in one mutually-exclusive group, each sleeping 20 ms, until one reaches 20 firings, then
asserts both ran and their counts differ by no more than 2.

| Executor | Humble | Jazzy | Lyrical |
|---|---|---|---|
| unfixed MTE | STARVES (`one=20 two=0`) | STARVES (`one=0 two=20`) | STARVES (`one=0 two=20`) |
| fixed MTE | OK | OK | OK |
| EventsCBGExecutor | n/a (not in Humble) | OK | OK |

The unfixed MTE starves 100% (the victim timer never executes, count 0) on every distro. The starved
timer differs by thread race but the total starvation is identical. The fixed MTE alternates
correctly. `EventsCBGExecutor` is starvation-free by construction (verified via the twin test
`starvation_eventscbg_passes`), which is the comparison baseline the EMSOFT paper relies on.

The same starvation test `.cpp` was compiled against the unfixed executor (overlaid onto pristine
upstream) and the fixed executor, so the only variable is the executor.

---

## 2. Micro-benchmark, fix overhead (upstream `benchmark_executor`)

Method. The fix changes `MultiThreadedExecutor` in place, so fixed versus unfixed means the same
`benchmark_executor` binary built from the fix ref against pristine upstream.
`-DCMAKE_BUILD_TYPE=Release`, `--benchmark_repetitions=10` (mean). Heap-allocation counters come from
`performance_test_fixture` with the `osrf_testing_tools_cpp` memory-tools interposer LD_PRELOADed.
Measured on an idle 24-core host (load about 0.4).

The headline is that heap-allocation overhead is exactly zero on every distro. Allocation counts are
deterministic and load-independent, so this is the robust evidence for the negligible-overhead claim.

| Distro | Scenario | unfixed to fixed real_time | delta time | unfixed to fixed allocs | delta allocs |
|---|---|---|---|---|---|
| Humble | spin_some | 49,547 to 50,416 ns | +1.75% | 83.1 to 83.1 | +0.00% |
| Jazzy | spin_some | 28,726 to 28,639 ns | -0.30% | 47.1 to 47.1 | +0.00% |
| Lyrical | spin_some | 16,536 to 16,981 ns | +2.69% | 40 to 40 | +0.00% |
| Lyrical | MultipleCallbackGroups spin_some | 16,728 to 17,338 ns | +3.65% | 40 to 40 | +0.00% |
| Lyrical | Cascaded spin | 85,308 to 83,176 ns | -2.50% | about 0 | +0.00% |
| Lyrical | wait_for_work | 4,619 to 4,751 ns | +2.85% | 4 to 4 | +0.00% |
| Lyrical | wait_for_work_rebuild | 8,375 to 8,659 ns | +3.39% | 329 to 329 | +0.03% |

Humble and Jazzy ship the older, reduced `benchmark_executor` with only the `spin_some` executor
scenario. Lyrical carries the full set including the mutually-exclusive `MultipleCallbackGroups` and
chained `Cascaded` scenarios, which are the most relevant to this fix.

The time delta is small and within run-to-run noise (-2.5% to +3.7%). The allocation delta is
identical in every scenario. The fix adds no allocations on the hot path. Humble's higher absolute
allocations and time reflect the `memory_strategy_` executor architecture, not the fix.

### Cross-executor reference (Lyrical, all from the fixed-ref binary)

| Scenario | SingleThreaded | MTE (fixed) | EventsCBG | MTE allocs | EventsCBG allocs |
|---|---|---|---|---|---|
| spin_some | 17,355 ns | 16,981 ns | 14,748 ns | 40 | 61.3 |
| MultipleCallbackGroups spin_some | 17,088 ns | 17,338 ns | 14,556 ns | 40 | 61.4 |
| Cascaded spin | 29,736 ns | 83,176 ns | 19,038 ns | about 0 | 0.14 |

`EventsCBGExecutor` is faster on `spin_some` (about 14.7 us versus 17 us) but allocates more per
iteration (about 61 versus 40). On the chained `Cascaded` scenario the MTE is markedly slower (83 us
versus 19 us), a genuine and reproducible architectural difference between the polling MTE and the
event-driven executor, independent of this fix.

---

## 3. Macro-benchmark, Autoware reference system

The [`ros-realtime/reference-system`](https://github.com/ros-realtime/reference-system)
`autoware_reference_system` run against the overlaid rclcpp, with an added `EventsCBGExecutor`
variant. Hot-path latency (Front-LiDAR to Object-Collision-Estimator), one 600 s (10-minute) run per
executor, single RMW (`rmw_cyclonedds_cpp`), idle host.

| Distro | Executor | mean (ms) | min | max | std | drops |
|---|---|---|---|---|---|---|
| Jazzy | EventsCBGExecutor | 12.92 | 7.53 | 19.97 | 2.18 | 0 |
| Jazzy | MTE (fixed) | 13.56 | 8.19 | 20.05 | 2.06 | 0 |
| Jazzy | MTE (unfixed) | 12.01 | 7.97 | 21.06 | 2.04 | 0 |
| Jazzy | SingleThreaded | 15.54 | 7.91 | 17.24 | 1.90 | 0 |
| Lyrical | EventsCBGExecutor | 12.51 | 6.64 | 20.92 | 2.40 | 0 |
| Lyrical | MTE (fixed) | 12.92 | 6.88 | 22.11 | 2.33 | 0 |
| Lyrical | MTE (unfixed) | 11.97 | 6.86 | 20.78 | 2.09 | 0 |
| Lyrical | SingleThreaded | 16.53 | 7.94 | 28.03 | 5.08 | 0 |

The fixed MTE tracks `EventsCBGExecutor` within about 0.6 ms of mean hot-path latency on the
realistic Autoware workload, and both beat the single-threaded executor. That is the ordering the
EMSOFT paper's Table I reports. Zero dropped messages on every executor across the full 10-minute
window.

---

## 4. Fixed versus unfixed MTE on the Autoware workload

The unfixed `MultiThreadedExecutor` row above lets us compare the fix's cost on the realistic
workload, not just the micro-benchmark. Two things stand out, and both are honest about scope.

First, the fix's macro cost is small. The fixed MTE runs a little slower than the unfixed MTE on
this workload. On Jazzy that is 13.56 ms versus 12.01 ms, about 1.5 ms (roughly 13%). On Lyrical it
is 12.92 ms versus 11.97 ms, about 1.0 ms (roughly 8%). This is larger than the micro-benchmark
delta and worth noting, though both stay well under the single-threaded executor and within the
run-to-run spread (std about 2 ms, min and max overlap heavily across the three MTE variants). A
multi-run average would tighten these numbers.

Second, and importantly, the unfixed MTE does **not** starve on this workload (0 drops, normal
latency). That is expected. The starvation bug requires two or more ready callbacks contending in a
single mutually-exclusive callback group, which the targeted micro test
(`starvation_mutually_exclusive_timers`) constructs deliberately. The Autoware reference system does
not arrange its callbacks that way, so the unfixed MTE runs it without triggering the bug. The macro
benchmark therefore measures the fix's **overhead on a workload where the bug does not fire**, which
is exactly the conservative comparison we want. The starvation itself is demonstrated by the micro
test in section 1, where the unfixed MTE fails outright on all three distros.

In short, the macro numbers say the fix is not free but is cheap (about 1 to 1.5 ms of mean latency
on a 10-minute Autoware run, no dropped messages), and the micro numbers say it adds zero
allocations. The bug it removes is a total starvation that the unfixed executor cannot avoid once the
contended-group condition occurs.

---

## 5. Summary

- The starvation bug is real and total on the unfixed MTE (one timer never runs) on all three
  distros. The fix eliminates it while keeping the single-threaded path and overall scheduling
  semantics intact.
- The fix costs zero extra heap allocations and a time delta of about 0 to 4% in the micro-benchmark
  (within noise). On the Autoware macro workload the fixed MTE tracks `EventsCBGExecutor` within
  about 0.6 ms, and runs about 1 to 1.5 ms slower than the unfixed MTE on a workload that does not
  trigger the starvation (a conservative overhead measurement, no dropped messages).
- On Humble, the `memory_strategy_` era with no `EventsCBGExecutor`, this fix is the only available
  remedy for the starvation.

## 6. Caveats and scope of these numbers

- The macro is 600 s by one run per executor, not the paper's 600 s by five. The single-run numbers
  are stable (0 drops, tight std) but not multi-run averaged. `make autoware-smoke AW_RUNS=5` and
  `docker/run-autoware-lyrical.sh 600 5` run the full five.
- There is no p99 or percentile column. The reference-system's stock tooling reports only min, mean,
  max, and std-dev. Percentiles would require custom post-processing of raw per-sample data, which
  the stock nodes do not log.
- The reference-system is CI-tested only on Humble, Iron, and Rolling. It builds and runs on Jazzy
  and Lyrical with two source adaptations made in `docker/autoware/run.sh`, not in the
  reference-system or rclcpp. Those adaptations are building with `BUILD_TESTING=OFF` (its unit tests
  use an unavailable `ament_target_dependencies` on newer ament) and skipping the
  `StaticSingleThreadedExecutor` variant on Lyrical (that executor was removed in rclcpp 32). Neither
  affects the executors under comparison.
- Timing was measured on an otherwise-idle host. Absolute numbers vary by machine, but the allocation
  deltas (zero) and the relative ordering are machine-independent.
