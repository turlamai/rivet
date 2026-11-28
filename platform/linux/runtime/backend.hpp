#pragma once

#include <memory>
#include <string>
#include <utility>

#include "rivet/detail/embedded_backend.hpp"
#include "rivet/diagnostics.hpp"
#include "rivet/protocol.hpp"

namespace rivet::linux_runtime {

// The runtime config and call types are shared with every embedded host; the
// platform namespace keeps the names downstream GTK code already uses. The
// Windows-only dll_dir field of the shared config is ignored here.
using RacketRuntimeConfig = detail::EmbeddedRuntimeConfig;
using PendingCall = detail::PendingCall;
using CallResult = detail::CallResult;
using CompletionHandler = detail::CompletionHandler;
using EventHandler = detail::EventHandler;

// Owns one embedded Racket CS instance and its RVT1 transport over an
// AF_UNIX socketpair. The threading contract is the one documented on
// rivet::detail::EmbeddedBackendCore.
class Backend final {
 public:
  explicit Backend(RacketRuntimeConfig config);
  ~Backend();

  Backend(Backend const&) = delete;
  Backend& operator=(Backend const&) = delete;

  void start();
  void stop();
  bool running() const noexcept;

  PendingCall request(std::string rpc_name, Value::List arguments = {});
  std::future<Value> call(std::string rpc_name, Value::List arguments = {});

  // Non-blocking request API. The returned id can be passed to cancel().
  // Every accepted request produces exactly one completion unless the
  // completion itself throws, in which case the exception is isolated by
  // the runtime.
  std::uint64_t request_async(std::string rpc_name,
                              Value::List arguments,
                              CompletionHandler completion);

  std::future<Value> get_state(std::string name) {
    Value::List args;
    args.emplace_back(std::move(name));
    return call("$state/get", std::move(args));
  }

  std::future<Value> set_state(std::string name, Value value) {
    Value::List args;
    args.emplace_back(std::move(name));
    args.emplace_back(std::move(value));
    return call("$state/set", std::move(args));
  }

  std::uint64_t get_state_async(std::string name, CompletionHandler completion) {
    Value::List args;
    args.emplace_back(std::move(name));
    return request_async("$state/get", std::move(args), std::move(completion));
  }

  std::uint64_t set_state_async(std::string name,
                                Value value,
                                CompletionHandler completion) {
    Value::List args;
    args.emplace_back(std::move(name));
    args.emplace_back(std::move(value));
    return request_async("$state/set", std::move(args), std::move(completion));
  }

  void cancel(std::uint64_t request_id);
  void set_event_handler(EventHandler handler);

 private:
  std::unique_ptr<detail::EmbeddedBackendCore> impl_;
};

}  // namespace rivet::linux_runtime
