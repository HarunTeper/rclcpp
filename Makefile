COMPOSE = docker compose -f docker/compose.yaml

# Benchmark phase (Phase 4-5) knobs:
#   BENCH_REPS   google-benchmark repetitions for run-comparison.sh (default 5)
#   AW_DURATION  autoware per-run duration seconds (smoke=5, paper=600)
#   AW_RUNS      autoware repetitions (paper=5)
BENCH_REPS  ?= 5
AW_DURATION ?= 5
AW_RUNS     ?= 1

.PHONY: lyrical-build lyrical-shell humble-build humble-shell jazzy-build jazzy-shell jazzy-test \
        compare-lyrical compare-jazzy autoware-build autoware-smoke autoware-shell
lyrical-build:
	$(COMPOSE) build lyrical
	$(COMPOSE) run --rm lyrical bash -lc '\
	  mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp && \
	  source /opt/ros/lyrical/setup.bash && \
	  colcon build --packages-select rclcpp --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo'

lyrical-shell:
	$(COMPOSE) run --rm lyrical bash

humble-build:
	$(COMPOSE) build humble
	$(COMPOSE) run --rm humble bash -lc '\
	  mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp && \
	  source /opt/ros/humble/setup.bash && \
	  colcon build --packages-select rclcpp --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo'

humble-shell:
	$(COMPOSE) run --rm humble bash

jazzy-build:
	$(COMPOSE) build jazzy
	$(COMPOSE) run --rm jazzy bash -lc '\
	  mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp && \
	  source /opt/ros/jazzy/setup.bash && \
	  colcon build --packages-select rclcpp --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo'

jazzy-shell:
	$(COMPOSE) run --rm jazzy bash

jazzy-test:
	$(COMPOSE) run --rm jazzy bash -lc '\
	  mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp && \
	  source /opt/ros/jazzy/setup.bash && \
	  colcon build --packages-select rclcpp --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo && \
	  colcon test --packages-select rclcpp --ctest-args -R test_multi_threaded_executor && \
	  colcon test-result --verbose'

# --- Phase 4-5 micro-benchmark + 3-way comparison -----------------------------
# Builds the benchmark from the pristine upstream ref and the fix ref, runs the
# micro-benchmark + starvation tests on each, renders docker/results/comparison-<distro>.md.
# Requires a clean working tree (the harness swaps rclcpp/ between refs).
compare-lyrical:
	bash docker/run-comparison.sh lyrical fix/mte-starvation-lyrical upstream/lyrical $(BENCH_REPS)

compare-jazzy:
	bash docker/run-comparison.sh jazzy fix/mte-starvation-jazzy upstream/jazzy $(BENCH_REPS)

# --- Phase 5.2 Autoware reference-system macro-benchmark ----------------------
autoware-build:
	$(COMPOSE) build autoware

# Capture the jazzy latency CSV to the host (run.sh cats it to stdout; the source mount
# is :ro so we tee the container stdout to a log and awk the CSV block out — same pattern
# as docker/run-autoware-lyrical.sh. Makes autoware-latency-jazzy.csv reproducible via make.)
autoware-smoke: autoware-build
	mkdir -p docker/results
	$(COMPOSE) run --rm autoware bash -lc '\
	  bash /ws/src/rclcpp_fork/docker/autoware/run.sh $(AW_DURATION) $(AW_RUNS)' \
	  | tee docker/results/autoware-smoke-jazzy.log
	awk '/^distro,executor,run/{p=1} p' docker/results/autoware-smoke-jazzy.log \
	  | grep -E '^(distro|jazzy)' > docker/results/autoware-latency-jazzy.csv || true
	@echo "wrote docker/results/autoware-latency-jazzy.csv"

autoware-shell:
	$(COMPOSE) run --rm autoware bash

# Lyrical Autoware macro-benchmark. run.sh builds the bind-mounted rclcpp = the HOST
# tree, so the host's rclcpp/ must be on fix/mte-starvation-lyrical first. Caller is
# responsible for that checkout (see docker/run-autoware-lyrical.sh which automates it).
autoware-lyrical-build:
	$(COMPOSE) build autoware-lyrical

autoware-lyrical-smoke: autoware-lyrical-build
	$(COMPOSE) run --rm autoware-lyrical bash -lc '\
	  bash /ws/src/rclcpp_fork/docker/autoware/run.sh $(AW_DURATION) $(AW_RUNS)'
