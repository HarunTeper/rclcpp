COMPOSE = docker compose -f docker/compose.yaml

.PHONY: lyrical-build lyrical-shell humble-build humble-shell jazzy-build jazzy-shell
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

humble-test:
	$(COMPOSE) run --rm humble bash -lc '\
	  mkdir -p /ws/src/pkg && ln -sfn /ws/src/rclcpp_fork/rclcpp /ws/src/pkg/rclcpp && \
	  source /opt/ros/humble/setup.bash && \
	  colcon build --packages-select rclcpp --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo && \
	  colcon test --packages-select rclcpp --ctest-args -R test_multi_threaded_executor && \
	  colcon test-result --verbose'
