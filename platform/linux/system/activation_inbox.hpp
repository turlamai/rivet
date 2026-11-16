#pragma once

#include <cstddef>
#include <deque>
#include <string>
#include <utility>
#include <vector>

namespace rivet::system {

// An intentionally transport-neutral, UI-thread-owned inbox for file/URL
// activation arguments. The product interprets and authorizes each item;
// accepting a native activation must not implicitly invoke a backend RPC.
// GTK4's GApplication command-line signal runs on the primary main context.
class ActivationInbox final {
 public:
  static constexpr std::size_t kMaxPending = 64;
  static constexpr std::size_t kMaxItemBytes = 4096;

  void push(std::string value) {
    if (value.empty() || value.size() > kMaxItemBytes) {
      ++rejected_;
      return;
    }
    if (pending_.size() == kMaxPending) {
      pending_.pop_front();
      ++dropped_;
    }
    pending_.push_back(std::move(value));
  }

  void push_all(std::vector<std::string> values) {
    for (auto& value : values) push(std::move(value));
  }

  // Hand events to product-owned validation/typed dispatch, after startup.
  // Draining is explicit: merely reaching the backend-ready state never
  // silently drops or auto-executes a queued action.
  [[nodiscard]] std::vector<std::string> take() {
    std::vector<std::string> result;
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
  std::deque<std::string> pending_;
  std::size_t dropped_{0};
  std::size_t rejected_{0};
};

}  // namespace rivet::system
