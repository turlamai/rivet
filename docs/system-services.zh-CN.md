# 系统服务

[English](system-services.md) · **简体中文**

商业桌面能力位于 `rivet/system` 和原生平台适配器中，而不是 RVT1。这个边界让嵌入式传输
保持小巧，并让 UI 线程和生命周期所有权显式化。

## 共享 API

`rivet/system` 导出单实例获取与激活路由、系统通知、托盘/菜单栏配置、登录/自启动控制、
安全二进制秘密存储、原子 JSON 设置、结构化日志，以及提供方中立的崩溃报告钩子。

生成的原生宿主直接调用第一方 Swift/C++ 系统库，运行在拥有该操作的 UI 或生命周期线程上。
它们不会把 Racket 过程安装到嵌入运行时，系统服务也不扩展 RVT1。Racket 侧提供方和无头测试
可以参数化 `current-system-adapter`；没有提供方时，Racket 便捷过程会明确失败，而不是静默
使用不安全存储或假通知。

### 跨平台全局快捷键

每个适配器都通过相同的回调形状报告激活——快捷键 id、平台毫秒时间戳和激活 token（仅 portal
平台；其他平台为空）——因此宿主共享同一条分发路径。直接注册平台（macOS、Windows）使用
共享的触发器语法：大小写不敏感的 `'+'` 分隔修饰键（`ctrl|control`、`alt|option`、
`shift`、`cmd|command|meta|super|win`）和恰好一个键（`a`–`z`、`0`–`9`、`f1`–`f24`、
`space`、`tab`、`enter|return`、`escape|esc`、`backspace`、`delete|del`、`insert`、
`home`、`end`、`pageup`、`pagedown`、方向键和常见标点名称）。两个适配器都拒绝重复 id 和
重复的生效触发器。Linux 有意不同：Wayland 没有全局 grab，因此绑定走合成器的 portal 提示，
最终触发器由合成器拥有。

### 跨平台剪贴板

原生适配器契约有意只支持纯文本：读取最新文本、用文本替换剪贴板、观察所有权/内容变化。
内嵌 NUL 字符会被拒绝，因为 Win32 和 GTK 表示以 NUL 结尾。剪贴板没有文本表示时，变化回调
不接收值。原生对象属于创建它的 UI 线程；对象销毁时观察停止。

Linux 异步读取，因为 Wayland 按需从当前所有者传输剪贴板内容。因此其回调还携带错误字符串，
把“不是文本”与传输失败区分开。Windows 和 macOS 读取是同步平台调用。快于观察者消费速度的
变化可能被合并；这是状态通知，不是无损历史流。

### 跨平台原生文件对话框

每个桌面适配器都暴露第一方打开、保存和文件夹选择对话框，支持文件扩展名过滤和可选的打开
多选。取消是正常的空结果；实际平台或传输失败仍可区分。对话框属于 UI 线程，可挂到原生应用
窗口作为 parent。

适配器只返回本地文件系统路径。Windows 使用 Common Item Dialog
（`IFileOpenDialog` / `IFileSaveDialog`），macOS 使用异步 `NSOpenPanel` /
`NSSavePanel`，Linux 使用 GTK4 `GtkFileDialog`（GTK 4.10+），在可用时委托给桌面 portal。
如果提供方返回非本地资源，Linux 会报告明确错误，而不是把其 URI 假装成文件系统路径。

## Windows

`platform/windows/system` 使用第一方 Win32 表面：

- 命名 mutex 用于进程唯一性；
- 命令行激活，用于 MSI 注册的 URL scheme 和文件关联；
- `Shell_NotifyIconW` 用于托盘存在和通知气泡，另有 `TrayController` 拥有窗口 subclass、
  原生弹出菜单、命令路由和 `TaskbarCreated` 恢复；
- `GlobalShortcuts` 基于 `RegisterHotKey`：每个实例一个 message-only 窗口，`WM_HOTKEY`
  分发到共享激活回调形状。`ParseTrigger` 实现跨平台触发器语法；在泵送窗口消息的线程
  （生成宿主中的 WinUI 线程）注册和注销；
- `Clipboard` 基于 `CF_UNICODETEXT`，使用 message-only owner 窗口和
  `AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE` 观察；
- `FileDialogs` 基于 Common Item Dialog，包括打开多选、文件夹选择、保存建议和扩展名过滤；
- 当前用户的 `Run` 注册表值用于可选自启动；
- Windows Credential Manager（`CredWriteW`/`CredReadW`）用于秘密；
- `SetUnhandledExceptionFilter` 和 `RegisterApplicationRestart` 作为底层崩溃/重启钩子。

宿主拥有窗口句柄，并在其 WinUI 线程接收托盘回调。只有宿主有意拥有全部消息路由时才使用
底层 `TrayIcon`。常规托盘常驻宿主使用 `TrayController`：传入本地化 `TrayMenuItem` 标签和
应用回调，并在其 `HWND` 之前销毁 controller。controller 安装/移除 `SetWindowSubclass`，
Explorer 重启后恢复图标，在 `TrackPopupMenu` 之前调用 `SetForegroundWindow` 以便外部点击
关闭弹窗，并且只路由自己的菜单命令标识符。回调异常绝不会穿过 Win32 消息过程展开。参考
Taskboard 是可执行配方。

应用可以把内置崩溃回调替换为 Crashpad、Sentry、私有端点，或完全不上传；Rivet 不绑定任何
提供方。

## macOS

`RivetSystem` 使用 AppKit 和 Apple 系统框架：

- 进程死亡时自动释放的操作系统文件锁；
- SwiftUI `onOpenURL` 加随包 `CFBundleURLTypes`/`CFBundleDocumentTypes` 元数据；
- `UNUserNotificationCenter`；
- `NSStatusItem` 用于菜单栏 UI；
- `RivetGlobalShortcuts` 基于 Carbon `RegisterEventHotKey`：直接注册，使用共享触发器语法
  和回调形状，激活在主线程事件循环上。`parse(_:)` 通过 Carbon 常量映射 ANSI 虚拟键码——
  这些码跟随物理 QWERTY 布局而非字母表——并公开用于测试和触发器渲染；
- `RivetClipboard` 基于 `NSPasteboard`，在主 run loop 轮询 `changeCount`（AppKit 不发布
  pasteboard 变化通知）；
- `RivetFileDialogs` 基于异步 AppKit 打开/保存面板，可选择性作为 supplied `NSWindow` 的
  sheet 呈现；
- `SMAppService.mainApp` 用于登录项注册；
- Security.framework Keychain generic-password 条目；
- 保持在 main actor 上的激活路由。

macOS 会按操作系统要求询问通知和登录项同意。代码不得把拒绝当作崩溃。

`UserNotifications` 只对带应用标识符的已打包 `.app` 可用。`RivetNotifications.isAvailable`
报告运行进程是否具有该身份。因此 `.rivet/stage/RivetHost` 等开发可执行文件从
`requestAuthorization()` 返回 `false`，`show(...)` 抛出可捕获的
`RivetSystemError.notificationsUnavailable`，而不是进入 `UNUserNotificationCenter` 并触发
Objective-C 异常。

## Linux

`platform/linux/system` 使用第一方 Linux 桌面表面，按与其他平台相同的独立性规则选择：

- 抽象命名空间 Unix socket 用于单实例 lease；secondary 通过该 socket 把激活参数转发给
  primary；
- `ActivationArguments()` 从 `/proc/self/cmdline` 读取安装器注册的 URL scheme 和文件关联
  负载；
- 会话总线上的 `org.freedesktop.Notifications`（GDBus），带稳定通知 id 以支持标记替换；
- `GlobalShortcuts`——异步 `org.freedesktop.portal.GlobalShortcuts` 会话 API。`support()`
  暴露 portal 版本，`bind(...)` 在不阻塞 GTK 主上下文的情况下报告 bound、cancelled、
  unavailable 和 failed 结果，激活回调保留合成器时间戳和激活 token。最终快捷键由合成器
  拥有，可能替换或拒绝应用偏好的触发器。Rivet 不回退到 `XGrabKey`；没有该 portal 的会话
  上的应用可以暴露既有的单实例激活命令（例如可执行的 `--toggle` 动作），让用户在合成器
  设置中绑定；
- `Clipboard`——在宿主的 GTK 主上下文上进行 GTK4/GDK 文本读取、写入和 `changed` 观察；
  能力发现只有在交互式显示初始化后才报告它；
- `FileDialogs`——GTK4 原生打开/保存/文件夹选择器，带 portal 委托、过滤、多选和主上下文
  上的异步完成；
- `TrayIcon`——org.kde.StatusNotifierItem 加 com.canonical.dbusmenu 菜单，通过会话总线
  （GDBus）。这是显式 opt-in，不是适配器默认行为：桌面托管依赖合成器（GNOME 只有通过
  AppIndicator 扩展才托管，KDE 原生支持），因此应用检查 `TrayIcon::available()`（或
  `tray` 能力）后决定。图标、tooltip 和扁平菜单（带标签项、分隔符、enabled 状态）原地
  更新；watcher 在重新出现时重新注册，因此 GNOME Shell 重启和扩展重载不会让运行中的进程
  丢失图标。方法和菜单回调在构造图标时的 thread-default 主上下文上运行——对 GTK 宿主
  就是主循环线程；
- `$XDG_CONFIG_HOME/autostart` 下的 XDG autostart 条目；
- 通过 libsecret 的 Secret Service 提供方（GNOME Keyring、KWallet bridge）用于二进制秘密；
  libsecret 存在时能力被编译进来，只有在提供方可达时才在运行时报告；
- `sigaction` 致命信号钩子，向 XDG state 目录下的文件追加预格式化说明（信号编号加重启
  参数）。

`rivet::system::Capabilities()` 报告运行会话实际提供的能力；缺少会话总线、Secret Service
提供方或 libsecret 构建时会在调用时明确失败，而不是静默降级。

只有在嵌入 backend 的 `start()` 完成 Hello 握手之后才安装
`rivet::system::InstallShutdownHook`。`racket_boot` 在启动期间建立 Racket CS 信号处理；
过早安装应用钩子会让该初始化替换它，把 `SIGTERM` 变成 backend break，而 GTK 主循环仍然
存活。生成的宿主和参考 Taskboard 强制这个顺序，deb 生命周期门禁会向已安装应用发送真实
`SIGTERM`。

Linux 集成二进制自检适配器（`RivetIntegration --system`）：lease 获取和激活转发、autostart
条目和崩溃钩子总会运行；通知、托盘和安全存储检查在会话缺少相应服务时自行跳过。一个独立的
封闭测试启动私有 D-Bus 会话和 mock GlobalShortcuts portal，然后校验发现、会话创建、绑定
结果和激活投递，不依赖特定 CI 桌面。

## 设置、日志与崩溃

`make-settings-store` 返回不透明句柄，读取 JSON 对象，并在共享进程内信号量和操作系统文件锁
下通过原子替换写入更新。操作会在事务内刷新，因此多个句柄和协作进程不会用陈旧缓存互相覆盖。
快照和存储的 JSON 树深度不可变；调用方无法在同步边界周围修改缓存状态。持久空 `.lock`
同级文件不携带事务状态。使用 `settings-ref`、`settings-set!`、`settings-remove!` 和
`settings-snapshot`。应用选择路径，通常是其平台 Application Support/AppData 目录
（Linux 上是 XDG state 或 config 目录下的文件）。秘密不属于设置；请使用安全存储。

`rivet-log` 向 `current-rivet-log-sink` 发出结构化记录；`make-rotating-log-sink` 是
可选的、有界的 JSONL 文件 sink，支持按大小轮转和私有权限；`make-crash-file-reporter` 把未捕获的 Racket 异常写成同样的有界记录。`call-with-crash-reporting` 记录
逃逸的 Racket 异常，并在重新抛出前调用 `current-rivet-crash-reporter`。原生致命钩子有意
保持最小：崩溃处理器必须避免分配和网络访问，然后让 helper 在下次启动时提交报告。
