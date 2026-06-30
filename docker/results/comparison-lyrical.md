# MTE starvation fix — 3-way comparison (lyrical)

- **fixed ref:** `fix/mte-starvation-lyrical`  ·  **baseline ref:** `upstream/lyrical`
- **benchmark:** `benchmark_executor` (upstream's own), `-DCMAKE_BUILD_TYPE=Release`, `--benchmark_repetitions=10` aggregates-only (mean ± stddev).
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
| spin_some (basic) | 16,536 ns | 16,981 ns | +2.69% | 40 | 40 | +0.00% |
| MultipleCallbackGroups spin_some | 16,728 ns | 17,338 ns | +3.65% | 40 | 40 | +0.00% |
| Cascaded spin | 85,308 ns | 83,176 ns | -2.50% | 2e-05 | 2e-05 | +0.00% |
| wait_for_work | 4,619 ns | 4,751 ns | +2.85% | 4 | 4 | +0.00% |
| wait_for_work_rebuild | 8,375 ns | 8,659 ns | +3.39% | 329 | 329 | +0.03% |

## Cross-executor (fixed ref) — MTE vs EventsCBGExecutor vs SingleThreaded

All three from the fixed-ref binary, so they share build flags & machine state.

| Scenario | SingleThreaded | MTE (fixed) | EventsCBG | MTE allocs | EventsCBG allocs |
|---|---|---|---|---|---|
| spin_some (basic) | 17,355 ns | 16,981 ns | 14,748 ns | 40 | 61.3 |
| MultipleCallbackGroups spin_some | 17,088 ns | 17,338 ns | 14,556 ns | 40 | 61.4 |
| Cascaded spin | 29,736 ns | 83,176 ns | 19,038 ns | 2e-05 | 0.141 |
| wait_for_work | 4,661 ns | 4,751 ns | — | 4 | — |
| wait_for_work_rebuild | 8,581 ns | 8,659 ns | — | 329 | — |

---
_Allocation counters summed: heap_allocations._
_Benchmarks present (fixed): 23; (baseline): 23._
