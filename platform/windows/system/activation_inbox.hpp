#pragma once

#include <cstddef>
#include <deque>
#include <string>
#include <utility>
#include <vector>

namespace rivet::system {

// UI-thread-owned inbox for Win32 argv activation payloads. Retain the raw
// Unicode arguments without treating them as trusted paths or commands.
// Products explicitly validate and consume them after backend readiness.
// This facility does not provide second-instance delivery by itself.
class ActivationInbox final {
 public:
  static constexpr std::size_t kMaxPending = 64;
  static constexpr std::size_t kMaxItemCharacters = 4096;

  void push(std::wstring value) {
    if (value.empty() || value.size() > kMaxItemCharacters) {
      ++rejected_;
      return;
    }
    if (pending_.size() == kMaxPending) {
      pending_.pop_front();
      ++dropped_;
    }
    pending_.push_back(std::move(value));
  }

  void push_all(std::vector<std::wstring> values) {
    for (auto& value : values) push(std::move(value));
  }

  [[nodiscard]] std::vector<std::wstring> take() {
    std::vector<std::wstring> result;
    result.reserve(pending_.size());
    while (!pending_.empty()) {
      result.push_back(std::move(pending_.front()));
      pending_.pop_front();
    }
    return result;
  }

  [[nodiscard]] std::size_t pending_count() const { return pending_.size(); }
  [[nodiscard]] std::size_t dropped_count() const { return dropped_; }
  [[nodiscard]] std::size_t rejected_count() const { return rejected_; }

 private:
  std::deque<std::wstring> pending_;
  std::size_t dropped_{0};
  std::size_t rejected_{0};
};

}  // namespace rivet::system
