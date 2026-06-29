FROM ros:jazzy
SHELL ["/bin/bash", "-c"]

# Build deps for building rclcpp from source + benchmark tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-colcon-common-extensions \
      ros-jazzy-performance-test-fixture \
      ros-jazzy-test-msgs \
      ros-jazzy-ament-cmake-google-benchmark \
      ros-jazzy-mimick-vendor \
      git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /ws
# Source is bind-mounted at runtime to /ws/src/rclcpp_fork (see compose.yaml)
CMD ["bash"]
