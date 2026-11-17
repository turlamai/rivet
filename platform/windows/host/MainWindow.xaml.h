#pragma once

#include "pch.h"
#include "MainWindow.g.h"
#include "system_services.hpp"
#include "activation_inbox.hpp"
#include "winui_window.hpp"

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();
  explicit MainWindow(std::vector<std::wstring> initial_activations);

  // UI-thread-owned native activation inbox. A product can consume these
  // arguments only after validating the intended file/URL operation.
  [[nodiscard]] std::vector<std::wstring> TakeActivationArguments() {
    return activations_.take();
  }
  // Called only on the WinUI dispatcher after AppLifecycle redirects a
  // second instance. Keep input native until product validation.
  void ReceiveActivationArguments(std::vector<std::wstring> arguments) {
    activations_.push_all(std::move(arguments));
  }

  // Stable HWND access for platform-owned features such as global hotkeys,
  // clipboard listeners, window subclassing, topmost policy, and tray icons.
  [[nodiscard]] HWND WindowHandle() {
    return rivet::system::NativeWindowHandle(*this);
  }

  // Thread-safe orderly backend stop shared by the window-close path and
  // the console-control shutdown hook (logoff/CTRL events).
  void StopBackendOrderly();

  void Increment_Click(winrt::Windows::Foundation::IInspectable const& sender,
                       Microsoft::UI::Xaml::RoutedEventArgs const& args);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  void IncrementAsync();
  void SetReadyUi();
  void SetErrorUi(std::string const& message);

  std::shared_ptr<rivet::windows::Backend> backend_;
  rivet::system::ActivationInbox activations_;
  std::atomic<std::int64_t> count_{0};
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
