# Multi-Threaded Executor Starvation Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the ROS 2 `MultiThreadedExecutor` starvation-free for mutually-exclusive callback groups, on both the Humble (`memory_strategy_`) era and the Jazzy→Rolling (`wait_result_`) era, validated in Docker against a deterministic test and benchmarked against the upstream `EventsCBGExecutor`.

**Architecture:** The bug: at each poll, blocked callbacks (group `can_be_taken_from()==false`) are dropped from the wait set and only re-added later alongside fresh higher-priority instances, so the low-priority one starves. The fix (per the EMSOFT 2024 paper §VI): keep blocked entities *persistent* across polls and re-add them after `wait()`; guard callback-group-flag updates + guard-condition triggers under a second `notify_mutex_` so polling cannot race flag-clearing; only wait on newly-added entities to avoid busy-waiting. Two source eras need two distinct patches because the wait-set plumbing and the location of `can_be_taken_from().store(true)` differ.

**Tech Stack:** C++17, rclcpp, `colcon`/`ament_cmake`, GoogleTest (`ament_add_ros_isolated_gtest`), Google Benchmark (`ament_cmake_google_benchmark` + `performance_test_fixture`), Docker (`ros:humble`, `ros:jazzy`, `ros:rolling`), the Autoware Reference System (`ros-realtime/reference-system`).

## Global Constraints

- **rclcpp coding style:** match surrounding code; pass `ament_uncrustify`, `ament_cpplint`, `ament_cppcheck`. 100-col lines. `RCLCPP_PUBLIC` on new public/protected methods. Copyright header unchanged.
- **No behavior change for the common case:** reentrant callback groups, single-threaded executor, and non-mutually-exclusive workloads must behave exactly as before. The fix only alters how *blocked mutually-exclusive* entities are retained.
- **No new dependencies** in `package.xml` for the fix itself (Docker/benchmark tooling lives outside the rclcpp build deps where possible; `performance_test_fixture` is already a test dep).
- **Branches** (in fork `HarunTeper/rclcpp`, remote `origin`; `upstream` = `ros2/rclcpp`):
  - `fix/mte-starvation-humble` off `upstream/humble`
  - `fix/mte-starvation-rolling` off `upstream/rolling`
  - Jazzy validated by cherry-pick onto a throwaway branch off `upstream/jazzy`.
- **Commit trailer** on every commit:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **The deterministic starvation test is the contract.** It must FAIL on unfixed MTE and PASS on fixed MTE and on `EventsCBGExecutor`, in every era.

---

## File Structure

**Docker / harness (fork root, not part of the rclcpp ament package):**
- `docker/humble/Dockerfile` — `FROM ros:humble`, build rclcpp from source overlay.
- `docker/rolling/Dockerfile` — `FROM ros:rolling`.
- `docker/jazzy/Dockerfile` — `FROM ros:jazzy`.
- `docker/compose.yaml` — services `humble`, `rolling`, `jazzy`; mounts the repo.
- `docker/run-comparison.sh` — builds + runs test + benchmarks, emits a results table.
- `Makefile` — convenience targets (`humble-build`, `rolling-test`, `compare`, …).

**Fix — Rolling/Jazzy era (`wait_result_`):**
- Modify `rclcpp/include/rclcpp/executor.hpp` — add `notify_mutex_`, `previous_wait_result_`, and the `add_blocked_entities_to_wait_set` helper decl.
- Modify `rclcpp/src/rclcpp/executor.cpp` — `wait_for_work`, `get_next_executable`, new helper.
- Modify `rclcpp/src/rclcpp/executors/multi_threaded_executor.cpp` — move flag-reset + trigger under `notify_mutex_`.

**Fix — Humble era (`memory_strategy_`):**
- Modify `rclcpp/include/rclcpp/executor.hpp` (humble) — add `notify_mutex_`, persistence state.
- Modify `rclcpp/src/rclcpp/executor.cpp` (humble) — `wait_for_work`, `execute_any_executable`, `get_next_executable`.
- Modify `rclcpp/src/rclcpp/executors/multi_threaded_executor.cpp` (humble).

**Test (both eras):**
- Modify `rclcpp/test/rclcpp/executors/test_multi_threaded_executor.cpp` — replace the fork's fragile `starvation` test with a deterministic, parameterized one.

**Benchmark (Rolling/Jazzy only — EventsCBGExecutor exists there):**
- Modify `rclcpp/test/benchmark/benchmark_executor.cpp` — add a fixed-MTE variant alongside the existing `multi_thread_*` / `cbg_executor_*` benchmarks.

**Autoware macro-benchmark:**
- `docker/autoware/` — clone + build `reference-system`, run with each executor, collect latency CSVs.

---

## Phase 0 — Docker environment & reproduction

### Task 0.1: Docker scaffolding for the Rolling era

**Files:**
- Create: `docker/rolling/Dockerfile`
- Create: `docker/compose.yaml`
- Create: `Makefile`

**Interfaces:**
- Produces: a container that mounts the repo at `/ws/src/rclcpp` and can `colcon build --packages-select rclcpp`. Make target `rolling-build`.

- [ ] **Step 1: Write `docker/rolling/Dockerfile`**

```dockerfile
FROM ros:rolling
SHELL ["/bin/bash", "-c"]

# Build deps for building rclcpp from source + benchmark tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-colcon-common-extensions \
      ros-rolling-performance-test-fixture \
      ros-rolling-test-msgs \
      ros-rolling-ament-cmake-google-benchmark \
      git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /ws
# Source is bind-mounted at runtime to /ws/src/rclcpp (see compose.yaml)
CMD ["bash"]
```

- [ ] **Step 2: Write `docker/compose.yaml`**

```yaml
services:
  rolling:
    build: { context: ., dockerfile: rolling/Dockerfile }
    image: mte-starvation/rolling
    volumes:
      - ../:/ws/src/rclcpp_fork:ro
      - rolling-build:/ws/build
      - rolling-install:/ws/install
    working_dir: /ws
    # The rclcpp package sits at /ws/src/rclcpp_fork/rclcpp; symlink it in at runtime.
    command: bash
volumes:
  rolling-build:
  rolling-install:
```

Note: the repo root contains `rclcpp/`, `rclcpp_action/`, etc. We build only the `rclcpp` package. The container entrypoint will symlink `/ws/src/rclcpp_fork/rclcpp` → a colcon-discoverable path.

- [ ] **Step 3: Write `Makefile`**

```makefile
COMPOSE = docker compose -f docker/compose.yaml

.PHONY: rolling-build rolling-shell
rolling-build:
	$(COMPOSE) build rolling
	$(COMPOSE) run --rm rolling bash -lc '\
	  mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp && \
	  source /opt/ros/rolling/setup.bash && \
	  colcon build --packages-select rclcpp --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo'

rolling-shell:
	$(COMPOSE) run --rm rolling bash
```

- [ ] **Step 4: Build the image and the package**

Run: `make rolling-build`
Expected: image builds; `colcon build --packages-select rclcpp` finishes with `Summary: 1 package finished`. (First build is slow; this confirms the toolchain works.)

- [ ] **Step 5: Commit**

```bash
git add docker/rolling/Dockerfile docker/compose.yaml Makefile
git commit -m "build: add rolling Docker env that builds rclcpp from source

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 0.2: Docker scaffolding for Humble and Jazzy

**Files:**
- Create: `docker/humble/Dockerfile`
- Create: `docker/jazzy/Dockerfile`
- Modify: `docker/compose.yaml`
- Modify: `Makefile`

**Interfaces:**
- Produces: Make targets `humble-build`, `jazzy-build`, analogous to `rolling-build`.

- [ ] **Step 1: Write `docker/humble/Dockerfile`** — identical to rolling's but `FROM ros:humble` and `ros-humble-*` apt package names. Humble has `performance_test_fixture` and `test_msgs`; it does NOT have `events_cbg_executor` (expected — the benchmark's cbg variant is Rolling/Jazzy-only).

```dockerfile
FROM ros:humble
SHELL ["/bin/bash", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-colcon-common-extensions \
      ros-humble-performance-test-fixture \
      ros-humble-test-msgs \
      ros-humble-ament-cmake-google-benchmark \
      git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /ws
CMD ["bash"]
```

- [ ] **Step 2: Write `docker/jazzy/Dockerfile`** — same with `FROM ros:jazzy` and `ros-jazzy-*` names.

- [ ] **Step 3: Add `humble` and `jazzy` services to `docker/compose.yaml`** mirroring the `rolling` service (separate named volumes `humble-build`/`humble-install`/`jazzy-build`/`jazzy-install`).

- [ ] **Step 4: Add `humble-build` / `jazzy-build` Make targets** mirroring `rolling-build` (substitute `/opt/ros/humble`, `/opt/ros/jazzy`).

- [ ] **Step 5: Build both**

Run: `make humble-build jazzy-build`
Expected: both finish `Summary: 1 package finished`.

- [ ] **Step 6: Commit**

```bash
git add docker/humble/Dockerfile docker/jazzy/Dockerfile docker/compose.yaml Makefile
git commit -m "build: add humble and jazzy Docker envs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 1 — A deterministic starvation test (the contract)

The fork's current test (`test_multi_threaded_executor.cpp` lines 109-155) is timing-fragile: it uses `sleep_for(100ms)` and `ASSERT_LE(diff,1)` inside callbacks driven by `10ms` wall timers, and only asserts after a count exceeds 10. It can pass on a buggy executor by luck and is slow. Replace it with a deterministic detector built on the paper's Example 4 (two timers, one mutually-exclusive group): the bug manifests as *one timer's callback never running while the other runs repeatedly*. We detect starvation as "after the unblocked timer has fired N times, the starved timer has fired 0 times."

This phase runs on the **Rolling** container (the test is identical source across eras; we add it to the working tree which is shared).

### Task 1.1: Replace the fork test with a deterministic starvation detector

**Files:**
- Modify: `rclcpp/test/rclcpp/executors/test_multi_threaded_executor.cpp` (replace the `starvation` test, lines 109-155 in the working tree)

**Interfaces:**
- Consumes: existing fixture `TestMultiThreadedExecutor` (SetUpTestCase/TearDownTestCase do rclcpp init/shutdown) and includes already present (`<chrono>`, `<atomic>` via rclcpp, `rclcpp/executors.hpp`, `using namespace std::chrono_literals`).
- Produces: `TEST_F(TestMultiThreadedExecutor, starvation_mutually_exclusive_timers)` that deterministically fails on the unfixed MTE.

- [ ] **Step 1: Add `<atomic>` and `<thread>` includes if missing**

In the include block (currently lines 15-26), ensure these are present (add any missing):

```cpp
#include <atomic>
#include <thread>
```

- [ ] **Step 2: Replace the `starvation` test with a deterministic, executor-templated version**

Delete the entire existing `TEST_F(TestMultiThreadedExecutor, starvation) { ... }` block and replace with a **templated scenario helper** (so the EventsCBGExecutor twin in Task 1.2 reuses it instead of duplicating ~25 lines) plus the MTE test:

```cpp
/*
  Starvation reproduction (paper Example 4): two timers in ONE mutually-exclusive
  callback group, two executor threads. A correct executor alternates between the
  two timers. The buggy MTE keeps re-selecting the higher-priority timer and never
  runs the other one. We make this deterministic: each callback blocks briefly so
  that while one runs, the other's instance is "blocked" and (on the buggy executor)
  dropped from the wait set. We declare starvation if, by the time the first timer
  has fired `kFireTarget` times, the second has fired zero times.

  Templated on the executor type so multiple executors share one scenario body.
  ExecutorT must accept (rclcpp::ExecutorOptions, size_t num_threads).
*/
template<typename ExecutorT>
void run_starvation_scenario(const std::string & node_name)
{
  ExecutorT executor(rclcpp::ExecutorOptions(), 2u);

  auto node = std::make_shared<rclcpp::Node>(node_name);

  // Single mutually-exclusive group shared by both timers.
  auto group = node->create_callback_group(
    rclcpp::CallbackGroupType::MutuallyExclusive);

  constexpr int kFireTarget = 20;
  std::atomic_int count_one{0};
  std::atomic_int count_two{0};
  std::atomic_bool done{false};

  auto make_cb = [&](std::atomic_int & my_count) {
    return [&my_count, &done, &executor]() {
        // Hold the group briefly so the sibling timer's instance is blocked.
        std::this_thread::sleep_for(20ms);
        const int mine = ++my_count;
        if (mine >= kFireTarget && !done.exchange(true)) {
          executor.cancel();
        }
      };
  };

  auto timer_one = node->create_wall_timer(5ms, make_cb(count_one), group);
  auto timer_two = node->create_wall_timer(5ms, make_cb(count_two), group);

  executor.add_node(node);
  executor.spin();  // returns when cancel() is called

  // The starved timer must have fired at least once; a correct (alternating)
  // executor keeps the two counts within 2 of each other.
  EXPECT_GT(count_one.load(), 0) << "timer_one never executed (starved)";
  EXPECT_GT(count_two.load(), 0) << "timer_two never executed (starved)";
  EXPECT_LE(std::abs(count_one.load() - count_two.load()), 2)
    << "counts diverged: one=" << count_one.load() << " two=" << count_two.load();
}

TEST_F(TestMultiThreadedExecutor, starvation_mutually_exclusive_timers) {
  run_starvation_scenario<rclcpp::executors::MultiThreadedExecutor>("test_mte_starvation");
}
```

- [ ] **Step 3: Add a generous test timeout in CMake (so a hung/starved run fails fast rather than blocking CI)**

Modify `rclcpp/test/rclcpp/CMakeLists.txt` — the `test_multi_threaded_executor` registration currently is:

```cmake
ament_add_ros_isolated_gtest(test_multi_threaded_executor executors/test_multi_threaded_executor.cpp
  APPEND_LIBRARY_DIRS "${append_library_dirs}")
```

Add a `TIMEOUT`:

```cmake
ament_add_ros_isolated_gtest(test_multi_threaded_executor executors/test_multi_threaded_executor.cpp
  TIMEOUT 60
  APPEND_LIBRARY_DIRS "${append_library_dirs}")
```

- [ ] **Step 4: Build and run the test on UNFIXED rolling — expect FAILURE**

Run (add a Make target `rolling-test`, see below):
```bash
make rolling-test GTEST_FILTER='TestMultiThreadedExecutor.starvation_mutually_exclusive_timers'
```
Where `rolling-test` runs:
```makefile
rolling-test:
	$(COMPOSE) run --rm rolling bash -lc '\
	  mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp && \
	  source /opt/ros/rolling/setup.bash && \
	  colcon build --packages-select rclcpp --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo && \
	  colcon test --packages-select rclcpp \
	    --ctest-args -R test_multi_threaded_executor \
	    --pytest-args -k starvation ; \
	  colcon test-result --verbose'
```
Expected: the test **FAILS** — `count_two` (or `count_one`) is 0, or the divergence assertion trips. This proves the detector catches the live bug. **Capture the output** as the red baseline.

- [ ] **Step 5: Commit**

```bash
git add rclcpp/test/rclcpp/executors/test_multi_threaded_executor.cpp rclcpp/test/rclcpp/CMakeLists.txt Makefile
git commit -m "test: deterministic MTE starvation detector (fails on unfixed executor)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 1.2: Confirm EventsCBGExecutor passes the same scenario (Rolling)

**Files:**
- Modify: `rclcpp/test/rclcpp/executors/test_multi_threaded_executor.cpp` (add one more test)

**Interfaces:**
- Consumes: `rclcpp::executors::EventsCBGExecutor` from `rclcpp/executors.hpp` (available on Rolling/Jazzy).
- Produces: `TEST_F(TestMultiThreadedExecutor, starvation_eventscbg_passes)` — sanity baseline showing the bug is MTE-specific.

- [ ] **Step 1: Add the EventsCBGExecutor twin test** reusing the templated helper from Task 1.1 (no duplication — only the executor type and node name differ). Guard it with `#if __has_include(...)` so it compiles only where the header exists (Rolling/Jazzy, not Humble):

```cpp
#if __has_include("rclcpp/executors/events_cbg_executor/events_cbg_executor.hpp")
TEST_F(TestMultiThreadedExecutor, starvation_eventscbg_passes) {
  run_starvation_scenario<rclcpp::executors::EventsCBGExecutor>("test_eventscbg_starvation");
}
#endif
```

- [ ] **Step 2: Run it on Rolling — expect PASS**

Run: `make rolling-test` filtering `starvation_eventscbg_passes`.
Expected: **PASS** — confirms the scenario is well-formed and the bug is specific to the MTE.

- [ ] **Step 3: Commit**

```bash
git add rclcpp/test/rclcpp/executors/test_multi_threaded_executor.cpp
git commit -m "test: confirm EventsCBGExecutor is starvation-free on the same scenario

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Fix the Rolling/Jazzy era (`wait_result_`)

Develop on `fix/mte-starvation-rolling` (off `upstream/rolling`, cherry-picking the Phase 1 test commits). The mechanism (verified against `upstream/rolling:rclcpp/src/rclcpp/executor.cpp`):

- `wait_for_work` (≈L758) does `this->wait_result_.reset()` then `wait_set_.wait()` — **this reset drops blocked entities.**
- `get_next_ready_executable` skips entities whose `callback_group->can_be_taken_from()` is false (`continue`) and, when it selects a mutually-exclusive executable, calls `can_be_taken_from().store(false)` (≈L903-907).
- `MultiThreadedExecutor::run` (working tree already has the fork's partial edit) sets `can_be_taken_from().store(true)` and triggers the guard condition *after* execution.

### Task 2.1: Add the `notify_mutex_` and wrap flag-reset + trigger atomically

**Files:**
- Modify: `rclcpp/include/rclcpp/executor.hpp` — add member.
- Modify: `rclcpp/src/rclcpp/executors/multi_threaded_executor.cpp` — `run()`.

**Interfaces:**
- Produces: `mutable std::mutex notify_mutex_;` (protected member of `Executor`), and a `run()` whose post-execute block holds `notify_mutex_` while doing `can_be_taken_from().store(true)` + `interrupt_guard_condition_->trigger()`.

- [ ] **Step 1: Declare `notify_mutex_` in `executor.hpp`**

After the existing `mutable std::mutex mutex_;` declaration, add:

```cpp
  /// Guards callback-group flag changes and guard-condition triggers so that a
  /// polling thread cannot clear/refill the wait set while another thread is
  /// unblocking a mutually-exclusive group. See EMSOFT 2024 fix.
  mutable std::mutex notify_mutex_;
```

- [ ] **Step 2: Rewrite the post-execute block in `multi_threaded_executor.cpp::run()`**

Replace the current post-`execute_any_executable` block with:

```cpp
    execute_any_executable(any_exec);

    if (any_exec.callback_group) {
      std::lock_guard<std::mutex> notify_lock{notify_mutex_};
      // Unblock the group, then wake the executor — atomically w.r.t. polling.
      any_exec.callback_group->can_be_taken_from().store(true);
      if (any_exec.callback_group->type() == CallbackGroupType::MutuallyExclusive) {
        try {
          interrupt_guard_condition_->trigger();
        } catch (const rclcpp::exceptions::RCLError & ex) {
          throw std::runtime_error(
            std::string("Failed to trigger guard condition on callback group change: ") +
            ex.what());
        }
      }
    }

    // Clear the callback_group to prevent the AnyExecutable destructor from
    // resetting the callback group `can_be_taken_from`
    any_exec.callback_group.reset();
```

- [ ] **Step 3: Build — expect compile success, test still FAILS**

Run: `make rolling-test` (filter `starvation_mutually_exclusive_timers`).
Expected: compiles; test **still FAILS**. The mutex alone does not fix starvation — it only closes the race. This is expected and correct; the persistence change (Task 2.2) is what fixes it.

- [ ] **Step 4: Commit**

```bash
git add rclcpp/include/rclcpp/executor.hpp rclcpp/src/rclcpp/executors/multi_threaded_executor.cpp
git commit -m "fix(executor): guard cbg flag reset + notify under notify_mutex_

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.2: Persist blocked entities across polls in `wait_for_work`

**Files:**
- Modify: `rclcpp/include/rclcpp/executor.hpp` — add `previous_wait_result_` member + helper decl.
- Modify: `rclcpp/src/rclcpp/executor.cpp` — `wait_for_work`, `get_next_executable`, new helper.

**Interfaces:**
- Consumes: `notify_mutex_` (Task 2.1); existing `wait_result_` (`std::optional<rclcpp::WaitResult<rclcpp::WaitSet>>`), `wait_set_`, `current_collection_`.
- Produces:
  - `std::optional<rclcpp::WaitResult<rclcpp::WaitSet>> previous_wait_result_;`
  - `void readd_blocked_entities_from_previous_result();` (protected)
  - `get_next_executable` holds `notify_mutex_` across the `wait_for_work` + re-add window.

- [ ] **Step 1: Declare the member and helper in `executor.hpp`**

Next to the existing `wait_result_` declaration, add:

```cpp
  /// Blocked entities retained from the previous poll, re-added after wait().
  std::optional<rclcpp::WaitResult<rclcpp::WaitSet>> previous_wait_result_
    RCPPUTILS_TSA_GUARDED_BY(mutex_);
```

In the protected method section near `wait_for_work`, add:

```cpp
  /// Re-add still-blocked entities from the previous poll into the current
  /// wait result, so blocked mutually-exclusive callbacks are not starved.
  RCLCPP_PUBLIC
  void
  readd_blocked_entities_from_previous_result();
```

- [ ] **Step 2: Write the failing-behavior helper and wire `wait_for_work`**

In `executor.cpp`, change `wait_for_work` so it does NOT discard blocked entities. Current body resets `wait_result_` unconditionally. New approach: before resetting, move the current result into `previous_wait_result_`; after `wait_set_.wait()` produces the fresh result, re-add entities from `previous_wait_result_` whose callback group is still blocked (`can_be_taken_from()==false`) and still valid.

Replace the `wait_for_work` body with:

```cpp
void
Executor::wait_for_work(std::chrono::nanoseconds timeout)
{
  TRACETOOLS_TRACEPOINT(rclcpp_executor_wait_for_work, timeout.count());

  {
    std::lock_guard<std::mutex> guard(mutex_);
    // Retain the previous result instead of discarding blocked entities.
    previous_wait_result_ = std::move(wait_result_);
    wait_result_.reset();

    if (this->entities_need_rebuild_.exchange(false) || current_collection_.empty()) {
      this->collect_entities();
    }
  }

  this->wait_result_.emplace(wait_set_.wait(timeout));

  // Bring forward any entities that are still blocked by a running
  // mutually-exclusive group, so they are not starved.
  this->readd_blocked_entities_from_previous_result();

  if (!this->wait_result_ || this->wait_result_->kind() == WaitResultKind::Empty) {
    RCUTILS_LOG_WARN_NAMED(
      "rclcpp",
      "empty wait set received in wait(). This should never happen.");
  } else {
    if (this->wait_result_->kind() == WaitResultKind::Ready && current_notify_waitable_) {
      auto & rcl_wait_set = this->wait_result_->get_wait_set().get_rcl_wait_set();
      if (current_notify_waitable_->is_ready(rcl_wait_set)) {
        current_notify_waitable_->execute(current_notify_waitable_->take_data());
      }
    }
  }
}
```

> **IMPLEMENTATION NOTE for the executor (read before writing the helper):** `rclcpp::WaitResult` does not currently expose a public API to *inject* an externally-held ready entity into a fresh `WaitResult`. This is the crux of PR #2702 step 4 and the part the maintainer called "awkward." Before writing `readd_blocked_entities_from_previous_result`, **spike** the available surface of `rclcpp::WaitResult` / `rclcpp::WaitSet` (`rclcpp/wait_result.hpp`, `wait_set_template.hpp`): determine whether blocked entities can be retained by (a) holding their `WaitResult` and consulting it as a *secondary* source in `get_next_ready_executable`, rather than physically merging into `wait_result_`. Option (a) avoids mutating `WaitResult` internals and is the recommended path. If (a) is taken, the helper becomes a no-op and the real change is in `get_next_ready_executable` (Task 2.3). **Pause and report the spike result before implementing** — this determines whether Task 2.2 or Task 2.3 carries the logic.

- [ ] **Step 3: Implement the helper per the spike decision**

If the spike chose option (a) (consult previous result as secondary source), implement:

```cpp
void
Executor::readd_blocked_entities_from_previous_result()
{
  // Option (a): we do not mutate the fresh wait_result_. Instead we keep
  // previous_wait_result_ alive; get_next_ready_executable consults it for
  // still-blocked entities. Drop it only if it no longer holds blocked work.
  if (!previous_wait_result_.has_value()) {
    return;
  }
  // If nothing in the previous result is still blocked, release it.
  // (Concrete predicate filled in during 2.3 once the iteration API is fixed.)
}
```

(The substantive consultation logic lands in Task 2.3. This task's deliverable is the retention plumbing + the spike conclusion.)

- [ ] **Step 4: Hold `notify_mutex_` across the poll in `get_next_executable`**

Replace `get_next_executable` body with:

```cpp
bool
Executor::get_next_executable(AnyExecutable & any_executable, std::chrono::nanoseconds timeout)
{
  bool success = false;
  success = get_next_ready_executable(any_executable);
  if (!success) {
    {
      // Hold notify_mutex_ so a thread finishing a callback cannot reset a
      // group flag + trigger the guard condition mid-poll (the race the
      // second mutex closes).
      std::lock_guard<std::mutex> notify_lock{notify_mutex_};
      wait_for_work(timeout);
    }
    if (!spinning.load()) {
      return false;
    }
    success = get_next_ready_executable(any_executable);
  }
  return success;
}
```

- [ ] **Step 5: Build — expect compile success**

Run: `make rolling-build`. Expected: compiles. Starvation test may still fail until 2.3.

- [ ] **Step 6: Commit**

```bash
git add rclcpp/include/rclcpp/executor.hpp rclcpp/src/rclcpp/executor.cpp
git commit -m "fix(executor): retain previous wait result to persist blocked entities

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.3: Consult retained blocked entities in `get_next_ready_executable`

**Files:**
- Modify: `rclcpp/src/rclcpp/executor.cpp` — `get_next_ready_executable`.

**Interfaces:**
- Consumes: `previous_wait_result_` (Task 2.2), `current_collection_`.
- Produces: a `get_next_ready_executable` that, after exhausting the fresh `wait_result_`, also offers any still-ready, now-unblocked entity from `previous_wait_result_`, and avoids busy-waiting on entities that are still blocked.

- [ ] **Step 1: Implement the consultation + busy-wait avoidance**

Per the spike: after the existing scan of `wait_result_` finds nothing selectable, scan `previous_wait_result_` for entities whose group is now `can_be_taken_from()==true`. Crucially, when a previously-blocked entity is *still* blocked, it must NOT cause the wait loop to spin: `wait_for_work`'s `wait_set_.wait()` only waits on the fresh wait set (which excludes the still-blocked entities), so the retained ones do not self-trigger. Add the secondary scan at the end of `get_next_ready_executable`, before the `can_be_taken_from().store(false)` block:

```cpp
  // Secondary source: entities retained from the previous poll that were
  // blocked then and are now runnable. This prevents starvation of
  // lower-priority callbacks in a mutually-exclusive group.
  if (!valid_executable && previous_wait_result_.has_value() &&
      previous_wait_result_->kind() == rclcpp::WaitResultKind::Ready)
  {
    valid_executable = try_select_unblocked_from_result(
      *previous_wait_result_, any_executable);
    if (previous_result_has_no_blocked_entities(*previous_wait_result_)) {
      previous_wait_result_.reset();
    }
  }
```

Where `try_select_unblocked_from_result` mirrors the existing per-entity-kind scan (timers/subscriptions/services/clients/waitables) but only accepts entities whose `callback_group->can_be_taken_from()` is now true, and `previous_result_has_no_blocked_entities` returns true when none of the retained entities map to a still-blocked group. **Implement both as file-local static helpers** in `executor.cpp` (not public API), reusing the existing `current_collection_` lookups. (Exact bodies depend on the spike's chosen `WaitResult` iteration surface; the reviewer should confirm they reuse, not duplicate, the existing scan logic.)

- [ ] **Step 2: Build and run the starvation test — expect PASS**

Run: `make rolling-test` (filter `starvation_mutually_exclusive_timers`).
Expected: **PASS** — both counts > 0 and within 2 of each other.

- [ ] **Step 3: Run the EventsCBG twin + the existing `timer_over_take` test — expect PASS**

Run: `make rolling-test` (no filter, whole `test_multi_threaded_executor`).
Expected: all tests PASS (no regression in `timer_over_take`).

- [ ] **Step 4: Commit**

```bash
git add rclcpp/src/rclcpp/executor.cpp
git commit -m "fix(executor): select now-unblocked retained entities; starvation test passes

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2.4: Full rclcpp suite + linters on Rolling

**Files:** none (validation only).

- [ ] **Step 1: Run the whole rclcpp test suite**

Run:
```bash
$(COMPOSE) run --rm rolling bash -lc 'source /opt/ros/rolling/setup.bash && \
  cd /ws && colcon test --packages-select rclcpp && colcon test-result --verbose'
```
Expected: no new failures vs. an unfixed baseline. **If any executor test regresses, STOP and debug before proceeding** (use systematic-debugging).

- [ ] **Step 2: Run linters**

Run the `ament_uncrustify`, `ament_cpplint`, `ament_cppcheck` targets (they run as part of `colcon test`; confirm the new code passes). Fix style inline.

- [ ] **Step 3: Commit any lint fixes**

```bash
git commit -am "style: lint fixes for starvation fix

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Fix the Humble era (`memory_strategy_`) — PRIMARY DELIVERABLE

Develop on `fix/mte-starvation-humble` (off `upstream/humble`). Port the user's existing `rclcpp_humble_multithreaded_executor` `fix` branch logic onto current upstream humble. Key structural differences from Rolling (verified against `upstream/humble`):

- **No `wait_result_` / no C++ `WaitSet` wrapper.** Humble uses raw `rcl_wait_set_t wait_set_` + `memory_strategy_`.
- `wait_for_work` (≈L690) clears handles via `memory_strategy_->clear_handles()`, collects via `collect_entities`, resizes/fills the rcl wait set, `rcl_wait`s, then `memory_strategy_->remove_null_handles(&wait_set_)`. **The clear+refill is where blocked entities are dropped.**
- `can_be_taken_from().store(false)` is set in `get_next_ready_executable_from_map` (≈L897).
- **`can_be_taken_from().store(true)` + `interrupt_guard_condition_.trigger()` are BOTH inside `execute_any_executable` (≈L536-543)** — NOT in `run()`. And `run()` does `any_exec.callback_group.reset()` to stop the destructor re-resetting.

### Task 3.1: Port the deterministic test to Humble

**Files:**
- Modify: `rclcpp/test/rclcpp/executors/test_multi_threaded_executor.cpp` (Humble branch).

- [ ] **Step 1: Cherry-pick / re-apply the `starvation_mutually_exclusive_timers` test** (Task 1.1 Step 2). The `EventsCBGExecutor` twin is `__has_include`-guarded so it compiles to nothing on Humble — verify it's skipped, not errored.
- [ ] **Step 2: Add `TIMEOUT 60`** to the Humble `test_multi_threaded_executor` CMake registration (same as Task 1.1 Step 3).
- [ ] **Step 3: Build + run on UNFIXED humble — expect FAILURE.**
Run: `make humble-test` (analogous target). Expected: starvation test FAILS (red baseline for Humble).
- [ ] **Step 4: Commit.**

### Task 3.2: Add `notify_mutex_` and move flag-reset+trigger out of `execute_any_executable`

**Files:**
- Modify: `rclcpp/include/rclcpp/executor.hpp` (humble) — add `notify_mutex_`.
- Modify: `rclcpp/src/rclcpp/executor.cpp` (humble) — `execute_any_executable`.
- Modify: `rclcpp/src/rclcpp/executors/multi_threaded_executor.cpp` (humble) — `run()`.

**Interfaces:**
- Produces: `notify_mutex_` member; `execute_any_executable` no longer resets the flag/triggers; `run()` does it under `notify_mutex_` (matching the Rolling structure).

- [ ] **Step 1: Add `mutable std::mutex notify_mutex_;`** to `executor.hpp` (humble) next to `mutex_`.
- [ ] **Step 2: Remove the flag-reset + trigger from `execute_any_executable`.** Delete these lines (≈L536-543):
```cpp
  // Reset the callback_group, regardless of type
  any_exec.callback_group->can_be_taken_from().store(true);
  try {
    interrupt_guard_condition_.trigger();
  } catch (const rclcpp::exceptions::RCLError & ex) {
    throw std::runtime_error(
            std::string(
              "Failed to trigger guard condition from execute_any_executable: ") + ex.what());
  }
```
- [ ] **Step 3: Add the guarded block to `multi_threaded_executor.cpp::run()`** after `execute_any_executable(any_exec);`:
```cpp
    if (any_exec.callback_group) {
      std::lock_guard<std::mutex> notify_lock{notify_mutex_};
      any_exec.callback_group->can_be_taken_from().store(true);
      if (any_exec.callback_group->type() == CallbackGroupType::MutuallyExclusive) {
        try {
          interrupt_guard_condition_.trigger();
        } catch (const rclcpp::exceptions::RCLError & ex) {
          throw std::runtime_error(
            std::string("Failed to trigger guard condition on callback group change: ") +
            ex.what());
        }
      }
    }
```
> Note: Humble's `interrupt_guard_condition_` is a value member (`rclcpp::GuardCondition`), so it is `.trigger()` on the object (not `->`). Keep the existing `any_exec.callback_group.reset();` line after this block.
- [ ] **Step 4: Build — expect compile success, starvation test still FAILS** (mutex alone doesn't fix it).

  **Why removing the reset from `execute_any_executable` is safe (verified against `upstream/humble`):** The `SingleThreadedExecutor::spin()` loop lets each `AnyExecutable` go out of scope per iteration, and `AnyExecutable::~AnyExecutable()` (`rclcpp/src/rclcpp/any_executable.cpp:33-34`) already resets `can_be_taken_from().store(true)`. So the single-threaded path is covered by the destructor, not by `execute_any_executable`. The MTE's `run()` calls `any_exec.callback_group.reset()` precisely to *suppress* that destructor reset so it can control timing — which is why the MTE now does the reset itself under `notify_mutex_` (Step 3), keeping the existing `callback_group.reset()` line to avoid a double-reset. Net effect: single-threaded unchanged; MTE reset is now atomic with the trigger. **Sanity-check** by running `test_single_threaded_executor` in this build — expect PASS.
- [ ] **Step 5: Commit.**

### Task 3.3: Persist blocked entities across polls (Humble `memory_strategy_` path)

**Files:**
- Modify: `rclcpp/src/rclcpp/executor.cpp` (humble) — `wait_for_work`, `get_next_executable`.
- Modify: `rclcpp/include/rclcpp/executor.hpp` (humble) — persistence state if needed.

**Interfaces:**
- Consumes: `memory_strategy_`, raw `wait_set_`, `weak_groups_to_nodes_`.
- Produces: a wait path where blocked entities are retained. In the Humble model the natural mechanism is: when `memory_strategy_->remove_null_handles` / collection runs, do **not** drop handles belonging to currently-blocked groups; equivalently, hold the previous ready set and re-offer still-ready entries in `get_next_ready_executable_from_map`.

- [ ] **Step 1: Spike the memory_strategy surface.** Read `rclcpp/strategies/allocator_memory_strategy.hpp` (humble) and `memory_strategy.hpp`. Determine the least-invasive retention point. The user's existing `rclcpp_humble_multithreaded_executor` `fix` branch already solves this — **fetch and read it first**:
```bash
git fetch https://github.com/HarunTeper/rclcpp_humble_multithreaded_executor fix:humble_reference_fix
git show humble_reference_fix --stat
```
Port that branch's approach rather than reinventing. **Report the diff before implementing.**
- [ ] **Step 2: Apply the ported retention logic** to `wait_for_work` / `get_next_ready_executable_from_map`, guarded by `notify_mutex_` in `get_next_executable` (mirror Task 2.2 Step 4).
- [ ] **Step 3: Build + run starvation test — expect PASS.**
- [ ] **Step 4: Run the whole `test_multi_threaded_executor` — expect PASS (no `timer_over_take` regression).**
- [ ] **Step 5: Commit.**

### Task 3.4: Full rclcpp suite + linters on Humble

- [ ] **Step 1: `colcon test --packages-select rclcpp` on humble — no new failures.** (STOP + debug on regression.)
- [ ] **Step 2: Linters pass; fix inline.**
- [ ] **Step 3: Commit.**

---

## Phase 4 — Micro-benchmark: add the fixed-MTE variant (Rolling/Jazzy)

The upstream `benchmark_executor.cpp` already benchmarks `multi_thread_*` and `cbg_executor_*`. Since our fix changes the *behavior* of `MultiThreadedExecutor` itself (not a new class), the existing `multi_thread_*` benchmarks already measure the fixed executor once the fix is compiled in. To compare fixed-vs-unfixed, we benchmark the **same binary** built from `upstream/rolling` (baseline) vs. our `fix/mte-starvation-rolling` (fixed), and diff the JSON.

### Task 4.1: Capture baseline vs. fixed micro-benchmark numbers

**Files:**
- Modify: `docker/run-comparison.sh` (create in Task 5.1; this task defines the benchmark invocation it calls).

- [ ] **Step 1: Build and run the benchmark on the FIXED tree, output JSON**
Run:
```bash
$(COMPOSE) run --rm rolling bash -lc 'source /opt/ros/rolling/setup.bash && cd /ws && \
  colcon build --packages-select rclcpp --cmake-args -DCMAKE_BUILD_TYPE=Release && \
  ./build/rclcpp/test/benchmark/benchmark_executor \
     --benchmark_format=json --benchmark_out=/ws/install/bench_fixed.json'
```
Expected: JSON with timing + heap-allocation counters for `multi_thread_executor_spin_some`, `..._wait_for_work`, `..._wait_for_work_rebuild`, `MultipleCallbackGroups/multi_thread_executor_spin_some`, `CascadedPerformanceTestExecutor/multi_thread_executor_spin`, and the `cbg_executor_*` equivalents.

- [ ] **Step 2: Repeat on a clean `upstream/rolling` checkout (baseline)** — a second worktree or a `git stash`/checkout; output `bench_baseline.json`.
- [ ] **Step 3: Diff** with a small Python snippet (in `docker/run-comparison.sh`) reporting per-benchmark % delta for `real_time` and `allocations`. Expected: MTE deltas within a few % (the paper's "negligible overhead" claim, on the maintainers' own harness).
- [ ] **Step 4: Commit the harness + recorded numbers** (store JSONs under `docker/results/`).

---

## Phase 5 — Comparison harness & Autoware macro-benchmark

### Task 5.1: `run-comparison.sh` — the 3-way table

**Files:**
- Create: `docker/run-comparison.sh`
- Create: `docker/results/.gitkeep`

**Interfaces:**
- Produces: a script that runs, on a given distro container: the starvation test (MTE-unfixed via baseline image, MTE-fixed, EventsCBGExecutor) and the micro-benchmark, emitting `docker/results/comparison-<distro>.md` with columns {starvation-free?, spin_some real_time, allocations, cascaded latency}.

- [ ] **Step 1: Write the script** orchestrating: (a) build baseline + fixed, (b) run `test_multi_threaded_executor` filtered to the starvation tests on each, (c) run benchmark JSON on each, (d) render a markdown table. Use only bash + python3 (present in the ROS image).
- [ ] **Step 2: Run it for Rolling**; verify the table shows: unfixed MTE = STARVES, fixed MTE = OK, EventsCBGExecutor = OK; overhead columns populated.
- [ ] **Step 3: Commit script + generated `comparison-rolling.md`.**

### Task 5.2: Autoware Reference System macro-benchmark

**Files:**
- Create: `docker/autoware/Dockerfile` (or extend rolling image) — clone `ros-realtime/reference-system`.
- Create: `docker/autoware/run.sh`

**Interfaces:**
- Produces: latency CSVs per executor (mean/std/99th percentile), matching the paper's Table I, under `docker/results/autoware-<executor>.csv`.

- [ ] **Step 1: Dockerfile** clones `https://github.com/ros-realtime/reference-system`, builds it against our overlaid rclcpp, and exposes its `autoware_reference_system` runner.
- [ ] **Step 2: `run.sh`** runs the reference system with `MultiThreadedExecutor` (fixed), and `EventsCBGExecutor`, for a fixed duration (paper used 10 min ×5; use a shorter smoke duration for iteration, full duration for the final run), collecting latency stats.
- [ ] **Step 3: Run a short smoke run**; confirm CSVs are produced and parseable.
- [ ] **Step 4: Commit Dockerfile + run.sh + smoke results.**

### Task 5.3: Jazzy cherry-pick validation

**Files:** none (validation; produces a throwaway branch).

- [ ] **Step 1: Create `verify/jazzy-cherrypick` off `upstream/jazzy`; cherry-pick the Phase 2 fix commits** (`fix(executor): guard ...`, `fix(executor): retain ...`, `fix(executor): select ...`) and the Phase 1 test commits.
- [ ] **Step 2: Resolve conflicts** (expect light: `multi_threaded_executor.cpp` is near-identical; `executor.cpp` has ~125 lines of drift). Record which hunks needed manual fixup.
- [ ] **Step 3: `make jazzy-test`** — starvation test PASSES, suite green.
- [ ] **Step 4: Document** the cherry-pick result (clean / needed-N-fixups) in `docker/results/jazzy-backport-notes.md`; commit.

---

## Phase 6 — Upstream handoff

### Task 6.1: Update PR #2702 and prepare the Humble PR

**Files:**
- Create: `docs/superpowers/specs/pr-narrative.md` (draft PR descriptions; not pushed to rclcpp).

- [ ] **Step 1: Write the Rolling PR narrative** for #2702: what changed, the deterministic test, the micro-benchmark deltas, the Autoware numbers, and the explicit comparison to EventsCBGExecutor — framing the MTE fix as serving users who cannot switch.
- [ ] **Step 2: Write the Humble PR narrative** leading with "EventsCBGExecutor does not exist on Humble, so this is the only remedy" — the strongest, least-contested case.
- [ ] **Step 3: Re-engage `jmachowinski` / `alsora`** on the PR with running code + numbers (do NOT push to ros2/rclcpp without the user's explicit go-ahead — this is an outward-facing action).
- [ ] **Step 4: Commit the narrative doc.**

---

## Self-Review notes

- **Spec coverage:** Track A (Humble) = Phase 3; Track B (Rolling→Jazzy) = Phase 2 + Task 5.3; comparison = Phase 4 + 5; both benchmarks = Phase 4 (micro) + Task 5.2 (Autoware); Docker = Phase 0; deterministic-test TDD = Phase 1; PR/maintainer re-engagement = Phase 6. All spec sections covered.
- **Known open implementation risk (flagged inline, not hidden):** the `WaitResult` injection surface (Task 2.2 Step 2 note) and the Humble single-threaded reset dependency (Task 3.2 Step 4) are spikes that may redirect the exact code. Each has an explicit STOP-and-report gate rather than a guessed implementation — this is deliberate, because guessing the `WaitResult` internals is exactly what stalled the original PR.
- **Type consistency:** `notify_mutex_`, `previous_wait_result_`, `readd_blocked_entities_from_previous_result`, `can_be_taken_from()` used consistently across tasks. Humble uses `interrupt_guard_condition_.trigger()` (value), Rolling uses `interrupt_guard_condition_->trigger()` (pointer) — called out where it matters.
