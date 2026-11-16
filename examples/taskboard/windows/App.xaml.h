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
  // Only instantiated by the packaged Windows native UI icon regression.
  Microsoft::UI::Xaml::Window icon_probe_window_{nullptr};
};

}  // namespace winrt::RivetHost::implementation
