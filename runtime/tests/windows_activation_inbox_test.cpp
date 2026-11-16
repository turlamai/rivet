#include "../../platform/windows/system/activation_inbox.hpp"

#include <cassert>
#include <string>
#include <vector>

int main() {
  using rivet::system::ActivationInbox;
  ActivationInbox inbox;

  // Native Windows receives UTF-16 argv even before Racket's Hello handshake.
  inbox.push_all({L"rivet://open/first", L"C:\\Users\\test\\file.txt"});
  assert(inbox.pending_count() == 2);
  assert((inbox.take() ==
          std::vector<std::wstring>{L"rivet://open/first",
                                    L"C:\\Users\\test\\file.txt"}));
  assert(inbox.take().empty());

  // No unbounded accumulation when file/URL protocol invocations repeat.
  std::vector<std::wstring> items;
  for (std::size_t i = 0; i < ActivationInbox::kMaxPending + 5; ++i) {
    auto item = L"rivet://open/" + std::to_wstring(i);
    inbox.push(item);
    items.push_back(item);
  }
  assert(inbox.pending_count() == ActivationInbox::kMaxPending);
  assert(inbox.dropped_count() == 5);
  auto result = inbox.take();
  assert((result ==
          std::vector<std::wstring>(items.end() - ActivationInbox::kMaxPending,
                                    items.end())));

  inbox.push(L"");
  inbox.push(std::wstring(ActivationInbox::kMaxItemCharacters + 1, L'x'));
  assert(inbox.rejected_count() == 2);
  assert(inbox.pending_count() == 0);
  inbox.push(std::wstring(ActivationInbox::kMaxItemCharacters, L'z'));
  auto boundary = inbox.take();
  assert(boundary.size() == 1);
  assert(boundary.front().size() == ActivationInbox::kMaxItemCharacters);
  assert(inbox.dropped_count() == 5);
  assert(inbox.rejected_count() == 2);
  return 0;
}
