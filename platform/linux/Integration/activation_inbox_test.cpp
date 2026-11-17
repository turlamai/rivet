#include "activation_inbox.hpp"

#include <stdexcept>
#include <string>
#include <vector>

namespace {
void require(bool condition, char const* message) {
  if (!condition) throw std::runtime_error(message);
}
}  // namespace

int main() {
  using rivet::system::ActivationInbox;
  ActivationInbox inbox;

  // First-launch events remain available until product logic explicitly
  // consumes them, even if the backend is still starting.
  inbox.push_all({"rivet://open/first", "/tmp/hello.txt"});
  require(inbox.pending_count() == 2, "initial events lost");
  require((inbox.take() ==
           std::vector<std::string>{"rivet://open/first", "/tmp/hello.txt"}),
          "initial event order changed");
  require(inbox.pending_count() == 0, "drain should clear pending events");
  require(inbox.take().empty(), "second drain must not repeat events");

  // A run of second-instance command-line deliveries retains the latest
  // bounded suffix, preserving full opaque UTF-8 path and URL bytes.
  std::vector<std::string> inputs;
  for (std::size_t i = 0; i < ActivationInbox::kMaxPending + 7; ++i) {
    auto item = "rivet://open/" + std::to_string(i);
    inputs.push_back(item);
    inbox.push(item);
  }
  require(inbox.pending_count() == ActivationInbox::kMaxPending,
          "pending count exceeded bound");
  require(inbox.dropped_count() == 7, "overflow count incorrect");
  auto delivered = inbox.take();
  require(delivered ==
              std::vector<std::string>(inputs.end() - ActivationInbox::kMaxPending,
                                       inputs.end()),
          "overflow must drop oldest and preserve arrival order");

  inbox.push("");
  inbox.push(std::string(ActivationInbox::kMaxItemBytes + 1, 'x'));
  require(inbox.rejected_count() == 2, "invalid payloads not rejected");
  require(inbox.pending_count() == 0, "rejected payload entered the inbox");
  inbox.push(std::string(ActivationInbox::kMaxItemBytes, 'b'));
  require(inbox.pending_count() == 1, "valid boundary-length payload rejected");

  auto boundary = inbox.take();
  require(boundary.size() == 1 &&
              boundary[0].size() == ActivationInbox::kMaxItemBytes,
          "max-length activation was truncated");
  require(inbox.dropped_count() == 7 && inbox.rejected_count() == 2,
          "diagnostic counters should survive drain");
  return 0;
}
