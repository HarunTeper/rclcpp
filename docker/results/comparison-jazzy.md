# MTE starvation fix — 3-way comparison (jazzy)

- **fixed ref:** `fix/mte-starvation-jazzy`  ·  **baseline ref:** `upstream/jazzy`
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
| spin_some (basic) | 28,564 ns | 28,358 ns | -0.72% | 47.1 | 47.1 | -0.00% |

## Cross-executor (fixed ref) — MTE vs EventsCBGExecutor vs SingleThreaded

All three from the fixed-ref binary, so they share build flags & machine state.

| Scenario | SingleThreaded | MTE (fixed) | EventsCBG | MTE allocs | EventsCBG allocs |
|---|---|---|---|---|---|
| spin_some (basic) | 28,504 ns | 28,358 ns | — | 47.1 | — |

---
_Allocation counters summed: heap_allocations._
_Benchmarks present (fixed): 13; (baseline): 13._
