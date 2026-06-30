#!/usr/bin/env bash
# run-autoware-unfixed.sh - run the UNFIXED MTE on the Autoware macro workload, for the
# fixed-vs-unfixed performance comparison. Mirrors run-autoware-lyrical.sh but swaps the
# host rclcpp/ to the PRISTINE UPSTREAM ref (so autoware_default_multithreaded links the
# unfixed executor) and runs ONLY that one executable.
#
# Usage: docker/run-autoware-unfixed.sh <distro> <duration_sec> <runs>
#   docker/run-autoware-unfixed.sh jazzy 600 1
#   docker/run-autoware-unfixed.sh lyrical 600 1
#
# Output: docker/results/autoware-latency-<distro>-unfixed.csv (one row, the unfixed MTE).
set -euo pipefail

DISTRO="${1:?need distro: jazzy|lyrical}"
DURATION="${2:?need duration seconds}"
RUNS="${3:?need number of runs}"
UPSTREAM_REF="upstream/${DISTRO}"

# jazzy uses the "autoware" compose service, lyrical uses "autoware-lyrical".
case "$DISTRO" in
  jazzy)   SVC="autoware" ;;
  lyrical) SVC="autoware-lyrical" ;;
  *) echo "ERROR: unsupported distro '$DISTRO' (jazzy|lyrical only)" >&2; exit 1 ;;
esac

cd "$(git rev-parse --show-toplevel)"
REPO_ROOT="$(pwd)"
RESULTS="${REPO_ROOT}/docker/results"
COMPOSE="docker compose -f docker/compose.yaml"
mkdir -p "$RESULTS"

if [ -n "$(git status --porcelain -- rclcpp)" ]; then
  echo "ERROR: uncommitted changes under rclcpp/. Commit/stash first (we swap rclcpp/ to upstream)." >&2
  git status --porcelain -- rclcpp >&2; exit 1
fi
START_REF="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
echo ">>> starting ref: ${START_REF}; swapping rclcpp/ -> ${UPSTREAM_REF} (UNFIXED) for ${DISTRO}"
restore() {
  echo ">>> restoring rclcpp/ to ${START_REF}"
  git checkout --quiet "$START_REF" -- rclcpp || true
  git reset --quiet -- rclcpp || true
  git clean -qfd rclcpp || true
}
trap restore EXIT

git checkout --quiet "$UPSTREAM_REF" -- rclcpp
git clean -qfd rclcpp

echo ">>> building ${SVC} image + running UNFIXED MTE only (duration=${DURATION}s runs=${RUNS})"
$COMPOSE build "$SVC"
# Clean volumes so the pristine rclcpp configures fresh; run ONLY autoware_default_multithreaded.
$COMPOSE run --rm "$SVC" bash -lc "
  mkdir -p /ws/build /ws/install
  find /ws/build /ws/install -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  bash /ws/src/rclcpp_fork/docker/autoware/run.sh ${DURATION} ${RUNS} autoware_default_multithreaded
" | tee "${RESULTS}/autoware-unfixed-${DISTRO}.log"

# Extract the CSV block and relabel the executor as the UNFIXED MTE for clarity.
awk '/^distro,executor,run/{p=1} p' "${RESULTS}/autoware-unfixed-${DISTRO}.log" \
  | grep -E "^(distro|${DISTRO})" \
  | sed "s/${DISTRO},autoware_default_multithreaded,/${DISTRO},MTE_unfixed,/" \
  > "${RESULTS}/autoware-latency-${DISTRO}-unfixed.csv" || true
echo ">>> wrote ${RESULTS}/autoware-latency-${DISTRO}-unfixed.csv:"
cat "${RESULTS}/autoware-latency-${DISTRO}-unfixed.csv"
