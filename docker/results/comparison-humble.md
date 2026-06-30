# MTE starvation fix — 3-way comparison (humble)

- **fixed ref:** `fix/mte-starvation-humble`  ·  **baseline ref:** `upstream/humble`
- **benchmark:** `benchmark_executor` (upstream's own), `-DCMAKE_BUILD_TYPE=Release`, `--benchmark_repetitions=10` aggregates-only (mean ± stddev).
- **method:** the fix changes `MultiThreadedExecutor` in place, so *fixed vs unfixed MTE* = same benchmark binary built from the fix ref vs pristine upstream. `cbg_executor_*` rows are the `EventsCBGExecutor` (same code in both refs).

## Starvation (the bug)

| Executor | Starvation-free? | Evidence |
|---|---|---|
| unfixed MTE | **STARVES** | one=20 two=0 |
| fixed MTE | **OK** | — |
| EventsCBGExecutor | **n/a** | twin test `starvation_eventscbg_passes` |

## MTE overhead — fixed vs unfixed (same binary)

`real_time` is mean over repetitions; `Δ` = (fixed − unfixed)/unfixed. Allocations = sum of heap/alloc counters from `performance_test_fixture`.

| Scenario | unfixed real_time | fixed real_time | Δ time | unfixed allocs | fixed allocs | Δ allocs |
|---|---|---|---|---|---|---|
| spin_some (basic) | 49,547 ns | 50,416 ns | +1.75% | 83.1 | 83.1 | +0.00% |

## Cross-executor (fixed ref) — MTE vs EventsCBGExecutor vs SingleThreaded

All three from the fixed-ref binary, so they share build flags & machine state.

| Scenario | SingleThreaded | MTE (fixed) | EventsCBG | MTE allocs | EventsCBG allocs |
|---|---|---|---|---|---|
| spin_some (basic) | 50,503 ns | 50,416 ns | — | 83.1 | — |

---
_Allocation counters summed: heap_allocations._
_Benchmarks present (fixed): 14; (baseline): 14._
