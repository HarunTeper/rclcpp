FROM ros:lyrical
SHELL ["/bin/bash", "-c"]

# Build deps for building rclcpp from source + benchmark tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-colcon-common-extensions \
      ros-lyrical-performance-test-fixture \
      ros-lyrical-test-msgs \
      ros-lyrical-ament-cmake-google-benchmark \
      ros-lyrical-mimick-vendor \
      git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /ws
# Source is bind-mounted at runtime to /ws/src/rclcpp_fork (see compose.yaml)
CMD ["bash"]
