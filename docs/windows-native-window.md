# Windows host integration

## Native window handle

WinUI 3 desktop features often need the native `HWND`: global hotkeys,
clipboard listeners, `SetWindowSubclass`, precise `SetWindowPos` placement,
tray icons, and other Win32 ownership APIs all use it.

Generated Rivet windows expose the supported bridge directly:

```cpp
HWND hwnd = WindowHandle();
```

From another window type, call the underlying helper after that window has
run `InitializeComponent`:

```cpp
#include "system_services.hpp"

HWND hwnd = rivet::system::NativeWindowHandle(window);
```

The helper uses the Windows App SDK `IWindowNative::get_WindowHandle` ABI and
turns a missing interop interface, failed HRESULT, or null handle into a normal
C++/WinRT exception. The scaffold owns the required
`microsoft.ui.xaml.window.h` include and Windows system-adapter include path,
so product code does not need to recreate projection-specific boilerplate.

Do not find the application's own window by title. `FindWindowW` is ambiguous
when another window has the same title, breaks after localization or title
changes, and races window creation. The WinUI object is the authority for its
native handle.

Use the handle on the UI thread unless the target Win32 API explicitly permits
cross-thread access. Remove listeners, subclasses, and registered hotkeys
before the owning window is destroyed; an `HWND` is not a lifetime-owning
reference.

For tray applications, do not reproduce the `SetWindowSubclass`,
`TaskbarCreated`, `TrackPopupMenu`, and `WM_COMMAND` recipe in each host.
`rivet::system::TrayController` owns that HWND-bound lifecycle. The application
still owns menu semantics by providing localized `TrayMenuItem` values and
callbacks; see the reference Taskboard's `MainWindow.xaml.cpp`.

Example:

```cpp
MainWindow::MainWindow() {
  InitializeComponent();
  auto const hwnd = WindowHandle();
  if (!::AddClipboardFormatListener(hwnd)) {
    winrt::throw_last_error();
  }
}
```

## Application icon for WinUI title bars

Windows App SDK / WinUI 3 does **not** automatically reuse the EXE icon for
each top-level `AppWindow`. Rivet embeds a project-declared `windows-icon`
in the generated Windows executable as icon group resource **ID 1**.
Use the opt-in WinUI header helper on **every titled** window that should
display that product identity:

```cpp
#include "winui_window.hpp"  // platform/windows/system/winui_window.hpp

// Called on the WinUI thread, after InitializeComponent, before or after Activate.
(void)rivet::system::ApplyAppIcon(*this);  // MainWindow or SettingsWindow
```

The helper uses the embedded Win32 icon resource and
`AppWindow.SetIcon(IconId)`, **not** `SetIcon(executable_path)`. The string
overload expects the pathname of a real `.ico` file, not the executable
containing one. `ApplyAppIcon` returns `true` when an embedded icon was
found and applied. It returns `false` if no product icon was embedded,
leaving the native title-bar fallback untouched; callers should not crash
or invent an icon in that case.

`LoadIconW` returns a shared resource handle owned by the loaded EXE.
Do **not** call `DestroyIcon` on it; the executable resource outlives all
Windows App SDK windows in the process. Call from the owning WinUI UI thread.
The API never forces title bars on borderless overlays and does not alter
native title-bar decisions on macOS or Linux.

## Explicit WebView2 environment in an installed WinUI 3 host

An unpackaged WinUI 3 app installed by MSI under `Program Files` must **not**
let WebView2 select its executable-adjacent default user data folder (UDF).
That location is generally not writable by a normal user. A failed automatic
environment creation has also been observed to trigger a NULL-interface crash
inside the WinUI 3 WebView2 control's failure path on Windows ARM64/x64
emulation ([issue #376](https://github.com/turlamai/rivet/issues/376)).
Rivet cannot repair that upstream control crash by catching an RVT1 exception.

Create one stable, per-user UDF under `%LOCALAPPDATA%` **before** setting
`WebView2.Source` or otherwise initiating implicit initialization. Supply it
to an explicitly constructed environment, and pass that environment into
`EnsureCoreWebView2Async`. This C++/WinRT sketch belongs in a native host
coroutine on the WinUI owning thread (replace `browser` and the product path):

```cpp
// Include <ShlObj.h>, <filesystem>, <memory>, and the WinRT WebView2
// Core projection. Never create this folder next to the installed EXE.
PWSTR rawLocalAppData = nullptr;
winrt::check_hresult(::SHGetKnownFolderPath(
    FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &rawLocalAppData));
std::unique_ptr<wchar_t, decltype(&::CoTaskMemFree)>
    ownedLocalAppData(rawLocalAppData, &::CoTaskMemFree);
auto const udf = std::filesystem::path(rawLocalAppData) /
                 L"YourPublisher" / L"YourProduct" / L"WebView2";
std::filesystem::create_directories(udf);

// Inside the UI-thread coroutine, before assigning any WebView2 Source:
using namespace winrt::Microsoft::Web::WebView2::Core;
auto const environment =
    co_await CoreWebView2Environment::CreateWithOptionsAsync(
        L"", winrt::hstring{udf.wstring()},
        CoreWebView2EnvironmentOptions{});
co_await browser.EnsureCoreWebView2Async(environment);
```

Wrap path creation, `CreateWithOptionsAsync`, and
`EnsureCoreWebView2Async` in the host's error-handling boundary; report
failure using **native controls**, not the WebView2 that failed to start.
Do not render remote content or offer destructive UDF deletion as an automatic
retry. The WebView2 runtime, options, and concurrent browser processes must
agree on the selected profile. Never move the UDF into `Program Files`,
make the installation directory writable, or rely solely on
`WEBVIEW2_USER_DATA_FOLDER`: process environment overrides have been
observed to behave differently across launch contexts. Use
`CoreWebView2Environment.UserDataFolder` to verify the effective path.
Define an explicit policy for preserving or removing this profile at uninstall.

**Required acceptance before calling a consumer fixed:** exercise a real
installed MSI under a standard user and a filtered administrator token; a
clean profile; immediate restart after force-termination; an independently
locked UDF; an unwritable UDF; and normal open/navigate/recovery with the
exact packaged WinUI host, including the Windows ARM64/x64-emulation case.
Record the observed UDF path and crash/no-crash behavior. A successful
standalone Racket or development-directory run is insufficient. If the
failure path still dereferences a NULL interface, report it upstream to
Windows App SDK/WebView2 with the isolated dump and minimal repro.

### 中文：WinUI 3 WebView2 数据目录与失败恢复

通过 MSI 安装到 `Program Files` 的非 MSIX WinUI 3 应用，不应依赖
WebView2 位于可执行文件旁的默认用户数据目录。请在首次初始化及设置
`WebView2.Source` **之前**，在 `%LOCALAPPDATA%/发布者/产品/WebView2`
准备可写的用户目录，使用
`CoreWebView2Environment::CreateWithOptionsAsync` 显式创建环境，再传给
`EnsureCoreWebView2Async(environment)`；不能只设置
`WEBVIEW2_USER_DATA_FOLDER` 环境变量。

文件夹创建或浏览器环境初始化失败时，应使用原生 WinUI 控件显示错误及
恢复方式，不能依赖失败的 WebView2，也不能自动清空用户登录信息或放宽
`Program Files` 权限。验证时必须覆盖真实 MSI 安装、普通用户、
受限管理员令牌、强制退出后立即重启、目录占用/不可写及 Windows ARM64
模拟运行。此方法属于应用端预防措施，**不代表微软控件内部的崩溃已经修复**。
问题和验收证据统一跟踪于 [#376](https://github.com/turlamai/rivet/issues/376)。

Microsoft's current references:
[WebView2 user-data-folder guidance](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/user-data-folder) and
[WebView2 in WinUI 3](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/webview2).

## Non-blocking generated API

The generated C++ client exposes two compatible styles for every RPC and
shared State operation. The historical API returns `std::future<T>`:

```cpp
rivet_app::API api(*backend);
auto value = api.increment(41).get();
```

WinUI code should normally use the non-blocking completion companion. It
returns the RVT1 request ID immediately, which also permits cancellation with
`Backend::cancel(id)`:

```cpp
auto id = api.increment_async(
    41,
    [dispatcher](rivet_app::Result<std::int64_t> result) {
      try {
        auto value = result.get();
        dispatcher.TryEnqueue([value] {
          // Update WinUI here.
        });
      } catch (std::exception const& error) {
        // Surface the backend or decoding error.
      }
    });
```

Shared State has the same generated shape, such as
`get_counter_async(...)` and `set_counter_async(value, ...)`.

### Polling the backend

Every RPC also gains a bounded-wait companion, `name_within(arguments,
std::chrono::milliseconds)`. Its completion resolves a promise, so the call
waits up to the timeout and **cancels the pending request on a miss**; Void
RPCs return `bool` (false = timed out), other results return
`std::optional<T>`. Backend and decoding errors still throw from the final
get, matching the blocking call's contract.

```cpp
// A 400 ms UI tick polls without spawning a thread and without blocking
// past the frame budget:
if (auto value = api.increment_within(41, std::chrono::milliseconds{0})) {
  counter_label().Text(std::to_wstring(*value));
}
```

This is the sanctioned shape for long-lived polling UIs. Do not spawn a
detached `std::thread` per tick: each one races the reader thread, leaks
past teardown, and churns a native thread per frame. Prefer completions
when an update push model works; use `_within` when the UI owns a tick
loop, with a zero timeout for a pure poll or a small budget when a
bounded wait is acceptable.

### Threading

RVT1 responses are decoded on Rivet's native reader thread. Normal completion
handlers therefore run there; submission failures or shutdown rejection may
complete on the thread that encountered the failure. Dispatch through
`DispatcherQueue` before touching WinUI objects. Rivet isolates exceptions
thrown by completion handlers, and `Result<T>::get()` rethrows backend or
decoding errors.

The completion path uses the existing pending-request table, request IDs,
cancellation frames, reader thread, and shutdown behavior; it does not create a
native thread per RPC. It intentionally does not return `IAsyncOperation<T>`:
projecting `Bytes`, recursive `List`, `Optional`, and `Any` through a public
WinRT ABI would force platform container policy into Rivet's schema.
