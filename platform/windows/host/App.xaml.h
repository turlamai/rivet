#pragma once

#include "pch.h"
#include "App.xaml.g.h"
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
  winrt::Microsoft::Windows::AppLifecycle::AppInstance primary_instance_{nullptr};
  winrt::event_token redirected_token_{};
  bool has_redirected_subscription_{false};
  // Keep the secondary redirect operation alive until its completion callback
  // has acknowledged delivery or opened the visible failure fallback.
  winrt::Windows::Foundation::IAsyncAction pending_redirect_{nullptr};
};

}  // namespace winrt::RivetHost::implementation
