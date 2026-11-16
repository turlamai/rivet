#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"
#include "system_services.hpp"

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

void App::OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&) {
  // MSI URL/file associations pass their arguments to the new process.
  // Capture before constructing the WinUI window and starting Racket CS.
  // The native inbox does not execute these untrusted strings as RPCs.
  window_ = winrt::make<MainWindow>(rivet::system::ActivationArguments());
  window_.Activate();
}

}  // namespace winrt::RivetHost::implementation
