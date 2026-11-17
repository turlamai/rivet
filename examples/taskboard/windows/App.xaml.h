#pragma once

#include "pch.h"
#include "App.xaml.g.h"
#include "../../../platform/windows/system/activation_inbox.hpp"
#include <winrt/Microsoft.Windows.AppLifecycle.h>
#include <string>
#include <vector>

namespace winrt::RivetHost::implementation {

struct App : AppT<App> {
  App();
  ~App();
  void OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&);

 private:
  void OpenPrimaryWindow(std::vector<std::wstring> initial_arguments);
  Microsoft::UI::Xaml::Window window_{nullptr};
  // The AppInstance key may be registered before the first window exists.
  // Queue early redirected activations instead of dropping them; the window
  // transfers ownership after construction. Main WinUI dispatcher only.
  rivet::system::ActivationInbox pending_activations_;
  winrt::Microsoft::Windows::AppLifecycle::AppInstance primary_instance_{nullptr};
  winrt::event_token redirected_token_{};
  bool has_redirected_subscription_{false};
  // Keep the secondary redirect operation alive until its completion callback
  // has acknowledged delivery or opened the visible failure fallback.
  winrt::Windows::Foundation::IAsyncAction pending_redirect_{nullptr};
  // Only instantiated by the packaged Windows native UI icon regression.
  Microsoft::UI::Xaml::Window icon_probe_window_{nullptr};
};

}  // namespace winrt::RivetHost::implementation
