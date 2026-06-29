// Copyright 2015 Open Source Robotics Foundation, Inc.
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

#ifndef RCLCPP__STRATEGIES__ALLOCATOR_MEMORY_STRATEGY_HPP_
#define RCLCPP__STRATEGIES__ALLOCATOR_MEMORY_STRATEGY_HPP_

#include <memory>
#include <vector>

#include "rcl/allocator.h"

#include "rclcpp/allocator/allocator_common.hpp"
#include "rclcpp/detail/add_guard_condition_to_rcl_wait_set.hpp"
#include "rclcpp/memory_strategy.hpp"
#include "rclcpp/node.hpp"
#include "rclcpp/visibility_control.hpp"

#include "rcutils/logging_macros.h"

#include "rmw/types.h"

namespace rclcpp
{
namespace memory_strategies
{
namespace allocator_memory_strategy
{

/// Delegate for handling memory allocations while the Executor is executing.
/**
 * By default, the memory strategy dynamically allocates memory for structures that come in from
 * the rmw implementation after the executor waits for work, based on the number of entities that
 * come through.
 */
template<typename Alloc = std::allocator<void>>
class AllocatorMemoryStrategy : public memory_strategy::MemoryStrategy
{
public:
  RCLCPP_SMART_PTR_DEFINITIONS(AllocatorMemoryStrategy<Alloc>)

  using VoidAllocTraits = typename allocator::AllocRebind<void *, Alloc>;
  using VoidAlloc = typename VoidAllocTraits::allocator_type;

  explicit AllocatorMemoryStrategy(std::shared_ptr<Alloc> allocator)
  {
    allocator_ = std::make_shared<VoidAlloc>(*allocator.get());
  }

  AllocatorMemoryStrategy()
  {
    allocator_ = std::make_shared<VoidAlloc>();
  }

  void add_guard_condition(const rclcpp::GuardCondition & guard_condition) override
  {
    for (const auto & existing_guard_condition : guard_conditions_) {
      if (existing_guard_condition == &guard_condition) {
        return;
      }
    }
    guard_conditions_.push_back(&guard_condition);
  }

  void remove_guard_condition(const rclcpp::GuardCondition * guard_condition) override
  {
    for (auto it = guard_conditions_.begin(); it != guard_conditions_.end(); ++it) {
      if (*it == guard_condition) {
        guard_conditions_.erase(it);
        break;
      }
    }
  }

  void clear_handles() override
  {
    subscription_handles_.clear();
    service_handles_.clear();
    client_handles_.clear();
    timer_handles_.clear();
    waitable_handles_.clear();
  }

  void clear_handles_with_groups(const WeakCallbackGroupsToNodesMap & weak_groups_to_nodes)
    override
  {
    number_of_blocked_subscriptions = 0;
    auto subscription_it = subscription_handles_.begin();
    while (subscription_it != subscription_handles_.end()) {
      auto subscription = get_subscription_by_handle(*subscription_it, weak_groups_to_nodes);
      if (subscription) {
        auto group = get_group_by_subscription(subscription, weak_groups_to_nodes);
        if (!group) {
          subscription_it = subscription_handles_.erase(subscription_it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          // Group is blocked; keep this handle at the front and count it
          number_of_blocked_subscriptions++;
          ++subscription_it;
          continue;
        }
        subscription_it = subscription_handles_.erase(subscription_it);
        continue;
      }
      subscription_it = subscription_handles_.erase(subscription_it);
    }

    number_of_blocked_timers = 0;
    auto timer_it = timer_handles_.begin();
    while (timer_it != timer_handles_.end()) {
      auto timer = get_timer_by_handle(*timer_it, weak_groups_to_nodes);
      if (timer) {
        auto group = get_group_by_timer(timer, weak_groups_to_nodes);
        if (!group) {
          timer_it = timer_handles_.erase(timer_it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          number_of_blocked_timers++;
          ++timer_it;
          continue;
        }
        timer_it = timer_handles_.erase(timer_it);
        continue;
      }
      timer_it = timer_handles_.erase(timer_it);
    }

    number_of_blocked_services = 0;
    auto service_it = service_handles_.begin();
    while (service_it != service_handles_.end()) {
      auto service = get_service_by_handle(*service_it, weak_groups_to_nodes);
      if (service) {
        auto group = get_group_by_service(service, weak_groups_to_nodes);
        if (!group) {
          service_it = service_handles_.erase(service_it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          number_of_blocked_services++;
          ++service_it;
          continue;
        }
        service_it = service_handles_.erase(service_it);
        continue;
      }
      service_it = service_handles_.erase(service_it);
    }

    number_of_blocked_clients = 0;
    auto client_it = client_handles_.begin();
    while (client_it != client_handles_.end()) {
      auto client = get_client_by_handle(*client_it, weak_groups_to_nodes);
      if (client) {
        auto group = get_group_by_client(client, weak_groups_to_nodes);
        if (!group) {
          client_it = client_handles_.erase(client_it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          number_of_blocked_clients++;
          ++client_it;
          continue;
        }
        client_it = client_handles_.erase(client_it);
        continue;
      }
      client_it = client_handles_.erase(client_it);
    }

    number_of_blocked_waitables = 0;
    auto waitable_it = waitable_handles_.begin();
    while (waitable_it != waitable_handles_.end()) {
      auto waitable = *waitable_it;
      if (waitable) {
        auto group = get_group_by_waitable(waitable, weak_groups_to_nodes);
        if (!group) {
          waitable_it = waitable_handles_.erase(waitable_it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          number_of_blocked_waitables++;
          ++waitable_it;
          continue;
        }
        waitable_it = waitable_handles_.erase(waitable_it);
        continue;
      }
      waitable_it = waitable_handles_.erase(waitable_it);
    }
  }

  void remove_null_handles(rcl_wait_set_t * wait_set) override
  {
    // TODO(jacobperron): Check if wait set sizes are what we expect them to be?
    //                    e.g. wait_set->size_of_clients == client_handles_.size()

    // Important to use subscription_handles_.size() instead of wait set's size since
    // there may be more subscriptions in the wait set due to Waitables added to the end.
    // The same logic applies for other entities.
    for (size_t i = 0; i < subscription_handles_.size() - number_of_blocked_subscriptions; ++i) {
      if (!wait_set->subscriptions[i]) {
        subscription_handles_[i + number_of_blocked_subscriptions].reset();
      }
    }
    for (size_t i = 0; i < service_handles_.size() - number_of_blocked_services; ++i) {
      if (!wait_set->services[i]) {
        service_handles_[i + number_of_blocked_services].reset();
      }
    }
    for (size_t i = 0; i < client_handles_.size() - number_of_blocked_clients; ++i) {
      if (!wait_set->clients[i]) {
        client_handles_[i + number_of_blocked_clients].reset();
      }
    }
    for (size_t i = 0; i < timer_handles_.size() - number_of_blocked_timers; ++i) {
      if (!wait_set->timers[i]) {
        timer_handles_[i + number_of_blocked_timers].reset();
      }
    }
    for (size_t i = 0; i < waitable_handles_.size() - number_of_blocked_waitables; ++i) {
      if (!waitable_handles_[i + number_of_blocked_waitables]->is_ready(wait_set)) {
        waitable_handles_[i + number_of_blocked_waitables].reset();
      }
    }

    subscription_handles_.erase(
      std::remove(subscription_handles_.begin(), subscription_handles_.end(), nullptr),
      subscription_handles_.end()
    );

    service_handles_.erase(
      std::remove(service_handles_.begin(), service_handles_.end(), nullptr),
      service_handles_.end()
    );

    client_handles_.erase(
      std::remove(client_handles_.begin(), client_handles_.end(), nullptr),
      client_handles_.end()
    );

    timer_handles_.erase(
      std::remove(timer_handles_.begin(), timer_handles_.end(), nullptr),
      timer_handles_.end()
    );

    waitable_handles_.erase(
      std::remove(waitable_handles_.begin(), waitable_handles_.end(), nullptr),
      waitable_handles_.end()
    );
  }

  bool collect_entities(const WeakCallbackGroupsToNodesMap & weak_groups_to_nodes) override
  {
    bool has_invalid_weak_groups_or_nodes = false;
    for (const auto & pair : weak_groups_to_nodes) {
      auto group = pair.first.lock();
      auto node = pair.second.lock();
      if (group == nullptr || node == nullptr) {
        has_invalid_weak_groups_or_nodes = true;
        continue;
      }
      if (!group || !group->can_be_taken_from().load()) {
        continue;
      }

      group->collect_all_ptrs(
        [this](const rclcpp::SubscriptionBase::SharedPtr & subscription) {
          subscription_handles_.push_back(subscription->get_subscription_handle());
        },
        [this](const rclcpp::ServiceBase::SharedPtr & service) {
          service_handles_.push_back(service->get_service_handle());
        },
        [this](const rclcpp::ClientBase::SharedPtr & client) {
          client_handles_.push_back(client->get_client_handle());
        },
        [this](const rclcpp::TimerBase::SharedPtr & timer) {
          timer_handles_.push_back(timer->get_timer_handle());
        },
        [this](const rclcpp::Waitable::SharedPtr & waitable) {
          waitable_handles_.push_back(waitable);
        });
    }

    return has_invalid_weak_groups_or_nodes;
  }

  void add_waitable_handle(const rclcpp::Waitable::SharedPtr & waitable) override
  {
    if (nullptr == waitable) {
      throw std::runtime_error("waitable object unexpectedly nullptr");
    }
    waitable_handles_.push_back(waitable);
  }

  bool add_handles_to_wait_set(rcl_wait_set_t * wait_set) override
  {
    // Skip the first number_of_blocked_* entries — those are handles whose callback group is
    // currently executing (can_be_taken_from()==false) and must not be added to the wait set.
    for (size_t i = number_of_blocked_subscriptions; i < subscription_handles_.size(); ++i) {
      if (rcl_wait_set_add_subscription(wait_set, subscription_handles_[i].get(), NULL) !=
        RCL_RET_OK)
      {
        RCUTILS_LOG_ERROR_NAMED(
          "rclcpp",
          "Couldn't add subscription to wait set: %s", rcl_get_error_string().str);
        return false;
      }
    }

    for (size_t i = number_of_blocked_clients; i < client_handles_.size(); ++i) {
      if (rcl_wait_set_add_client(wait_set, client_handles_[i].get(), NULL) != RCL_RET_OK) {
        RCUTILS_LOG_ERROR_NAMED(
          "rclcpp",
          "Couldn't add client to wait set: %s", rcl_get_error_string().str);
        return false;
      }
    }

    for (size_t i = number_of_blocked_services; i < service_handles_.size(); ++i) {
      if (rcl_wait_set_add_service(wait_set, service_handles_[i].get(), NULL) != RCL_RET_OK) {
        RCUTILS_LOG_ERROR_NAMED(
          "rclcpp",
          "Couldn't add service to wait set: %s", rcl_get_error_string().str);
        return false;
      }
    }

    for (size_t i = number_of_blocked_timers; i < timer_handles_.size(); ++i) {
      if (rcl_wait_set_add_timer(wait_set, timer_handles_[i].get(), NULL) != RCL_RET_OK) {
        RCUTILS_LOG_ERROR_NAMED(
          "rclcpp",
          "Couldn't add timer to wait set: %s", rcl_get_error_string().str);
        return false;
      }
    }

    for (auto guard_condition : guard_conditions_) {
      detail::add_guard_condition_to_rcl_wait_set(*wait_set, *guard_condition);
    }

    for (size_t i = number_of_blocked_waitables; i < waitable_handles_.size(); ++i) {
      waitable_handles_[i]->add_to_wait_set(wait_set);
    }
    return true;
  }

  void
  get_next_subscription(
    rclcpp::AnyExecutable & any_exec,
    const WeakCallbackGroupsToNodesMap & weak_groups_to_nodes) override
  {
    auto it = subscription_handles_.begin();
    while (it != subscription_handles_.end()) {
      auto subscription = get_subscription_by_handle(*it, weak_groups_to_nodes);
      if (subscription) {
        // Find the group for this handle and see if it can be serviced
        auto group = get_group_by_subscription(subscription, weak_groups_to_nodes);
        if (!group) {
          // Group was not found, meaning the subscription is not valid...
          // Remove it from the ready list and continue looking
          it = subscription_handles_.erase(it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          // Group is mutually exclusive and is being used, so skip it for now
          // Leave it to be checked next time, but continue searching
          ++it;
          continue;
        }
        // Otherwise it is safe to set and return the any_exec
        any_exec.subscription = subscription;
        any_exec.callback_group = group;
        any_exec.node_base = get_node_by_group(group, weak_groups_to_nodes);
        subscription_handles_.erase(it);
        return;
      }
      // Else, the subscription is no longer valid, remove it and continue
      it = subscription_handles_.erase(it);
    }
  }

  void
  get_next_service(
    rclcpp::AnyExecutable & any_exec,
    const WeakCallbackGroupsToNodesMap & weak_groups_to_nodes) override
  {
    auto it = service_handles_.begin();
    while (it != service_handles_.end()) {
      auto service = get_service_by_handle(*it, weak_groups_to_nodes);
      if (service) {
        // Find the group for this handle and see if it can be serviced
        auto group = get_group_by_service(service, weak_groups_to_nodes);
        if (!group) {
          // Group was not found, meaning the service is not valid...
          // Remove it from the ready list and continue looking
          it = service_handles_.erase(it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          // Group is mutually exclusive and is being used, so skip it for now
          // Leave it to be checked next time, but continue searching
          ++it;
          continue;
        }
        // Otherwise it is safe to set and return the any_exec
        any_exec.service = service;
        any_exec.callback_group = group;
        any_exec.node_base = get_node_by_group(group, weak_groups_to_nodes);
        service_handles_.erase(it);
        return;
      }
      // Else, the service is no longer valid, remove it and continue
      it = service_handles_.erase(it);
    }
  }

  void
  get_next_client(
    rclcpp::AnyExecutable & any_exec,
    const WeakCallbackGroupsToNodesMap & weak_groups_to_nodes) override
  {
    auto it = client_handles_.begin();
    while (it != client_handles_.end()) {
      auto client = get_client_by_handle(*it, weak_groups_to_nodes);
      if (client) {
        // Find the group for this handle and see if it can be serviced
        auto group = get_group_by_client(client, weak_groups_to_nodes);
        if (!group) {
          // Group was not found, meaning the service is not valid...
          // Remove it from the ready list and continue looking
          it = client_handles_.erase(it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          // Group is mutually exclusive and is being used, so skip it for now
          // Leave it to be checked next time, but continue searching
          ++it;
          continue;
        }
        // Otherwise it is safe to set and return the any_exec
        any_exec.client = client;
        any_exec.callback_group = group;
        any_exec.node_base = get_node_by_group(group, weak_groups_to_nodes);
        client_handles_.erase(it);
        return;
      }
      // Else, the service is no longer valid, remove it and continue
      it = client_handles_.erase(it);
    }
  }

  void
  get_next_timer(
    rclcpp::AnyExecutable & any_exec,
    const WeakCallbackGroupsToNodesMap & weak_groups_to_nodes) override
  {
    auto it = timer_handles_.begin();
    while (it != timer_handles_.end()) {
      auto timer = get_timer_by_handle(*it, weak_groups_to_nodes);
      if (timer) {
        // Find the group for this handle and see if it can be serviced
        auto group = get_group_by_timer(timer, weak_groups_to_nodes);
        if (!group) {
          // Group was not found, meaning the timer is not valid...
          // Remove it from the ready list and continue looking
          it = timer_handles_.erase(it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          // Group is mutually exclusive and is being used, so skip it for now
          // Leave it to be checked next time, but continue searching
          ++it;
          continue;
        }
        if (!timer->call()) {
          // timer was cancelled, skip it.
          ++it;
          continue;
        }
        // Otherwise it is safe to set and return the any_exec
        any_exec.timer = timer;
        any_exec.callback_group = group;
        any_exec.node_base = get_node_by_group(group, weak_groups_to_nodes);
        timer_handles_.erase(it);
        return;
      }
      // Else, the timer is no longer valid, remove it and continue
      it = timer_handles_.erase(it);
    }
  }

  void
  get_next_waitable(
    rclcpp::AnyExecutable & any_exec,
    const WeakCallbackGroupsToNodesMap & weak_groups_to_nodes) override
  {
    auto it = waitable_handles_.begin();
    while (it != waitable_handles_.end()) {
      std::shared_ptr<Waitable> & waitable = *it;
      if (waitable) {
        // Find the group for this handle and see if it can be serviced
        auto group = get_group_by_waitable(waitable, weak_groups_to_nodes);
        if (!group) {
          // Group was not found, meaning the waitable is not valid...
          // Remove it from the ready list and continue looking
          it = waitable_handles_.erase(it);
          continue;
        }
        if (!group->can_be_taken_from().load()) {
          // Group is mutually exclusive and is being used, so skip it for now
          // Leave it to be checked next time, but continue searching
          ++it;
          continue;
        }
        // Otherwise it is safe to set and return the any_exec
        any_exec.waitable = waitable;
        any_exec.callback_group = group;
        any_exec.node_base = get_node_by_group(group, weak_groups_to_nodes);
        waitable_handles_.erase(it);
        return;
      }
      // Else, the waitable is no longer valid, remove it and continue
      it = waitable_handles_.erase(it);
    }
  }

  rcl_allocator_t get_allocator() override
  {
    if constexpr (std::is_same_v<Alloc, std::allocator<void>>) {
      return rcl_get_default_allocator();
    } else {
      return rclcpp::allocator::get_rcl_allocator<void *, VoidAlloc>(*allocator_.get());
    }
  }

  size_t number_of_ready_subscriptions() const override
  {
    size_t number_of_subscriptions =
      subscription_handles_.size() - number_of_blocked_subscriptions;
    for (const std::shared_ptr<Waitable> & waitable : waitable_handles_) {
      number_of_subscriptions += waitable->get_number_of_ready_subscriptions();
    }
    return number_of_subscriptions;
  }

  size_t number_of_ready_services() const override
  {
    size_t number_of_services = service_handles_.size() - number_of_blocked_services;
    for (const std::shared_ptr<Waitable> & waitable : waitable_handles_) {
      number_of_services += waitable->get_number_of_ready_services();
    }
    return number_of_services;
  }

  size_t number_of_ready_events() const override
  {
    size_t number_of_events = 0;
    for (const std::shared_ptr<Waitable> & waitable : waitable_handles_) {
      number_of_events += waitable->get_number_of_ready_events();
    }
    return number_of_events;
  }

  size_t number_of_ready_clients() const override
  {
    size_t number_of_clients = client_handles_.size() - number_of_blocked_clients;
    for (const std::shared_ptr<Waitable> & waitable : waitable_handles_) {
      number_of_clients += waitable->get_number_of_ready_clients();
    }
    return number_of_clients;
  }

  size_t number_of_guard_conditions() const override
  {
    size_t number_of_guard_conditions = guard_conditions_.size();
    for (const std::shared_ptr<Waitable> & waitable : waitable_handles_) {
      number_of_guard_conditions += waitable->get_number_of_ready_guard_conditions();
    }
    return number_of_guard_conditions;
  }

  size_t number_of_ready_timers() const override
  {
    size_t number_of_timers = timer_handles_.size() - number_of_blocked_timers;
    for (const std::shared_ptr<Waitable> & waitable : waitable_handles_) {
      number_of_timers += waitable->get_number_of_ready_timers();
    }
    return number_of_timers;
  }

  size_t number_of_waitables() const override
  {
    return waitable_handles_.size() - number_of_blocked_waitables;
  }

private:
  template<typename T>
  using VectorRebind =
    std::vector<T, typename std::allocator_traits<Alloc>::template rebind_alloc<T>>;

  VectorRebind<const rclcpp::GuardCondition *> guard_conditions_;

  VectorRebind<std::shared_ptr<const rcl_subscription_t>> subscription_handles_;
  VectorRebind<std::shared_ptr<const rcl_service_t>> service_handles_;
  VectorRebind<std::shared_ptr<const rcl_client_t>> client_handles_;
  VectorRebind<std::shared_ptr<const rcl_timer_t>> timer_handles_;
  VectorRebind<std::shared_ptr<Waitable>> waitable_handles_;

  std::shared_ptr<VoidAlloc> allocator_;
};

}  // namespace allocator_memory_strategy
}  // namespace memory_strategies
}  // namespace rclcpp

#endif  // RCLCPP__STRATEGIES__ALLOCATOR_MEMORY_STRATEGY_HPP_
