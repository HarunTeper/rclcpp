# Autoware reference-system macro-benchmark image for the MTE starvation-fix comparison.
#
# Builds the ros-realtime/reference-system autoware_reference_system against our
# OVERLAID fixed rclcpp, plus an added EventsCBGExecutor variant
# (autoware_default_events), so we can compare fixed-MTE vs EventsCBGExecutor on the
# paper's reference workload.
#
# DISTRO CHOICE: must be a distro where BOTH (a) the reference-system builds and
# (b) rclcpp's EventsCBGExecutor exists (wait_result_ era). That is Jazzy or Lyrical.
# The reference-system is only CI-tested on Humble/Iron/Rolling, but its node code is
# plain rclcpp and builds on Jazzy/Lyrical too. Default here: jazzy (closest released
# LTS overlap). Override with --build-arg ROS_DISTRO=lyrical.
ARG ROS_DISTRO=jazzy
FROM ros:${ROS_DISTRO}
ARG ROS_DISTRO
SHELL ["/bin/bash", "-c"]

# Build deps for rclcpp-from-source + the reference system + its Python reporting tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-colcon-common-extensions \
      python3-pip \
      git \
      ros-${ROS_DISTRO}-test-msgs \
      ros-${ROS_DISTRO}-mimick-vendor \
      ros-${ROS_DISTRO}-performance-test-fixture \
      ros-${ROS_DISTRO}-ament-cmake-google-benchmark \
      ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
    && rm -rf /var/lib/apt/lists/*

# Python reporting deps used by reference_system_py (psrecord/bokeh for memory+plots,
# pandas/jinja2 for the summary tables). --break-system-packages: ROS images are PEP668.
# bokeh pinned <3: the reference-system's report.py uses the bokeh 2.x figure(plot_width=...)
# API, removed in bokeh 3.x — with bokeh 3 the HTML-report step of benchmark.py throws
# (AttributeError plot_width). We parse latency from std_output.log ourselves so the report
# isn't needed, but pinning keeps benchmark.py exiting clean (no alarming traceback).
RUN pip3 install --no-cache-dir --break-system-packages \
      psrecord 'bokeh<3' pandas jinja2 || \
    pip3 install --no-cache-dir psrecord 'bokeh<3' pandas jinja2

WORKDIR /ws
# rclcpp source is bind-mounted at runtime to /ws/src/rclcpp_fork (see compose).
# reference-system is cloned + the events variant injected at runtime by run.sh
# (keeps the image generic and lets us pin/patch without rebuilding the image).
CMD ["bash"]
