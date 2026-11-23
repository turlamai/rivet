#pragma once

// Transport-neutral core of the embedded Racket CS backend.
//
// Every desktop host that embeds Racket in-process (the WinUI 3 host on
// Windows, the GTK4 host on Linux) needs the same machinery below the
// native channel: booting Racket CS on a dedicated thread, handing the
// serve-fds endpoints to the application entry point, one reader thread that
// validates frames and resolves completions, serialized request/cancel writes,
// and an orderly stop. Only the channel itself is platform-specific (named
// pipes on Windows, an AF_UNIX socketpair on Linux). The platform therefore
// supplies an EmbeddedChannel and owns endpoint lifetime; everything else
// lives here so the two hosts cannot drift apart.
//
// This header is Rivet-internal: it is built into the platform libraries and
// is not a downstream integration surface. It includes the Racket CS C API,
// so the portable `rivet_protocol` library (which is Racket-agnostic) does not
// compile embedded_backend.cpp; the Windows and Linux platform builds do.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "rivet/detail/backend_completion_registry.hpp"
#include "rivet/diagnostics.hpp"
#include "rivet/protocol.hpp"

namespace rivet::detail {

struct EmbeddedRuntimeConfig {
  std::string executable_path;
  std::string petite_boot;
  std::string scheme_boot;
  std::string racket_boot;
  std::string backend_bundle;
  std::string module_name{"backend"};
  std::string entry_symbol{"start"};
  std::string collects_dir;
  std::string config_dir;
  // Windows only: the directory Racket CS searches for its DLLs. Left empty
  // on other platforms.
  std::wstring dll_dir;
  std::size_t max_pending_requests{1024};
  DiagnosticSink diagnostic_sink{default_diagnostic_sink()};
};

struct PendingCall {
  std::uint64_t id{};
  std::future<Value> result;
};

struct CallResult {
  std::optional<Value> value;
  std::exception_ptr error;

  bool succeeded() const noexcept { return value.has_value() && !error; }
};

using CompletionHandler = std::function<void(CallResult)>;
using EventHandler = std::function<void(std::string const&, Value const&)>;

// The serve-fds endpoints, owned by the platform until Racket consumes them.
//
// The descriptor accessors return the Rktio system descriptor that
// `unsafe-file-descriptor->port` expects: the native HANDLE value on Windows,
// a file descriptor elsewhere. `release()` transfers ownership to the Racket
// ports; before it, the platform object must close both endpoints itself.
class ServerEndpoints {
 public:
  virtual ~ServerEndpoints() = default;

  virtual intptr_t read_descriptor() const noexcept = 0;
  virtual intptr_t write_descriptor() const noexcept = 0;
  virtual void release() noexcept = 0;
};

// One opened channel: the native transport the core reads and writes, plus
// the server-side endpoints handed to the application's `start`.
struct EmbeddedChannel {
  std::unique_ptr<Transport> transport;
  std::unique_ptr<ServerEndpoints> server;
};

using EmbeddedChannelFactory = std::function<EmbeddedChannel()>;

// Threading contract:
//   * start()/stop()/request()/request_async()/cancel() may be used by the UI
//     layer.
//   * Racket CS is booted and entered on a dedicated worker thread.
//   * one reader thread resolves native futures and receives RPC completions.
//   * completion handlers are not UI-thread-affine: normal replies run them on
//     the reader thread, while immediate submission/shutdown failures can run
//     them on the initiating/shutdown thread. Always dispatch before touching
//     UI objects.
//   * event handlers run on the reader thread and require the same UI dispatch.
//   * completion/event handler exceptions are isolated from the transport loop.
//   * no Racket value crosses either native thread boundary.
class EmbeddedBackendCore {
 public:
  EmbeddedBackendCore(EmbeddedRuntimeConfig config,
                      EmbeddedChannelFactory open_channel);
  ~EmbeddedBackendCore();

  EmbeddedBackendCore(EmbeddedBackendCore const&) = delete;
  EmbeddedBackendCore& operator=(EmbeddedBackendCore const&) = delete;

  void start();
  void stop();
  bool running() const noexcept;

  PendingCall request(std::string rpc_name, Value::List arguments);
  std::future<Value> call(std::string rpc_name, Value::List arguments);

  // Non-blocking request API. The returned id can be passed to cancel(). Every
  // accepted request produces exactly one completion unless the completion
  // itself throws, in which case the exception is isolated by the runtime.
  std::uint64_t request_async(std::string rpc_name,
                              Value::List arguments,
                              CompletionHandler completion);

  void cancel(std::uint64_t request_id);
  void set_event_handler(EventHandler handler);

 private:
  void note_protocol_event(std::string event) noexcept;
  void emit_diagnostic(std::string layer,
                       std::string event,
                       std::string status,
                       std::string message = {},
                       std::optional<std::uint64_t> request_id = std::nullopt)
      noexcept;
  void submit_request(std::uint64_t id,
                      std::string rpc_name,
                      Value::List arguments);
  void racket_main(std::unique_ptr<ServerEndpoints> server) noexcept;
  void reader_main() noexcept;
  void accept_hello(Frame const& frame);
  void deliver_event(Value value) noexcept;
  void set_ready_exception(std::exception_ptr error) noexcept;

  EmbeddedRuntimeConfig config_;
  EmbeddedChannelFactory open_channel_;
  mutable std::mutex state_mutex_;
  std::mutex stop_mutex_;
  std::mutex write_mutex_;
  std::mutex event_mutex_;
  std::mutex diagnostic_mutex_;
  std::unique_ptr<Transport> transport_;
  std::thread racket_thread_;
  std::thread reader_thread_;
  BackendCompletionRegistry<Value, CallResult, CompletionHandler> completions_;
  EventHandler event_handler_;
  std::atomic<bool> running_{false};
  std::atomic<bool> hello_seen_{false};
  std::atomic<bool> stopping_{false};
  std::string last_protocol_event_{"none"};
  bool started_{false};
  std::shared_ptr<std::promise<void>> ready_;
  std::future<void> ready_future_;
};

}  // namespace rivet::detail
