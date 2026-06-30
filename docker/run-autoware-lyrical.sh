#!/usr/bin/env bash
# run-autoware-lyrical.sh — orchestrate the lyrical Autoware macro-benchmark from the host.
#
# run.sh (inside the container) builds the BIND-MOUNTED rclcpp, which reflects the HOST
# working tree. To benchmark the FIXED LYRICAL rclcpp, the host's rclcpp/ must be on
# fix/mte-starvation-lyrical during the run. This script swaps it (pathspec checkout,
# same discipline as run-comparison.sh), runs the smoke/full benchmark in the
# autoware-lyrical container, captures the latency CSV to docker/results/, then restores.
#
# Usage: docker/run-autoware-lyrical.sh <duration_sec> <runs>
#   smoke: run-autoware-lyrical.sh 5 1
#   paper: run-autoware-lyrical.sh 600 5
set -euo pipefail

DURATION="${1:?need duration seconds}"
RUNS="${2:?need number of runs}"
FIXED_REF="fix/mte-starvation-lyrical"

cd "$(git rev-parse --show-toplevel)"
REPO_ROOT="$(pwd)"
RESULTS="${REPO_ROOT}/docker/results"
COMPOSE="docker compose -f docker/compose.yaml"
mkdir -p "$RESULTS"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: tracked changes present. Commit/stash first (we swap rclcpp/ to lyrical)." >&2
  git status --short >&2; exit 1
fi
START_REF="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
echo ">>> starting ref: ${START_REF}; swapping rclcpp/ -> ${FIXED_REF}"
restore() {
  echo ">>> restoring rclcpp/ to ${START_REF}"
  git checkout --quiet "$START_REF" -- rclcpp || true
  git reset --quiet -- rclcpp || true
  git clean -qfd rclcpp || true
}
trap restore EXIT

git checkout --quiet "$FIXED_REF" -- rclcpp
git clean -qfd rclcpp

echo ">>> building lyrical autoware image + running (duration=${DURATION}s runs=${RUNS})"
$COMPOSE build autoware-lyrical
# Clear the lyrical autoware volumes for a clean configure, then run; tee the CSV out
# (run.sh cats it to stdout at the end — the source mount is :ro so we capture via stdout).
$COMPOSE run --rm autoware-lyrical bash -lc "
  mkdir -p /ws/build /ws/install
  find /ws/build /ws/install -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  bash /ws/src/rclcpp_fork/docker/autoware/run.sh ${DURATION} ${RUNS}
" | tee "${RESULTS}/autoware-smoke-lyrical.log"

# Extract the CSV block (printed after the "CSV follows" marker) to a host file.
awk '/^distro,executor,run/{p=1} p' "${RESULTS}/autoware-smoke-lyrical.log" \
  | grep -E '^(distro|lyrical)' > "${RESULTS}/autoware-latency-lyrical.csv" || true
echo ">>> wrote ${RESULTS}/autoware-latency-lyrical.csv:"
cat "${RESULTS}/autoware-latency-lyrical.csv"
