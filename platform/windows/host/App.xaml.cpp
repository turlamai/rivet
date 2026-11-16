#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"
#include "system_services.hpp"
#include "GeneratedBackend.hpp"
#include "app_instance_activation.hpp"

namespace winrt::RivetHost::implementation {

App::App() {
  InitializeComponent();

#if defined(_DEBUG) && !defined(DISABLE_XAML_GENERATED_BREAK_ON_UNHANDLED_EXCEPTION)
  UnhandledException([](winrt::Windows::Foundation::IInspectable const&,
                        Microsoft::UI::Xaml::UnhandledExceptionEventArgs const& e) {
    if (::IsDebuggerPresent()) {
      auto const message = e.Message();
      (void)message;
      __debugbreak();
    }
  });
#endif
}

App::~App() {
  if (has_redirected_subscription_ && primary_instance_) {
    primary_instance_.Activated(redirected_token_);
  }
}

void App::OpenPrimaryWindow(std::vector<std::wstring> initial_arguments) {
  window_ = winrt::make<MainWindow>(std::move(initial_arguments));
  window_.Activate();
}

void App::OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&) {
  namespace lifecycle = winrt::Microsoft::Windows::AppLifecycle;
  // Read the process's own Unicode activation before starting Racket. A
  // redirected activation arrives separately through AppInstance.Activated.
  auto initial_arguments = rivet::system::ActivationArguments();
  auto dispatcher =
      winrt::Microsoft::UI::Dispatching::DispatcherQueue::GetForCurrentThread();
  try {
    auto current = lifecycle::AppInstance::GetCurrent();
    auto activation = current.GetActivatedEventArgs();
    // Keying by generated identity avoids different Rivet apps claiming a
    // shared "single-instance" endpoint in the same user session.
    auto selected = lifecycle::AppInstance::FindOrRegisterForKey(
        winrt::to_hstring(rivet_app::kIdentifier));
    if (!selected.IsCurrent() && activation) {
      pending_redirect_ = selected.RedirectActivationToAsync(activation);
      pending_redirect_.Completed([this, dispatcher,
                          fallback = std::move(initial_arguments)](
                             auto const& finished, auto const&) mutable {
        bool delivered = false;
        try {
          finished.GetResults();
          delivered = true;
        } catch (...) {
          // Do not silently discard an activation on a broken redirect.
        }
        dispatcher.TryEnqueue(
            [this, delivered, fallback = std::move(fallback)]() mutable {
              pending_redirect_ = nullptr;
              if (delivered) {
                Microsoft::UI::Xaml::Application::Current().Exit();
              } else if (!window_) {
                OpenPrimaryWindow(std::move(fallback));
              }
            });
      });
      return;
    }
    if (selected.IsCurrent()) {
      primary_instance_ = current;
      redirected_token_ = primary_instance_.Activated(
          [this, dispatcher](auto const&,
                             lifecycle::AppActivationArguments const& redirected) {
            auto arguments = rivet::system::RedirectedActivationArguments(redirected);
            dispatcher.TryEnqueue([this, arguments = std::move(arguments)]() mutable {
              if (!window_) return;  // UI dispatcher is shutting down.
              auto projected = window_.as<winrt::RivetHost::MainWindow>();
              winrt::get_self<MainWindow>(projected)->ReceiveActivationArguments(
                  std::move(arguments));
              window_.Activate();
            });
          });
      has_redirected_subscription_ = true;
    }
  } catch (winrt::hresult_error const&) {
    // AppLifecycle may be unavailable on a development machine. Keep a
    // visible process with its own startup payload instead of failing boot.
  }
  OpenPrimaryWindow(std::move(initial_arguments));
}

}  // namespace winrt::RivetHost::implementation
