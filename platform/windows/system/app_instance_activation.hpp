#pragma once

// Windows App SDK owns instance identity and asynchronous redirection. Keep
// product-owned URL/file interpretation separate from OS delivery: these are
// untrusted native activation values, not authorized Racket RPC arguments.
#include <shellapi.h>

#include <winrt/Microsoft.Windows.AppLifecycle.h>
#include <winrt/Windows.ApplicationModel.Activation.h>
#include <winrt/Windows.Storage.h>

#include <string>
#include <vector>

namespace rivet::system {

inline std::vector<std::wstring> RedirectedActivationArguments(
    winrt::Microsoft::Windows::AppLifecycle::AppActivationArguments const&
        activation) {
  namespace lifecycle = winrt::Microsoft::Windows::AppLifecycle;
  namespace platform_activation = winrt::Windows::ApplicationModel::Activation;
  std::vector<std::wstring> result;
  if (!activation) return result;

  // The App SDK normalizes file/protocol activations differently from
  // conventional command-line launches. Preserve their raw UTF-16 values.
  if (activation.Kind() == lifecycle::ExtendedActivationKind::Protocol) {
    if (auto protocol =
            activation.Data().try_as<platform_activation::IProtocolActivatedEventArgs>()) {
      if (auto uri = protocol.Uri()) result.emplace_back(uri.RawUri().c_str());
    }
  } else if (activation.Kind() == lifecycle::ExtendedActivationKind::File) {
    if (auto file =
            activation.Data().try_as<platform_activation::IFileActivatedEventArgs>()) {
      for (auto const& item : file.Files()) {
        auto path = item.Path();
        if (!path.empty()) result.emplace_back(path.c_str());
      }
    }
  } else if (activation.Kind() == lifecycle::ExtendedActivationKind::Launch) {
    if (auto launch =
            activation.Data().try_as<platform_activation::ILaunchActivatedEventArgs>()) {
      // The Windows App SDK exposes the original Win32 full command line.
      // Decode Windows quoting rules instead of splitting on spaces.
      auto arguments = launch.Arguments();
      int count = 0;
      auto parsed = ::CommandLineToArgvW(arguments.c_str(), &count);
      if (parsed != nullptr) {
        for (int index = 1; index < count; ++index) {
          result.emplace_back(parsed[index]);
        }
        ::LocalFree(parsed);
      }
    }
  }
  return result;
}

}  // namespace rivet::system
