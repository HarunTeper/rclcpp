#!/usr/bin/env bash
# docker/autoware/run.sh — runs INSIDE the autoware container.
#
# Builds our fixed rclcpp + the ros-realtime/reference-system autoware_reference_system
# (with an added EventsCBGExecutor variant), then runs the reference workload for the
# requested executors and duration, and extracts a latency CSV (the paper's hot-path KPI).
#
# Usage (inside container):
#   /ws/src/rclcpp_fork/docker/autoware/run.sh <duration_sec> <runs> [exe_glob]
#   e.g.  run.sh 5 1                  # smoke: 5s, 1 run, default exes
#         run.sh 600 5               # paper: 10 min x 5
#         run.sh 600 5 'autoware_default_multithreaded,autoware_default_events'
#
# Outputs (written under /ws/install/autoware-results/, copy out via the bind so the
# host sees them — but the source mount is :ro, so results go to a writable volume path
# and the caller docker-cp's them, OR we print the CSV to stdout for host capture).
set -euo pipefail

DURATION="${1:?need duration seconds}"
RUNS="${2:?need number of runs}"
EXE_GLOB="${3:-autoware_default_multithreaded,autoware_default_events,autoware_default_singlethreaded}"
DISTRO="${ROS_DISTRO:?ROS_DISTRO must be set in the container}"

REF_SRC=/ws/src/reference-system
RESULTS=/ws/install/autoware-results
mkdir -p "$RESULTS"

echo "=== [autoware/$DISTRO] step 1: clone reference-system (if absent) ==="
if [[ ! -d "$REF_SRC/.git" ]]; then
  git clone --depth 1 https://github.com/ros-realtime/reference-system "$REF_SRC"
fi

echo "=== step 2: inject EventsCBGExecutor variant (idempotent) ==="
EXE_DIR="$REF_SRC/autoware_reference_system/src/ros2/executor"
cp -f /ws/src/rclcpp_fork/docker/autoware/autoware_default_events.cpp "$EXE_DIR/autoware_default_events.cpp"
CMAKE="$REF_SRC/autoware_reference_system/CMakeLists.txt"
if ! grep -q 'autoware_default_events' "$CMAKE"; then
  cat >> "$CMAKE" <<'EOF'

# --- Added for MTE-starvation-fix comparison: EventsCBGExecutor variant ---
add_benchmark_executable(autoware_default_events
  src/ros2/executor/autoware_default_events.cpp)
EOF
  echo "  injected add_benchmark_executable(autoware_default_events)"
else
  echo "  already injected"
fi

echo "=== step 3: link our fixed rclcpp into the workspace ==="
mkdir -p /ws/src/pkg
ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp

echo "=== step 4: build rclcpp (Release) + reference-system overlay ==="
source "/opt/ros/$DISTRO/setup.bash"
# Build our rclcpp first so the reference-system links against the FIXED executor.
colcon build --packages-select rclcpp \
  --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  > /ws/build_rclcpp.log 2>&1 || { echo "rclcpp build FAILED:"; tail -40 /ws/build_rclcpp.log; exit 1; }
source /ws/install/setup.bash
colcon build --packages-up-to autoware_reference_system \
  --cmake-args -DCMAKE_BUILD_TYPE=Release \
  > /ws/build_refsys.log 2>&1 || { echo "reference-system build FAILED:"; tail -60 /ws/build_refsys.log; exit 1; }
source /ws/install/setup.bash
echo "  build OK"

# Sanity: the events executable must exist (proves EventsCBGExecutor compiled+linked).
EVENTS_EXE="$(find /ws/install -name autoware_default_events -type f | head -1 || true)"
if [[ -z "$EVENTS_EXE" ]]; then
  echo "ERROR: autoware_default_events not built — EventsCBGExecutor link failed?"; exit 1
fi
echo "  events executable: $EVENTS_EXE"

echo "=== step 5: run benchmark — duration=${DURATION}s runs=${RUNS} exes='${EXE_GLOB}' ==="
BENCH_PY="$(ros2 pkg prefix --share autoware_reference_system)/scripts/benchmark.py"
for ((r=1; r<=RUNS; r++)); do
  RUNDIR="$RESULTS/run_${r}"
  mkdir -p "$RUNDIR"
  echo "  --- run $r/$RUNS -> $RUNDIR ---"
  # std trace only (latency via parsed stdout); single rmw for determinism.
  python3 "$BENCH_PY" "$DURATION" "$EXE_GLOB" \
    --trace_types std --rmws rmw_cyclonedds_cpp --logdir "$RUNDIR" \
    > "$RUNDIR/benchmark_py.log" 2>&1 || echo "  (benchmark.py returned nonzero — check $RUNDIR/benchmark_py.log)"
done

echo "=== step 6: extract latency CSV from std_output.log files ==="
python3 /ws/src/rclcpp_fork/docker/autoware/parse-autoware.py "$RESULTS" "$DURATION" "$DISTRO" \
  > "$RESULTS/autoware-latency-${DISTRO}.csv"
echo "  wrote $RESULTS/autoware-latency-${DISTRO}.csv"
echo "=== DONE. CSV follows (also at $RESULTS/autoware-latency-${DISTRO}.csv): ==="
cat "$RESULTS/autoware-latency-${DISTRO}.csv"
