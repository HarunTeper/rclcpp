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

# ROS setup.bash files reference unbound vars (e.g. AMENT_TRACE_SETUP_FILES) and are
# NOT `set -u`-clean, so sourcing them under `set -euo pipefail` aborts. Source with
# nounset temporarily disabled (the standard ROS-in-strict-bash workaround).
safe_source() { set +u; source "$1"; set -u; }

echo "=== [autoware/$DISTRO] step 1: clone reference-system (if absent) ==="
if [[ ! -d "$REF_SRC/.git" ]]; then
  git clone --depth 1 https://github.com/ros-realtime/reference-system "$REF_SRC"
fi

echo "=== step 2: inject EventsCBGExecutor variant (idempotent) ==="
EXE_DIR="$REF_SRC/autoware_reference_system/src/ros2/executor"
cp -f /ws/src/rclcpp_fork/docker/autoware/autoware_default_events.cpp "$EXE_DIR/autoware_default_events.cpp"
CMAKE="$REF_SRC/autoware_reference_system/CMakeLists.txt"
# CRITICAL: add_benchmark_executable() only registers the target for auto-install via
# ament_auto_package(), which is the LAST line of the CMakeLists and installs only what
# was registered BEFORE it. Appending our line to the END of the file compiles the binary
# but registers it too late -> it lands in /ws/build but never /ws/install. So we must
# INSERT the registration BEFORE the ament_auto_package(...) call, not append it.
if ! grep -q 'autoware_default_events' "$CMAKE"; then
  python3 - "$CMAKE" <<'PY'
import sys, re
path = sys.argv[1]
text = path_text = open(path).read()
inject = (
    "# --- Added for MTE-starvation-fix comparison: EventsCBGExecutor variant ---\n"
    "add_benchmark_executable(autoware_default_events\n"
    "  src/ros2/executor/autoware_default_events.cpp)\n\n"
)
m = re.search(r'^\s*ament_auto_package\s*\(', text, re.M)
if not m:
    sys.stderr.write("ERROR: ament_auto_package( not found in CMakeLists — cannot inject\n")
    sys.exit(1)
text = text[:m.start()] + inject + text[m.start():]
open(path, "w").write(text)
print("  injected add_benchmark_executable(autoware_default_events) before ament_auto_package()")
PY
else
  echo "  already injected"
fi

# step 2b: drop reference-system executor variants whose executor class no longer exists
# in the target rclcpp, else autoware_reference_system fails to COMPILE. Lyrical (rclcpp
# 32.0.0) removed StaticSingleThreadedExecutor; jazzy still has it. We only need
# multithreaded (fixed MTE) + events (EventsCBG) + singlethreaded (baseline) anyway.
# Comment out an add_benchmark_executable(<target> ...) call if its source references a
# class absent from the installed rclcpp headers.
drop_variant_if_class_missing() {
  local target="$1" cls="$2"
  # Authoritative check: the system rclcpp headers for this distro. Our fix changes MTE
  # internals only, never adds/removes executor classes, so the distro headers tell us
  # whether <cls> exists (e.g. StaticSingleThreadedExecutor: present on jazzy, gone on lyrical).
  if ! grep -rqs "${cls}" /opt/ros/$DISTRO/include/ 2>/dev/null; then
    # class not found in target rclcpp -> comment out the registration (2-line call)
    python3 - "$CMAKE" "$target" <<'PY'
import sys, re
path, target = sys.argv[1], sys.argv[2]
text = open(path).read()
# match: add_benchmark_executable(<target>\n  <src>) possibly spanning 2 lines
pat = re.compile(r'(?m)^[ \t]*add_benchmark_executable\(\s*' + re.escape(target) + r'\b[^)]*\)')
new, n = pat.subn(lambda mm: '# [MTE-bench] disabled (executor class missing in this rclcpp):\n# ' +
                  mm.group(0).replace('\n', '\n# '), text)
if n:
    open(path, 'w').write(new)
    print(f"  disabled add_benchmark_executable({target}) — class not in target rclcpp")
else:
    print(f"  (no add_benchmark_executable({target}) to disable)")
PY
  fi
}
drop_variant_if_class_missing autoware_default_staticsinglethreaded StaticSingleThreadedExecutor

echo "=== step 3: link our fixed rclcpp into the workspace ==="
mkdir -p /ws/src/pkg
ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp

echo "=== step 4: build rclcpp (Release) + reference-system overlay ==="
safe_source "/opt/ros/$DISTRO/setup.bash"
# Build our rclcpp first so the reference-system links against the FIXED executor.
colcon build --packages-select rclcpp \
  --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  > /ws/build_rclcpp.log 2>&1 || { echo "rclcpp build FAILED:"; tail -40 /ws/build_rclcpp.log; exit 1; }
safe_source /ws/install/setup.bash
# BUILD_TESTING=OFF: the reference_system package's unit tests call
# ament_target_dependencies() inside its if(BUILD_TESTING) block, which is not available
# on newer ament (lyrical/Ubuntu 26.04) without an explicit find_package(ament_cmake) the
# upstream package omits -> "Unknown CMake command ament_target_dependencies". We only need
# the autoware_default_* BENCHMARK executables (built outside the testing block), not the
# package's own unit tests, so disabling tests is the correct fix (not a workaround) and
# also speeds the build. Verified the benchmark executables still build with tests off.
colcon build --packages-up-to autoware_reference_system \
  --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  > /ws/build_refsys.log 2>&1 || { echo "reference-system build FAILED:"; tail -60 /ws/build_refsys.log; exit 1; }
safe_source /ws/install/setup.bash
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
