#include "backend.hpp"

#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

#include "rivet/protocol.hpp"

namespace rivet::linux_runtime {
namespace {

class UniqueFd {
 public:
  UniqueFd() = default;
  explicit UniqueFd(int fd) : fd_(fd) {}
  ~UniqueFd() { reset(); }

  UniqueFd(UniqueFd const&) = delete;
  UniqueFd& operator=(UniqueFd const&) = delete;

  UniqueFd(UniqueFd&& other) noexcept : fd_(other.release()) {}
  UniqueFd& operator=(UniqueFd&& other) noexcept {
    if (this != &other) {
      reset(other.release());
    }
    return *this;
  }

  int get() const noexcept { return fd_; }

  int release() noexcept {
    auto const result = fd_;
    fd_ = -1;
    return result;
  }

  void reset(int fd = -1) noexcept {
    if (fd_ >= 0) {
      (void)::close(fd_);
    }
    fd_ = fd;
  }

 private:
  int fd_{-1};
};

// One end for the native transport plus the two descriptors serve-fds reads
// and writes.
struct SocketEndpoints {
  UniqueFd native;
  UniqueFd server_read;
  UniqueFd server_write;
};

SocketEndpoints create_socket_endpoints() {
  int fds[2]{-1, -1};
#if defined(SOCK_CLOEXEC)
  int const rc = ::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, fds);
#else
  int const rc = ::socketpair(AF_UNIX, SOCK_STREAM, 0, fds);
#endif
  if (rc != 0) {
    throw std::runtime_error("socketpair failed: " +
                             std::string(std::strerror(errno)));
  }

  UniqueFd native(fds[0]);
  UniqueFd server_read(fds[1]);
#if !defined(SOCK_CLOEXEC)
  // Platforms without SOCK_CLOEXEC (macOS): set the flag on both ends right
  // after the pair exists. Own the descriptors first so an fcntl failure
  // cannot leak either endpoint while the exception unwinds.
  for (int const fd : {native.get(), server_read.get()}) {
    int const flags = ::fcntl(fd, F_GETFD, 0);
    if (flags < 0 || ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != 0) {
      throw std::runtime_error("fcntl(FD_CLOEXEC) failed: " +
                               std::string(std::strerror(errno)));
    }
  }
#endif
  UniqueFd server_write(::dup(server_read.get()));
  if (server_write.get() < 0) {
    throw std::runtime_error("dup failed: " +
                             std::string(std::strerror(errno)));
  }
  if (::fcntl(server_write.get(), F_SETFD, FD_CLOEXEC) != 0) {
    throw std::runtime_error("fcntl(FD_CLOEXEC) failed: " +
                             std::string(std::strerror(errno)));
  }
  return SocketEndpoints{std::move(native), std::move(server_read),
                         std::move(server_write)};
}

class FdTransport final : public rivet::Transport {
 public:
  explicit FdTransport(UniqueFd fd) : fd_(std::move(fd)) {}

  bool read_exact(std::uint8_t* destination, std::size_t size) override {
    std::size_t done = 0;
    while (done < size) {
      auto const count = ::read(fd_.get(), destination + done, size - done);
      if (count == 0) {
        if (done == 0) {
          return false;
        }
        throw std::runtime_error("unexpected EOF in RVT1 frame");
      }
      if (count < 0) {
        if (errno == EINTR) {
          continue;
        }
        throw std::runtime_error("RVT1 transport read failed: " +
                                 std::string(std::strerror(errno)));
      }
      done += static_cast<std::size_t>(count);
    }
    return true;
  }

  void write_all(std::uint8_t const* source, std::size_t size) override {
    std::size_t done = 0;
    while (done < size) {
      auto const count =
          ::send(fd_.get(), source + done, size - done, MSG_NOSIGNAL);
      if (count == 0) {
        throw std::runtime_error("RVT1 transport write made no progress");
      }
      if (count < 0) {
        if (errno == EINTR) {
          continue;
        }
        throw std::runtime_error("RVT1 transport write failed: " +
                                 std::string(std::strerror(errno)));
      }
      done += static_cast<std::size_t>(count);
    }
  }

  void flush() override {}

 private:
  UniqueFd fd_;
};

// The two descriptors serve-fds reads and writes. They refer to the same
// full-duplex socket and are distinct from the native transport end.
class SocketServerEndpoints final : public detail::ServerEndpoints {
 public:
  SocketServerEndpoints(UniqueFd read, UniqueFd write)
      : read_(std::move(read)), write_(std::move(write)) {}

  intptr_t read_descriptor() const noexcept override { return read_.get(); }

  intptr_t write_descriptor() const noexcept override { return write_.get(); }

  void release() noexcept override {
    (void)read_.release();
    (void)write_.release();
  }

 private:
  UniqueFd read_;
  UniqueFd write_;
};

detail::EmbeddedChannel open_channel() {
  auto endpoints = create_socket_endpoints();
  detail::EmbeddedChannel channel;
  channel.transport = std::make_unique<FdTransport>(std::move(endpoints.native));
  channel.server = std::make_unique<SocketServerEndpoints>(
      std::move(endpoints.server_read), std::move(endpoints.server_write));
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

}  // namespace rivet::linux_runtime
