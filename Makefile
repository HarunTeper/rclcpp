COMPOSE = docker compose -f docker/compose.yaml

.PHONY: lyrical-build lyrical-shell
lyrical-build:
	$(COMPOSE) build lyrical
	$(COMPOSE) run --rm lyrical bash -lc '\
	  mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp && \
	  source /opt/ros/lyrical/setup.bash && \
	  colcon build --packages-select rclcpp --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo'

lyrical-shell:
	$(COMPOSE) run --rm lyrical bash
