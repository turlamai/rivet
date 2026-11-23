// Transport-neutral core of the embedded Racket CS backend. See
// runtime/include/rivet/detail/embedded_backend.hpp for the contract; the
// platform libraries (platform/windows/runtime, platform/linux/runtime) own
// the native channel and forward their public Backend API to this core.

#include "rivet/detail/embedded_backend.hpp"

#include <exception>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <variant>

#include "chezscheme.h"
#include "racketcs.h"

namespace rivet::detail {
namespace {

std::exception_ptr stopped_error() {
  return std::make_exception_ptr(std::runtime_error("Rivet backend stopped"));
}

std::string exception_message(std::exception_ptr error) noexcept {
  if (!error) return "unknown failure";
  try {
    std::rethrow_exception(error);
  } catch (std::exception const& exception) {
    return exception.what();
  } catch (...) {
    return "non-standard exception";
  }
}

ptr quoted_symbol(std::string const& name) {
  auto const quote = Sstring_to_symbol("quote");
  auto const module = Sstring_to_symbol(name.c_str());
  return Scons(quote, Scons(module, Snil));
}

}  // namespace

EmbeddedBackendCore::EmbeddedBackendCore(EmbeddedRuntimeConfig config,
                                         EmbeddedChannelFactory open_channel)
    : config_(std::move(config)),
      open_channel_(std::move(open_channel)),
      completions_(config_.max_pending_requests) {}

EmbeddedBackendCore::~EmbeddedBackendCore() {
  try {
    stop();
  } catch (...) {
    // Destructors cannot surface shutdown failures.
  }
}

void EmbeddedBackendCore::start() {
  std::unique_lock state_lock(state_mutex_);
  if (started_) {
    throw std::logic_error("Rivet backend instances cannot be restarted");
  }
  started_ = true;
  emit_diagnostic("native-runtime", "backend-start", "begin");

  auto channel = open_channel_();
  transport_ = std::move(channel.transport);
  auto server = std::move(channel.server);
  emit_diagnostic("transport", "channel-opened", "success");

  ready_ = std::make_shared<std::promise<void>>();
  ready_future_ = ready_->get_future();
  running_.store(true, std::memory_order_release);

  reader_thread_ = std::thread([this] { reader_main(); });
  racket_thread_ = std::thread(
      [this, server = std::move(server)]() mutable {
        racket_main(std::move(server));
      });

  state_lock.unlock();

  // The first valid frame from Racket is Hello. Waiting for it makes start
  // fail synchronously when boot files, core.zo, or the entry point are bad.
  try {
    ready_future_.get();
    emit_diagnostic("protocol", "handshake", "success");
    emit_diagnostic("native-runtime", "backend-start", "success");
  } catch (...) {
    emit_diagnostic("protocol", "handshake", "failure",
                    exception_message(std::current_exception()));
    emit_diagnostic("native-runtime", "backend-start", "failure",
                    exception_message(std::current_exception()));
    throw;
  }
}

void EmbeddedBackendCore::stop() {
  // Serializing the complete stop sequence prevents two callers from joining
  // or destroying the same native threads/transport concurrently.
  std::lock_guard stop_lock(stop_mutex_);

  {
    std::lock_guard state_lock(state_mutex_);
    if (!started_) {
      return;
    }
    stopping_.store(true, std::memory_order_release);
    // Writers recheck this flag after acquiring write_mutex_. Once false, no
    // new Request/Cancel may be written after the Shutdown boundary below.
    running_.store(false, std::memory_order_release);
  }
  emit_diagnostic("native-runtime", "backend-stop", "begin");

  // Try Shutdown even when a worker already marked running_ false. A native
  // reader failure does not necessarily mean the Racket server stopped
  // reading requests, and skipping Shutdown in that state could strand the
  // Racket thread forever in its request loop.
  try {
    std::lock_guard write_lock(write_mutex_);
    auto* transport = transport_.get();
    if (transport != nullptr) {
      note_protocol_event("shutdown");
      write_frame(*transport, Frame{MessageType::Shutdown, 0, {}});
    }
  } catch (...) {
    // The server may already have exited. Joining below is authoritative.
  }

  if (racket_thread_.joinable()) {
    racket_thread_.join();
  }

  // The Racket-side output port owns the server write endpoint and closes it
  // during serve-fds teardown. That EOF wakes read_frame. Keep the C++
  // transport object alive until the reader is fully joined so a blocked
  // read can never race with transport destruction.
  if (reader_thread_.joinable()) {
    reader_thread_.join();
  }

  // Writers also hold write_mutex_ whenever they dereference transport_. A
  // request that raced with stop either wrote before Shutdown or observes
  // running_ == false after it acquires this mutex and never touches the
  // transport. Destruction therefore cannot overlap a native write either.
  {
    std::lock_guard write_lock(write_mutex_);
    std::lock_guard state_lock(state_mutex_);
    transport_.reset();
  }

  completions_.reject_all(stopped_error());
  emit_diagnostic("native-runtime", "backend-stop", "success");
}

bool EmbeddedBackendCore::running() const noexcept {
  return running_.load(std::memory_order_acquire);
}

PendingCall EmbeddedBackendCore::request(std::string rpc_name,
                                         Value::List arguments) {
  if (!running()) {
    throw std::runtime_error("Rivet backend is not running");
  }
  auto pending = completions_.insert_future();
  submit_request(pending.id, std::move(rpc_name), std::move(arguments));
  return PendingCall{pending.id, std::move(pending.result)};
}

std::future<Value> EmbeddedBackendCore::call(std::string rpc_name,
                                             Value::List arguments) {
  return request(std::move(rpc_name), std::move(arguments)).result;
}

std::uint64_t EmbeddedBackendCore::request_async(
    std::string rpc_name,
    Value::List arguments,
    CompletionHandler completion) {
  if (!completion) {
    throw std::invalid_argument("Rivet async completion handler is empty");
  }
  if (!running()) {
    throw std::runtime_error("Rivet backend is not running");
  }
  auto const id = completions_.insert_completion(std::move(completion));
  submit_request(id, std::move(rpc_name), std::move(arguments));
  return id;
}

void EmbeddedBackendCore::cancel(std::uint64_t request_id) {
  if (!running()) {
    return;
  }

  // Match submit_request's write -> pending lock order. Recheck running after
  // acquiring write_mutex_ so a cancellation that queued behind stop cannot
  // be serialized after Shutdown. The pending ownership check and Cancel
  // write then form one linearized operation.
  std::lock_guard write_lock(write_mutex_);
  if (!running()) {
    return;
  }
  (void)completions_.request_cancel(request_id, [&] {
    auto* transport = transport_.get();
    if (transport != nullptr) {
      note_protocol_event("cancel");
      emit_diagnostic("native-client", "request-cancel", "begin", "",
                      request_id);
      write_frame(*transport, Frame{MessageType::Cancel, request_id, {}});
    }
  });
}

void EmbeddedBackendCore::set_event_handler(EventHandler handler) {
  std::lock_guard lock(event_mutex_);
  event_handler_ = std::move(handler);
}

void EmbeddedBackendCore::note_protocol_event(std::string event) noexcept {
  std::lock_guard lock(diagnostic_mutex_);
  last_protocol_event_ = std::move(event);
}

void EmbeddedBackendCore::emit_diagnostic(
    std::string layer,
    std::string event,
    std::string status,
    std::string message,
    std::optional<std::uint64_t> request_id) noexcept {
  DiagnosticRecord record;
  {
    std::lock_guard lock(diagnostic_mutex_);
    record = DiagnosticRecord{std::move(layer), std::move(event),
                              std::move(status), last_protocol_event_,
                              request_id, std::move(message)};
  }
  try {
    if (config_.diagnostic_sink) config_.diagnostic_sink(record);
  } catch (...) {
    // Diagnostics must never become a new runtime failure path.
  }
}

void EmbeddedBackendCore::submit_request(std::uint64_t id,
                                         std::string rpc_name,
                                         Value::List arguments) {
  note_protocol_event("request");
  emit_diagnostic("native-client", "rpc-dispatch", "begin", rpc_name, id);

  Value::List request;
  request.reserve(arguments.size() + 1);
  request.emplace_back(std::move(rpc_name));
  for (auto& argument : arguments) {
    request.emplace_back(std::move(argument));
  }

  try {
    std::lock_guard write_lock(write_mutex_);
    // A request may have passed the optimistic check above before another
    // thread began stop(). Rechecking while holding the serialization lock
    // guarantees it is either entirely before Shutdown or not written at all.
    if (!running()) {
      throw std::runtime_error("Rivet backend is not running");
    }
    auto* transport = transport_.get();
    if (transport == nullptr) {
      throw std::runtime_error("Rivet backend transport is closed");
    }
    write_frame(*transport,
                Frame{MessageType::Request, id,
                      encode_value(Value(std::move(request)))});

    bool const send_deferred_cancel = completions_.mark_request_sent(id);
    // Keep write_mutex_ while emitting a latched cancellation so no other
    // frame can interleave between this Request and its deferred Cancel. If
    // stop began after the running check above, it is waiting for this mutex,
    // so both frames remain ordered before Shutdown.
    if (send_deferred_cancel) {
      write_frame(*transport, Frame{MessageType::Cancel, id, {}});
    }
  } catch (...) {
    emit_diagnostic("transport", "request-write", "failure",
                    exception_message(std::current_exception()), id);
    completions_.fail(id, std::current_exception());
  }
}

void EmbeddedBackendCore::racket_main(
    std::unique_ptr<ServerEndpoints> server) noexcept {
  emit_diagnostic("abi-bridge", "backend-init", "begin");
  bool initialized = false;
  try {
    // `unsafe-file-descriptor->port` consumes a Rktio system descriptor: the
    // native HANDLE value on Windows, a file descriptor elsewhere. Keep
    // ownership in the platform endpoints through startup and transfer it to
    // the Racket ports immediately before entering the application procedure.
    auto const in_descriptor = server->read_descriptor();
    auto const out_descriptor = server->write_descriptor();

    racket_boot_arguments_t boot{};
    boot.boot1_path = config_.petite_boot.c_str();
    boot.boot2_path = config_.scheme_boot.c_str();
    boot.boot3_path = config_.racket_boot.c_str();
    boot.exec_file = config_.executable_path.c_str();
    if (!config_.collects_dir.empty()) {
      boot.collects_dir = config_.collects_dir.c_str();
    }
    if (!config_.config_dir.empty()) {
      boot.config_dir = config_.config_dir.c_str();
    }
    if (!config_.dll_dir.empty()) {
      boot.dll_dir = const_cast<wchar_t*>(config_.dll_dir.c_str());
    }

    racket_boot(&boot);
    racket_embedded_load_file(config_.backend_bundle.c_str(), 1);

    auto const module = quoted_symbol(config_.module_name);
    auto const entry = Sstring_to_symbol(config_.entry_symbol.c_str());
    // racket_dynamic_require is implemented in terms of racket_apply and
    // therefore returns a list of result values. The requested export is
    // the first result.
    auto const results = racket_dynamic_require(module, entry);
    auto const procedure = Scar(results);
    auto const args = Scons(Sfixnum(in_descriptor),
                            Scons(Sfixnum(out_descriptor), Snil));

    initialized = true;
    emit_diagnostic("abi-bridge", "backend-init", "success");

    // From this point the Racket ports created by serve-fds own the native
    // endpoints and close them during server teardown.
    server->release();
    (void)racket_apply(procedure, args);
    Sscheme_deinit();
    emit_diagnostic(
        "racket-backend", "backend-exit",
        stopping_.load(std::memory_order_acquire) ? "success" : "failure",
        stopping_.load(std::memory_order_acquire)
            ? ""
            : "backend returned before native shutdown");
  } catch (...) {
    emit_diagnostic(initialized ? "racket-backend" : "abi-bridge",
                    initialized ? "backend-exit" : "backend-init", "failure",
                    exception_message(std::current_exception()));
    // The platform endpoints close both descriptors for native startup
    // failures. Once they are transferred, serve-fds owns their lifetime on
    // the Racket side. Closing the server ends makes the native reader
    // observe EOF.
  }

  running_.store(false, std::memory_order_release);
}

void EmbeddedBackendCore::reader_main() noexcept {
  try {
    for (;;) {
      Transport* transport = nullptr;
      {
        std::lock_guard lock(state_mutex_);
        transport = transport_.get();
      }
      if (transport == nullptr) {
        break;
      }

      auto frame = read_frame(*transport);
      if (!frame.has_value()) {
        if (!stopping_.load(std::memory_order_acquire)) {
          emit_diagnostic("transport", "channel-closed", "failure",
                          "Rivet transport closed unexpectedly");
        }
        break;
      }

      switch (frame->type) {
        case MessageType::Hello:
          note_protocol_event("hello");
          accept_hello(*frame);
          break;
        case MessageType::Response:
          note_protocol_event("response");
          emit_diagnostic("native-client", "rpc-dispatch", "success", "",
                          frame->id);
          completions_.resolve(frame->id, decode_value(frame->payload));
          break;
        case MessageType::Error: {
          note_protocol_event("error");
          auto error_value = decode_value(frame->payload);
          std::string message{"Rivet backend error"};
          if (auto* text = std::get_if<std::string>(&error_value.data)) {
            message = *text;
          }
          emit_diagnostic("racket-backend", "rpc-dispatch", "failure",
                          message, frame->id);
          completions_.fail(
              frame->id,
              std::make_exception_ptr(std::runtime_error(std::move(message))));
          break;
        }
        case MessageType::Event:
          note_protocol_event("event");
          deliver_event(decode_value(frame->payload));
          break;
        default:
          throw std::runtime_error("unexpected Rivet message from backend");
      }
    }

    if (!hello_seen_.load(std::memory_order_acquire)) {
      set_ready_exception(stopped_error());
    }
  } catch (...) {
    emit_diagnostic("protocol", "reader-loop", "failure",
                    exception_message(std::current_exception()));
    set_ready_exception(std::current_exception());
    completions_.reject_all(std::current_exception());
  }

  running_.store(false, std::memory_order_release);
  completions_.reject_all(stopped_error());
}

void EmbeddedBackendCore::accept_hello(Frame const& frame) {
  auto hello = decode_value(frame.payload);
  auto const* list = std::get_if<Value::List>(&hello.data);
  if (list == nullptr || list->size() != 2) {
    throw std::runtime_error("invalid Rivet Hello payload");
  }

  auto const* name = std::get_if<std::string>(&(*list)[0].data);
  auto const* version = std::get_if<std::int64_t>(&(*list)[1].data);
  if (name == nullptr || *name != "rivet" || version == nullptr ||
      *version != kProtocolVersion) {
    throw std::runtime_error("Rivet protocol handshake mismatch");
  }

  bool expected = false;
  if (!hello_seen_.compare_exchange_strong(expected, true,
                                           std::memory_order_acq_rel)) {
    throw std::runtime_error("duplicate Rivet Hello frame");
  }
  ready_->set_value();
}

void EmbeddedBackendCore::deliver_event(Value value) noexcept {
  try {
    auto const* list = std::get_if<Value::List>(&value.data);
    if (list == nullptr || list->size() != 2) {
      return;
    }
    auto const* name = std::get_if<std::string>(&(*list)[0].data);
    if (name == nullptr) {
      return;
    }

    EventHandler handler;
    {
      std::lock_guard lock(event_mutex_);
      handler = event_handler_;
    }
    if (handler) {
      try {
        handler(*name, (*list)[1]);
      } catch (...) {
        // Application event handlers are isolated from the transport loop.
      }
    }
  } catch (...) {
    // Malformed events are ignored; request/response transport stays alive.
  }
}

void EmbeddedBackendCore::set_ready_exception(std::exception_ptr error) noexcept {
  bool expected = false;
  if (hello_seen_.compare_exchange_strong(expected, true,
                                          std::memory_order_acq_rel)) {
    try {
      ready_->set_exception(error);
    } catch (...) {
    }
  }
}

}  // namespace rivet::detail
