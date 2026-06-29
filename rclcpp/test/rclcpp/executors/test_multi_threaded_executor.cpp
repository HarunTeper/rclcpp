// Copyright 2018 Open Source Robotics Foundation, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <string>
#include <memory>
#include <thread>

#include "rclcpp/exceptions.hpp"
#include "rclcpp/node.hpp"
#include "rclcpp/rclcpp.hpp"
#include "rclcpp/executors.hpp"
#if __has_include("rclcpp/executors/events_cbg_executor/events_cbg_executor.hpp")
#include "rclcpp/executors/events_cbg_executor/events_cbg_executor.hpp"
#endif

using namespace std::chrono_literals;

class TestMultiThreadedExecutor : public ::testing::Test
{
protected:
  static void SetUpTestCase()
  {
    rclcpp::init(0, nullptr);
  }
};

constexpr std::chrono::milliseconds PERIOD_MS = 1000ms;
constexpr double PERIOD = PERIOD_MS.count() / 1000.0;
constexpr double TOLERANCE = PERIOD / 4.0;

/*
   Test that timers are not taken multiple times when using reentrant callback groups.
 */
TEST_F(TestMultiThreadedExecutor, timer_over_take) {
#ifdef __linux__
  // This seems to be the most effective way to force the bug to happen on Linux.
  // This is unnecessary on MacOS, since the default scheduler causes it.
  struct sched_param param;
  param.sched_priority = 0;
  if (sched_setscheduler(0, SCHED_BATCH, &param) != 0) {
    perror("sched_setscheduler");
  }
#endif

  bool yield_before_execute = true;

  rclcpp::executors::MultiThreadedExecutor executor(
    rclcpp::ExecutorOptions(), 2u, yield_before_execute);

  ASSERT_GT(executor.get_number_of_threads(), 1u);

  std::shared_ptr<rclcpp::Node> node =
    std::make_shared<rclcpp::Node>("test_multi_threaded_executor_timer_over_take");

  auto cbg = node->create_callback_group(rclcpp::CallbackGroupType::Reentrant);

  rclcpp::Clock system_clock(RCL_STEADY_TIME);
  std::mutex last_mutex;
  auto last = system_clock.now();

  std::atomic_int timer_count {0};

  auto timer_callback = [&timer_count, &executor, &system_clock, &last_mutex, &last]() {
      // While this tolerance is a little wide, if the bug occurs, the next step will
      // happen almost instantly. The purpose of this test is not to measure the jitter
      // in timers, just assert that a reasonable amount of time has passed.
      rclcpp::Time now = system_clock.now();
      timer_count++;

      if (timer_count > 5) {
        executor.cancel();
      }

      {
        std::lock_guard<std::mutex> lock(last_mutex);
        double diff = static_cast<double>(std::abs((now - last).nanoseconds())) / 1.0e9;
        last = now;

        if (diff < PERIOD - TOLERANCE) {
          executor.cancel();
          ASSERT_GT(diff, PERIOD - TOLERANCE);
        }
      }
    };

  auto timer = node->create_wall_timer(PERIOD_MS, timer_callback, cbg);
  executor.add_node(node);
  executor.spin();
}

/*
  Starvation reproduction (paper Example 4): two timers in ONE mutually-exclusive
  callback group, two executor threads. A correct executor alternates between the
  two timers. The buggy MTE keeps re-selecting the higher-priority timer and never
  runs the other one. Each callback blocks briefly so that while one runs, the
  other's instance is blocked. We declare starvation if, by the time the first
  timer has fired kFireTarget times, the second has fired zero times.
  Templated on the executor type so multiple executors share one scenario body.
*/
template<typename ExecutorT>
void run_starvation_scenario(const std::string & node_name)
{
  ExecutorT executor(rclcpp::ExecutorOptions(), 2u);
  auto node = std::make_shared<rclcpp::Node>(node_name);
  auto group = node->create_callback_group(rclcpp::CallbackGroupType::MutuallyExclusive);

  constexpr int kFireTarget = 20;
  std::atomic_int count_one{0};
  std::atomic_int count_two{0};
  std::atomic_bool done{false};

  auto make_cb = [&](std::atomic_int & my_count) {
      return [&my_count, &done, &executor]() {
               std::this_thread::sleep_for(20ms);
               const int mine = ++my_count;
               if (mine >= kFireTarget && !done.exchange(true)) {
                 executor.cancel();
               }
             };
    };

  auto timer_one = node->create_wall_timer(5ms, make_cb(count_one), group);
  auto timer_two = node->create_wall_timer(5ms, make_cb(count_two), group);

  executor.add_node(node);
  executor.spin();

  EXPECT_GT(count_one.load(), 0) << "timer_one never executed (starved)";
  EXPECT_GT(count_two.load(), 0) << "timer_two never executed (starved)";
  EXPECT_LE(std::abs(count_one.load() - count_two.load()), 2)
    << "counts diverged: one=" << count_one.load() << " two=" << count_two.load();
}

TEST_F(TestMultiThreadedExecutor, starvation_mutually_exclusive_timers) {
  run_starvation_scenario<rclcpp::executors::MultiThreadedExecutor>("test_mte_starvation");
}

#if __has_include("rclcpp/executors/events_cbg_executor/events_cbg_executor.hpp")
TEST_F(TestMultiThreadedExecutor, starvation_eventscbg_passes) {
  run_starvation_scenario<rclcpp::executors::EventsCBGExecutor>("test_eventscbg_starvation");
}
#endif
