#include "backend.hpp"
#include "win32_pipe_transport.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

namespace rivet::windows {
namespace {

class UniqueHandle {
 public:
  UniqueHandle() = default;
  explicit UniqueHandle(HANDLE handle) : handle_(handle) {}
  ~UniqueHandle() { reset(); }

  UniqueHandle(UniqueHandle const&) = delete;
  UniqueHandle& operator=(UniqueHandle const&) = delete;

  UniqueHandle(UniqueHandle&& other) noexcept : handle_(other.release()) {}
  UniqueHandle& operator=(UniqueHandle&& other) noexcept {
    if (this != &other) {
      reset(other.release());
    }
    return *this;
  }

  HANDLE get() const noexcept { return handle_; }

  HANDLE release() noexcept {
    auto const result = handle_;
    handle_ = INVALID_HANDLE_VALUE;
    return result;
  }

  void reset(HANDLE handle = INVALID_HANDLE_VALUE) noexcept {
    if (handle_ != INVALID_HANDLE_VALUE && handle_ != nullptr) {
      ::CloseHandle(handle_);
    }
    handle_ = handle;
  }

 private:
  HANDLE handle_{INVALID_HANDLE_VALUE};
};

struct PipePair {
  UniqueHandle read;
  UniqueHandle write;
};

PipePair create_pipe() {
  HANDLE read = INVALID_HANDLE_VALUE;
  HANDLE write = INVALID_HANDLE_VALUE;
  if (!::CreatePipe(&read, &write, nullptr, 0)) {
    throw std::runtime_error("CreatePipe failed with Win32 error " +
                             std::to_string(::GetLastError()));
  }
  return PipePair{UniqueHandle(read), UniqueHandle(write)};
}

// The pipe ends serve-fds reads and writes. Rktio identifies them by the
// native HANDLE value, not a CRT fd.
class PipeEndpoints final : public detail::ServerEndpoints {
 public:
  PipeEndpoints(UniqueHandle read, UniqueHandle write)
      : read_(std::move(read)), write_(std::move(write)) {}

  intptr_t read_descriptor() const noexcept override {
    return reinterpret_cast<intptr_t>(read_.get());
  }

  intptr_t write_descriptor() const noexcept override {
    return reinterpret_cast<intptr_t>(write_.get());
  }

  void release() noexcept override {
    (void)read_.release();
    (void)write_.release();
  }

 private:
  UniqueHandle read_;
  UniqueHandle write_;
};

detail::EmbeddedChannel open_channel() {
  auto request_pipe = create_pipe();   // native -> Racket
  auto response_pipe = create_pipe();  // Racket -> native

  detail::EmbeddedChannel channel;
  // Adopt the handles only after the transport exists, so a construction
  // failure cannot leak either pipe end.
  channel.transport = std::make_unique<Win32PipeTransport>(
      response_pipe.read.get(), request_pipe.write.get());
  (void)response_pipe.read.release();
  (void)request_pipe.write.release();
  channel.server = std::make_unique<PipeEndpoints>(std::move(request_pipe.read),
                                                   std::move(response_pipe.write));
  return channel;
}

}  // namespace

Backend::Backend(RacketRuntimeConfig config)
    : impl_(std::make_unique<detail::EmbeddedBackendCore>(
          std::move(config), open_channel)) {}

Backend::~Backend() = default;

void Backend::start() { impl_->start(); }
void Backend::stop() { impl_->stop(); }
bool Backend::running() const noexcept { return impl_->running(); }

PendingCall Backend::request(std::string rpc_name, Value::List arguments) {
  return impl_->request(std::move(rpc_name), std::move(arguments));
}

std::future<Value> Backend::call(std::string rpc_name, Value::List arguments) {
  return impl_->call(std::move(rpc_name), std::move(arguments));
}

std::uint64_t Backend::request_async(std::string rpc_name,
                                     Value::List arguments,
                                     CompletionHandler completion) {
  return impl_->request_async(
      std::move(rpc_name), std::move(arguments), std::move(completion));
}

void Backend::cancel(std::uint64_t request_id) {
  impl_->cancel(request_id);
}

void Backend::set_event_handler(EventHandler handler) {
  impl_->set_event_handler(std::move(handler));
}

}  // namespace rivet::windows
