# MTE starvation fix — 3-way comparison (lyrical)

- **fixed ref:** `fix/mte-starvation-lyrical`  ·  **baseline ref:** `upstream/lyrical`
- **benchmark:** `benchmark_executor` (upstream's own), `-DCMAKE_BUILD_TYPE=Release`, `--benchmark_repetitions=3` aggregates-only (mean ± stddev).
- **method:** the fix changes `MultiThreadedExecutor` in place, so *fixed vs unfixed MTE* = same benchmark binary built from the fix ref vs pristine upstream. `cbg_executor_*` rows are the `EventsCBGExecutor` (same code in both refs).

## Starvation (the bug)

| Executor | Starvation-free? | Evidence |
|---|---|---|
| unfixed MTE | **STARVES** | one=0 two=20 |
| fixed MTE | **OK** | — |
| EventsCBGExecutor | **OK** | twin test `starvation_eventscbg_passes` |

## MTE overhead — fixed vs unfixed (same binary)

`real_time` is mean over repetitions; `Δ` = (fixed − unfixed)/unfixed. Allocations = sum of heap/alloc counters from `performance_test_fixture`.

| Scenario | unfixed real_time | fixed real_time | Δ time | unfixed allocs | fixed allocs | Δ allocs |
|---|---|---|---|---|---|---|
| spin_some (basic) | 17,116 ns | 17,102 ns | -0.08% | 40 | 40 | +0.00% |
| MultipleCallbackGroups spin_some | 17,503 ns | 17,839 ns | +1.92% | 40 | 40 | +0.00% |
| Cascaded spin | 78,688 ns | 75,227 ns | -4.40% | 2e-05 | 2e-05 | +0.00% |
| wait_for_work | 4,583 ns | 4,501 ns | -1.80% | 4 | 4 | -0.00% |
| wait_for_work_rebuild | 9,001 ns | 8,652 ns | -3.88% | 329 | 329 | -0.03% |

## Cross-executor (fixed ref) — MTE vs EventsCBGExecutor vs SingleThreaded

All three from the fixed-ref binary, so they share build flags & machine state.

| Scenario | SingleThreaded | MTE (fixed) | EventsCBG | MTE allocs | EventsCBG allocs |
|---|---|---|---|---|---|
| spin_some (basic) | 17,263 ns | 17,102 ns | 14,650 ns | 40 | 61.3 |
| MultipleCallbackGroups spin_some | 17,894 ns | 17,839 ns | 14,837 ns | 40 | 61.4 |
| Cascaded spin | 24,700 ns | 75,227 ns | 14,724 ns | 2e-05 | 0.141 |
| wait_for_work | 4,546 ns | 4,501 ns | — | 4 | — |
| wait_for_work_rebuild | 8,865 ns | 8,652 ns | — | 329 | — |

---
_Allocation counters summed: heap_allocations._
_Benchmarks present (fixed): 23; (baseline): 23._
