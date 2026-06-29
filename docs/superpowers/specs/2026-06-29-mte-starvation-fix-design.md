# Design: Multi-Threaded Executor Starvation Fix

**Date:** 2026-06-29
**Author:** Harun Teper
**Paper:** Teper et al., "Thread Carefully: Preventing Starvation in the ROS 2 Multi-Threaded Executor," EMSOFT 2024
**Upstream PR:** https://github.com/ros2/rclcpp/pull/2702 (open, labeled `more-information-needed`)
**Prior Humble fix:** https://github.com/HarunTeper/rclcpp_humble_multithreaded_executor (branch `fix`)

---

## 1. Problem

The ROS 2 `MultiThreadedExecutor` (MTE) can **starve** callbacks in mutually-exclusive
callback groups: a task may never execute even after an instance of it is placed in the
wait set.

**Root cause (from the paper, §III–IV):** At a polling point, the executor clears the wait
set and refills it with all *eligible* callbacks. A callback whose group has
`can_be_taken_from == false` (because another callback in its group is running) is **blocked**
and therefore **removed** from the wait set. It is only re-added at a *later* polling point —
together with fresh, higher-priority instances of the same group. Under static-priority
ordering, the higher-priority instance wins again, the lower-priority callback is removed
again, and this repeats indefinitely. This breaks the starvation-freedom that the response-time
analyses of Jiang et al. (RTSS'22) and Sobhani et al. (RTAS'23) assume.

**Fix mechanism (from the paper, §VI):**
1. **Do not drop blocked callbacks.** Make blocked entities from the previous poll *persistent*:
   keep them and re-add them to the current wait result after `wait()` returns.
2. **Second mutex (`notify_mutex`).** Guard callback-group-flag updates
   (`can_be_taken_from`) and the `interrupt_guard_condition_->trigger()` so a polling thread
   cannot clear/refill the wait set concurrently with another thread unblocking a group. This
   closes the race that an intuitive single-mutex approach would deadlock on (proven via SPIN
   model checking in the paper).
3. **Avoid busy-waiting.** After re-adding previously-blocked entities, only *wait on the
   newly-added* callbacks — re-added blocked entities are already "ready" and would otherwise
   spin the poll loop.

The design is proven **deadlock-free and starvation-free** (paper §VII) and incurs negligible
overhead on the Autoware Reference System (paper Table I).

## 2. Landscape (verified 2026-06-29)

The MTE is **not one codebase** — it splits into two eras, and the situation changed materially
since the 2024 PR:

| Distro | Status | Executor base | EventsCBGExecutor present? |
|---|---|---|---|
| **Humble** | LTS (EOL 2027), widely deployed | `memory_strategy_`-based | ❌ No |
| Iron | EOL | `memory_strategy_`-based | ❌ No |
| **Jazzy** | LTS (current) | `wait_result_`/collector-based | ✅ Yes (backported) |
| Kilted | stable | `wait_result_`-based | ✅ Yes |
| Lyrical | stable (newest) | `wait_result_`-based | ✅ Yes |
| Rolling | dev | `wait_result_`-based | ✅ Yes |

**Key external development:** jmachowinski's `EventsCBGExecutor` (Cellumation `cm_executors`) —
the exact event-queue / per-callback-group design he proposed on PR #2702 — was **merged into
`ros2/rclcpp` in April 2026** (rclcpp 32.0.0, "Lyrical Luth"). It is event-queue based, schedules
per-callback-group ready entities, and **structurally avoids the starvation bug** (confirmed by
maintainer `alsora` on Discourse: the bug is "specific to the multi-threaded executor
implementation and the way it uses waitsets"). It is being backported to Jazzy/Kilted
(`skyegalaxy/{jazzy,kilted}-cbg-exec-backport`).

**Implications:**
- For **Humble/Iron**, EventsCBGExecutor is unavailable → the MTE fix is the *only* remedy. **Highest value.**
- For **Jazzy → Rolling**, users have an escape hatch (EventsCBGExecutor) → the MTE fix is
  valuable for systems that can't switch, but its merge case must be argued against "just use
  EventsCBGExecutor."
- The MTE starvation code is **byte-identical across Jazzy/Kilted/Lyrical/Rolling**; jazzy↔rolling
  differ only cosmetically in `multi_threaded_executor.cpp` and ~125 lines in `executor.cpp`. So
  **one fix on the `wait_result_` era backports cleanly Rolling → Jazzy.**

## 3. Goals & Scope

Primary outcome (user's stated order): a **correct, demonstrable, reproducible** fix the user
controls, then shape toward upstream. Plus a **data-driven comparison** to settle the
"fix the MTE vs. point users at EventsCBGExecutor" question left open on Discourse.

### Track A (primary): Humble fix
Port the existing `rclcpp_humble_multithreaded_executor` `fix` branch onto the **current upstream
`humble` branch** of `ros2/rclcpp`. `memory_strategy_`-era codebase. Deliverable: a clean,
PR-ready `humble` branch in the fork with the starvation test passing and the suite green.

### Track B (forward-port check): Rolling → Jazzy
Re-express the same fix on the `wait_result_`-era code. **Develop on Rolling** (where PR #2702
lives and where upstream CI runs), then **confirm it cherry-picks to Jazzy**. This is "patch up,"
not a rewrite (verified: only cosmetic + ~125-line `executor.cpp` deltas between the two).

### Comparison (first-class deliverable)
A single harness runs identical workloads against three executors:
1. `MultiThreadedExecutor` (unfixed) — reproduces starvation (control).
2. `MultiThreadedExecutor` (fixed) — must be starvation-free.
3. `EventsCBGExecutor` (upstream, unmodified) — already starvation-free.

Measured on: **(a)** starvation-freedom, **(b)** overhead vs. baseline, **(c)** latency/CPU.

### Out of scope
- Reimplementing the EventsCBGExecutor design (it already exists upstream — we *compare against*
  it, we do not rebuild it).
- Iron (EOL); Kilted/Lyrical (covered transitively — same `wait_result_` era as Jazzy/Rolling;
  apply if/when needed).
- Updated response-time analysis (paper notes this is future work).

## 4. Benchmarks

Two layers, both run inside Docker. The user chose **both from the start**.

**Micro — upstream's own `rclcpp/test/benchmark/benchmark_executor.cpp`.**
Google Benchmark via `ament_cmake_google_benchmark` + `performance_test_fixture` (tracks **time
and heap allocations**). Already benchmarks single/multi/cbg executors side-by-side across:
`PerformanceTestExecutor` (N pub/sub), `PerformanceTestExecutorMultipleCallbackGroups`
(**mutually-exclusive groups — our exact scenario**), `CascadedPerformanceTestExecutor` (chain
latency), and `benchmark_wait_for_work[_force_rebuild]` (**isolates the wait-set rebuild cost —
the exact path our fix touches**). We add a **fixed-MTE template instantiation** to get
apples-to-apples numbers. Strategic value: this is the maintainers' *own* yardstick, so
"negligible overhead" claims land in their terms.

**Macro — Autoware Reference System** (`ros-realtime/reference-system`).
The benchmark the paper used (Table I: mean / std / 99th-percentile latency). Realistic
large-scale node graph; the standard ROS real-time overhead benchmark. Heavier Docker setup,
slower to iterate, but matches the published results directly.

## 5. Docker & Test Environment

Repo-local `docker/` directory, driven by `compose` + a `Makefile`:

```
docker/
  humble/Dockerfile      # FROM ros:humble  — Track A
  rolling/Dockerfile     # FROM ros:rolling — Track B dev + comparison
  jazzy/Dockerfile       # FROM ros:jazzy   — Track B backport validation
  compose.yaml
  run-comparison.sh      # builds + runs the 3-way table
Makefile                 # make humble-test | rolling-bench | compare | ...
```

Each image: mounts the rclcpp source overlay, builds rclcpp **from source** with `colcon`, then runs:
1. The **starvation gtest** (`test/rclcpp/executors/test_multi_threaded_executor.cpp`).
2. The **micro-benchmark** (`benchmark_executor.cpp` + fixed-MTE variant).
3. The **Autoware Reference System** macro-benchmark.

`run-comparison.sh` emits a results table for {MTE-unfixed, MTE-fixed, EventsCBGExecutor} ×
{starvation-free?, time, heap allocs, Autoware latency percentiles}.

## 6. Validation & Correctness

- **TDD on the bug.** The existing starvation test is the red test. It is currently
  timing-fragile (`sleep_for` + `ASSERT_LE(diff, 1)`); harden it into a **deterministic**
  starvation detector (count-balance / bounded-skew invariant that fails reliably on unfixed
  MTE) *before* touching the fix.
- **Reproduce → fix → confirm.** Reproduce starvation on unfixed MTE (both eras) → fix makes
  the test pass → EventsCBGExecutor passes the same test unmodified → full rclcpp test suite +
  `ament_lint` pass.
- **Correctness arguments** carry over from the paper: two-mutex protocol for deadlock-freedom;
  SPIN model (already in `tu-dortmund-ls12-rt/ROS2-MT-Starvation-Examples`) for the model-checked
  property. No new proofs required for the engineering work.

## 7. Risks & Open Questions

- **Merge case for Jazzy→Rolling.** With EventsCBGExecutor merged, maintainers may prefer
  "use EventsCBGExecutor" over patching the MTE. Mitigation: the comparison data + the Humble
  argument (no EventsCBGExecutor there) make the case. Re-engage `jmachowinski`/`alsora` on the
  PR once we have running code + numbers, not before.
- **Fork is 175 commits behind upstream/rolling.** Track B starts from a fresh branch off current
  `upstream/rolling`; the existing 7 PR commits become reference, not foundation.
- **Wait-set-persistence on the `wait_result_` era** is the hard, previously-unfinished part
  (PR step 4). The `previous_wait_result_` member is sketched but the re-add logic and priority
  positioning are unimplemented — this is the core engineering work.
- **Autoware Docker weight.** Macro-benchmark setup is heavy; if it blocks iteration, micro-bench
  carries day-to-day work while Autoware runs are batched.

## 8. Build Order (high level — detailed plan to follow)

1. Docker scaffolding (humble + rolling images, build-from-source, run the existing test).
2. Harden the starvation test into a deterministic detector; confirm it **fails** on unfixed MTE.
3. **Track A (Humble):** port the `fix` branch → test passes → suite green → PR-ready branch.
4. **Track B (Rolling):** implement wait-set persistence on the `wait_result_` era → test passes.
5. Add fixed-MTE micro-benchmark variant; wire up Autoware Reference System.
6. Run the 3-way comparison; produce the results table.
7. Validate Rolling fix cherry-picks to Jazzy.
8. Update PR #2702 with running code + numbers; re-engage maintainers.
