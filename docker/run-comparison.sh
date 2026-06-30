#!/usr/bin/env bash
# run-comparison.sh — MTE starvation-fix benchmark & 3-way comparison harness.
#
# Produces, for one distro, the data behind docker/results/comparison-<distro>.md:
#   rows    = {unfixed MTE, fixed MTE, EventsCBGExecutor}
#   columns = {starvation-free?, spin_some real_time, heap allocations,
#              Cascaded / MultipleCallbackGroups latency}
#
# METHODOLOGY
#   The fix changes MultiThreadedExecutor *in place*, so "fixed vs unfixed MTE" =
#   the SAME benchmark binary built from the fix ref vs from pristine upstream.
#     * multi_thread_* rows  -> fixed-MTE  (fix ref)  vs  unfixed-MTE (baseline ref)
#     * cbg_executor_*  rows -> EventsCBGExecutor (present, ~identical, in both refs)
#   The starvation column comes from test_multi_threaded_executor's starvation tests:
#     unfixed MTE STARVES (one timer count 0); fixed MTE OK; EventsCBG OK (twin test).
#
# CONTAINER / MOUNT MODEL
#   docker/compose.yaml bind-mounts the repo ROOT read-only to /ws/src/rclcpp_fork;
#   the rclcpp package is symlinked to /ws/src/pkg/rclcpp at runtime. Because the
#   mount reflects the HOST working tree, "build ref X" = check X out on the host,
#   then build in the container. We therefore checkout-in-place (stashing nothing —
#   the tree must be clean) and restore the starting branch at the end.
#
# USAGE
#   docker/run-comparison.sh <distro> <fixed-ref> <baseline-ref> [bench_repetitions]
#   e.g. docker/run-comparison.sh lyrical fix/mte-starvation-lyrical upstream/lyrical 5
#
# OUTPUTS (under docker/results/)
#   bench_fixed-<distro>.json     micro-benchmark JSON, fix ref
#   bench_baseline-<distro>.json  micro-benchmark JSON, pristine upstream ref
#   starvation-fixed-<distro>.txt / starvation-baseline-<distro>.txt   test logs
#   comparison-<distro>.md        the rendered 3-way table + overhead deltas
#
# This script is intentionally verbose and fail-fast; benchmark validity depends on
# clean rebuilds (see ledger gotcha: stale build/install volumes serve stale results).
set -euo pipefail

DISTRO="${1:?need distro: humble|jazzy|lyrical}"
FIXED_REF="${2:?need fixed git ref}"
BASELINE_REF="${3:?need baseline git ref}"
REPS="${4:-5}"

cd "$(git rev-parse --show-toplevel)"
REPO_ROOT="$(pwd)"
RESULTS="${REPO_ROOT}/docker/results"
mkdir -p "$RESULTS"
COMPOSE="docker compose -f docker/compose.yaml"

# --- safety: no TRACKED modifications -----------------------------------------
# We swap ONLY the rclcpp/ source tree between refs (pathspec checkout), leaving
# docker/ scaffolding + .superpowers/ ledger on the current branch the whole time.
# (The docker/ compose+Dockerfiles and the ledger live ONLY on the fix branches,
# NOT on pristine upstream — a full `git checkout upstream/X` would delete them and
# break `docker compose -f docker/compose.yaml`. Pathspec checkout of rclcpp/ avoids
# that: the container only builds rclcpp/ anyway.)
# Untracked files OUTSIDE rclcpp/ (like this harness) survive checkouts, so we don't
# block on them. But ANY entry under rclcpp/ — tracked modification OR untracked
# non-ignored file — is a problem: checkout_rclcpp() runs `git clean -qfd rclcpp`,
# which DELETES untracked files there with no warning (data loss). `git status
# --porcelain -- rclcpp` lists both, while respecting .gitignore (build dirs etc.
# are not flagged) — exactly the scope we must reject.
if [ -n "$(git status --porcelain -- rclcpp)" ]; then
  echo "ERROR: uncommitted changes under rclcpp/ (tracked or untracked). The harness swaps and"
  echo "       'git clean -qfd rclcpp's the rclcpp/ tree between refs, which would DELETE them."
  echo "       Commit/stash/remove them first." >&2
  git status --porcelain -- rclcpp >&2
  exit 1
fi
START_REF="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
echo ">>> starting branch/ref: ${START_REF}"
# Swap just the rclcpp/ tree to a given ref. Pathspec checkout stages the change
# (fine mid-run). CRUCIAL: a pathspec checkout updates/adds tracked files but does NOT
# delete files that the new ref lacks — so files that exist on the OLD ref but not the
# new one are left behind as untracked leftovers (e.g. swapping lyrical->jazzy leaves
# lyrical-only generic_service.* polluting the tree). Clean them, scoped to rclcpp/ ONLY
# (never touches docker/, .superpowers/, or this harness).
checkout_rclcpp() {
  git checkout --quiet "$1" -- rclcpp
  git clean -qfd rclcpp           # remove leftovers from the previously-checked-out ref
}

# The starvation test (and its TIMEOUT-60 CMake line) was ADDED by the fix branch, so
# pristine upstream has no starvation test at all (only timer_over_take). To prove the
# UNFIXED executor starves, overlay just those two TEST-ONLY files (black-box: they call
# only public spin/add APIs, no fix-only symbols) from the fix ref onto the baseline tree.
# The executor stays unfixed; the benchmark file stays at baseline. Result: a genuine
# "unfixed executor + starvation test" build.
# We overlay ONLY the test .cpp (not the test-dir CMakeLists): the
# test_multi_threaded_executor target already exists in upstream (it holds
# timer_over_take), so adding the starvation cases to the .cpp is sufficient. The
# fix branch's only CMake change there was a cosmetic `TIMEOUT 60` — not needed
# (the test runs in ~6s). Avoiding the CMakeLists overlay sidesteps any other drift.
TEST_CPP="rclcpp/test/rclcpp/executors/test_multi_threaded_executor.cpp"
overlay_starvation_test_from() {
  git checkout --quiet "$1" -- "$TEST_CPP"
  echo ">>> overlaid starvation test .cpp from $1 onto the current (unfixed) executor"
}
restore() {
  echo ">>> restoring rclcpp/ to ${START_REF}"
  git checkout --quiet "$START_REF" -- rclcpp || true
  git reset --quiet -- rclcpp || true   # clear the index entries the pathspec checkout staged
  git clean -qfd rclcpp || true          # remove any leftover files from swapped-in refs
}
trap restore EXIT

# In-container command: clean Release build of just the benchmark target's deps,
# then run benchmark_executor -> JSON, then run the starvation tests -> log.
# The source mount is :ro, so the benchmark JSON is captured via the compose `run`
# stdout redirection on the host (see the `> "${RESULTS}/..."` below) rather than
# written inside the container.
build_and_measure() {
  local label="$1"   # "fixed" | "baseline"
  echo ""
  echo "============================================================"
  echo ">>> [$DISTRO/$label] clean Release build + benchmark + starvation test"
  echo "============================================================"
  # Force a clean configure so a stale CMake cache can't serve stale results.
  $COMPOSE run --rm "$DISTRO" bash -lc "
    set -e
    mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp
    source /opt/ros/$DISTRO/setup.bash
    # /ws/build and /ws/install are Docker named-volume mountpoints — we can't rm the
    # mountpoint itself ('Device or resource busy'), only its contents. Clear contents
    # so each ref builds from a clean configure (stale CMake cache once served stale results).
    mkdir -p /ws/build /ws/install
    find /ws/build /ws/install -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    colcon build --packages-select rclcpp \
      --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON \
      --event-handlers console_direct+ > /ws/build_${label}.log 2>&1 || \
      { echo '=== BUILD FAILED, tail: ==='; tail -40 /ws/build_${label}.log; exit 1; }
    echo '=== build OK ==='
    source /ws/install/setup.bash
    BENCH=/ws/build/rclcpp/test/benchmark/benchmark_executor
    test -x \$BENCH || { echo \"benchmark binary missing: \$BENCH\"; exit 1; }
    # performance_test_fixture's heap-allocation counters only populate when the
    # osrf_testing_tools_cpp memory-tools interposer is LD_PRELOAD'ed (the header says so:
    # 'memory tools may not be working if LD_PRELOAD was not used'). Without it the JSON
    # carries timing only and NO alloc counters. Preload it so 'heap allocations' (the
    # paper's load-immune overhead metric) is captured.
    INTERPOSE=\$(find /opt/ros/$DISTRO/lib -name 'libmemory_tools_interpose.so' 2>/dev/null | head -1)
    if [ -n \"\$INTERPOSE\" ]; then
      echo \"=== LD_PRELOAD interposer: \$INTERPOSE ===\" >&2
    else
      echo '=== WARN: libmemory_tools_interpose.so not found — allocations will be absent ===' >&2
    fi
    LD_PRELOAD=\"\$INTERPOSE\" \$BENCH --benchmark_repetitions=${REPS} \
           --benchmark_report_aggregates_only=true --benchmark_format=json 2>/dev/null
  " > "${RESULTS}/bench_${label}-${DISTRO}.json.raw"
  # The build chatter precedes the JSON; slice from the first '{' to EOF.
  python3 - "$RESULTS" "$label" "$DISTRO" <<'PY'
import sys, pathlib
results, label, distro = sys.argv[1], sys.argv[2], sys.argv[3]
raw = pathlib.Path(results, f"bench_{label}-{distro}.json.raw").read_text()
i = raw.find("{")
if i < 0:
    sys.stderr.write(f"no JSON object found in bench_{label}-{distro}.json.raw\n")
    sys.exit(1)
pathlib.Path(results, f"bench_{label}-{distro}.json").write_text(raw[i:])
print(f"  wrote bench_{label}-{distro}.json")
PY

  echo ">>> [$DISTRO/$label] running starvation tests"
  $COMPOSE run --rm "$DISTRO" bash -lc "
    set -e
    mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp
    source /opt/ros/$DISTRO/setup.bash
    source /ws/install/setup.bash
    TEST=/ws/build/rclcpp/test/rclcpp/test_multi_threaded_executor
    test -x \$TEST || { echo \"test binary missing: \$TEST\"; exit 1; }
    \$TEST --gtest_filter='*starvation*:*timer_over_take*' 2>&1 || true
  " > "${RESULTS}/starvation-${label}-${DISTRO}.txt" 2>&1 || true
  echo "  wrote starvation-${label}-${DISTRO}.txt"
}

# --- build + measure BASELINE (pristine upstream) ----------------------------
echo ">>> swapping rclcpp/ to BASELINE ref: ${BASELINE_REF}"
checkout_rclcpp "$BASELINE_REF"
# Overlay the starvation test .cpp from the fix ref so the UNFIXED executor is
# exercised by it (proves the bug). The benchmark .cpp stays at baseline.
overlay_starvation_test_from "$FIXED_REF"
build_and_measure baseline

# --- build + measure FIXED ---------------------------------------------------
echo ">>> swapping rclcpp/ to FIXED ref: ${FIXED_REF}"
checkout_rclcpp "$FIXED_REF"
build_and_measure fixed

# trap restores START_REF on exit

# --- render the comparison table ---------------------------------------------
echo ""
echo ">>> rendering comparison-${DISTRO}.md"
python3 "${REPO_ROOT}/docker/render-comparison.py" "$DISTRO" "$RESULTS" "$FIXED_REF" "$BASELINE_REF" "$REPS"
echo ">>> DONE. See docker/results/comparison-${DISTRO}.md"
