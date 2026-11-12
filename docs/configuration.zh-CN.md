# 项目配置

[English](configuration.md) · **简体中文**

Rivet 应用由项目根目录的 `rivet.rktd` 文件配置。

用 `raco rivet new` 创建的新项目包含明确的发布身份和部署目标元数据。用 Rivet 0.1 创建的项目仍然有效：缺失的可选字段会获得向后兼容的默认值。

示例：

```racket
#hasheq(
  (name . "hello")
  (display-name . "hello")
  (publisher . "Example Company")
  (version . "0.1.0")
  (build . 1)
  (identifier . "dev.rivet.hello")
  (release-channel . stable)
  (url-schemes . ("hello"))
  (file-associations . (#hasheq((extension . ".hello")
                                (description . "Hello Document"))))
  (resources . ("assets" "locales/en.json"))
  (device-rpcs . (current-score refresh-score))
  (windows-icon . "branding/app.ico")
  (macos-icon . "branding/app.icns")
  (dmg-background . "branding/dmg-background.png")
  (windows-license . "branding/license-page.rtf")
  (windows-installer-bitmaps . (hasheq 'banner "branding/wizard-banner.bmp"
                                       'dialog "branding/wizard-dialog.bmp"))
  (macos-min-version . "14.0")
  (windows-min-version . "10.0.19041.0")
  (backend . "app/backend.rkt")
  (module . "backend")
  (entry . "start")
  (protocol . 1))
```

## 必需设置

- `name` — 应用/项目名称。
- `backend` — Racket 后端模块的相对路径。
- `module` — 嵌入运行时使用的后端模块名。
- `entry` — 导出的后端入口函数。
- `protocol` — Rivet 项目协议版本。当前 Rivet 支持协议 `1`。

## 发布元数据

- `display-name` — 用户可见的应用名称。旧项目默认使用 `name`。
- `publisher` — 供 Windows 安装器元数据和“应用和功能”使用的人类可读发布者。旧项目默认使用 `display-name`；不要在这里填反向域名的 `identifier`。
- `version` — 应用发布版本。旧项目默认为 `0.1.0`。
- `build` — 正的有符号 64 位整数构建号。旧项目默认为 `1`。
- `identifier` — 应用/bundle 标识符。旧项目会推导出 `dev.rivet.<name>`。

这些值会进入打包元数据和生成的原生常量，而不是在平台模板中重复维护。Swift 和 Kotlin 通过 `RivetGeneratedConfig` 暴露它们；C++ 在生成的模块/入口名旁暴露 `kDisplayName`、`kVersion`、`kBuild`、`kIdentifier` 和 `kReleaseChannel`。生成的 macOS 宿主用 `displayName` 作为其 `WindowGroup` 标题。

构建还会为后端代码暂存这份身份信息。应 require `rivet/app-info`（或聚合模块 `rivet`），不要在代码里硬编码第二份版本号：

```racket
(require rivet/app-info)

(define current-version (app-version))
(define update-channel (app-release-channel))
```

`current-app-info` 以 `app-info` 值返回全部六个字段。便捷过程 `app-name`、`app-display-name`、`app-version`、`app-build`、`app-identifier` 和 `app-release-channel` 读取同一份暂存元数据。缺失或格式错误的元数据会显式失败；Rivet 不会从可执行文件名猜测发布身份。

## 分发与激活元数据

- `release-channel` — `stable`、`beta` 或 `dev`，默认 `stable`。该值会签名进入更新清单，并且必须与客户端选择的通道一致。
- `url-schemes` — RFC 3986 scheme 名称列表。打包时会向原生操作系统注册这些 scheme；原生宿主会收到激活事件。
- `file-associations` — 哈希列表，每项包含以 `.` 开头的 `extension` 和可选的 `description`。打包时会生成原生文档/安装器元数据。

这些设置只描述原生注册。它们不会向 RVT1 增加消息，也不会创建共享 UI 抽象。

## 伴随设备 API

- `device-rpcs` — 通过生成的伴随 API 暴露的后端 RPC 符号的显式列表。默认是空列表，因此升级既有项目不会把后端方法暴露给另一台设备。

每个名称都必须对应已声明的 RPC，并符合有界的 RivetDevice 路由语法。被选中的参数/结果类型必须与伴随设备兼容；`Any` 会被拒绝。代码生成会产出 Swift 请求类型、带类型的 `RivetDeviceClient` 方法、`RivetDeviceRouter.registerGeneratedBackend`，以及基于已认证 Android `RivetClient` 的 Kotlin `RivetDeviceAPI` 包装。Kotlin 包装只包含白名单中的方法；即使应用代码绕过生成的客户端，桌面网关仍是权威的作用域检查。导出的名称会进入 `rivet-schema.json`：删除一个是破坏性变更，增加一个是兼容变更。参见[带类型的设备通信](device-communication.md)。

## macOS bundle 本地化

如果应用内字符串已经跟随用户语言，在 `rivet.rktd` 中声明

```
(macos-localizations "zh-Hans" "en")
```

（BCP 47 标识符）。不声明时，bundle 构建结果与之前逐字节相同，AppKit 会用开发区域语言渲染所有系统提供的字符串——About / Hide / Quit、标准警告框、SwiftUI 导航提示。声明后，`CFBundleLocalizations` 会写入 Info.plist，打包会在签名前放置标记文件 `Contents/Resources/<lang>.lproj/InfoPlist.strings`（无需重新签名），于是 `CFBundleCopyBundleLocalizations` 能解析用户语言，系统界面也会与应用内字符串保持一致。只声明应用本身已经提供的语言。

## 应用资源与图标

- `resources` — 项目相对的文件或目录列表，会按原相对路径复制到应用资源根目录。生成/控制根目录（`.git`、`.rivet`、`build`、`dist`）和符号链接会被拒绝，以免发布时意外带入仓库元数据、过期输出或项目之外的文件。
- `windows-icon` — 可选的项目相对 `.ico` 文件，编译进新生成的 Windows 宿主。缺少该项时构建会警告：exe 将不带嵌入图标发布。
- `macos-icon` — 可选的项目相对 `.icns` 文件，复制进 app bundle 并通过 `CFBundleIconFile` 声明。缺少该项时打包会警告：bundle 将不带 Dock/Finder 图标发布。
- `linux-icon` — 可选的项目相对 `.png` 文件，安装为桌面图标（`/usr/share/pixmaps`，由生成的 `.desktop` 条目引用），并作为 AppImage 顶层图标。AppImage 打包缺少它会失败关闭；deb 和 rpm 会警告并在没有桌面图标的情况下安装。
- `linux-desktop-id` — 可选的已安装 `.desktop` 文件反向域名 basename，例如
  `org.example.MyApp`。为兼容早期安装器，默认使用项目名。在 Wayland 下该 basename
  就是 portal 身份，因此当应用使用 GNOME `GlobalShortcuts` 或其他对身份敏感的
  portal 时应显式设置。必须匹配
  `^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z][A-Za-z0-9_-]*)+$`。
- `linux-binary-name` — 可选的已安装可执行文件名，例如 `fulcrum`。默认
  `RivetHost`，使既有项目构建结果不变；必须匹配
  `^[A-Za-z0-9][A-Za-z0-9._-]*$`。该值会贯穿 build、package、verify、启动
  冒烟测试和生成的 `.desktop` 条目。
- `linux-formats` — 可选子集 `("deb" "rpm" "appimage")`，选择 `raco rivet release` 构建哪些原生 Linux 安装格式。默认三种都构建；签名的 tar.gz 更新负载无论如何都会生成。
- `share-paths` — 可选的路径列表，列出来自共享盘或映射盘的绝对路径或项目相对路径。`raco rivet doctor` 会在 `network-shares` 中报告每个路径的 redirector 状态，并在映射盘状态不是 `OK` 时给出 `unreachable-network-share` 警告，且不会触碰该共享盘。产品还应使用 `rivet/share-watch` 门禁共享盘相关操作；见[诊断](diagnostics.zh-CN.md#windows-网络共享盘)。
- `macos-resource-files` — 唯一项目相对文件的列表，会在签名前原样复制到 macOS bundle 的 `Contents/Resources` 根目录。典型消费者是 `InternetAccessPolicy.plist`：Little Snitch 类防火墙会从资源根读取它，并向用户展示按主机的用途和拒绝后果。名称与 rivet 管理的 bundle 文件（打包的图标）冲突时会失败关闭。
- `dmg-background` — 可选的项目相对 `.png`，用作 DMG 窗口背景。声明后 `raco rivet release` 会切换到品牌化拖拽安装布局：卷内有 `/Applications` 符号链接，DMG 窗口固定为 660x400 几何尺寸并放置两个图标。PNG 应按 1320x800（窗口的 2 倍）渲染以在 Retina 上保持清晰；宽高比必须与窗口一致，打包器会把暂存副本降采样到 660x400，因为 Finder 按原生像素绘制背景而不缩放（否则会裁切布局）。保留底部约 28pt 空白（窗口边界包含标题栏），并让图标标签区域保持空闲。不声明该项时 DMG 保持普通单文件夹镜像。
- `windows-license` — 可选的项目相对 `.rtf` 文件，显示在 MSI 向导的许可页。不声明时，发布流水线会把仓库 `LICENSE` 文本（或 `LICENSE.txt`/`COPYING`）自动渲染成 RTF；两者都没有的项目会发布一条中性提示，指向随应用安装的许可证。
- `windows-installer-bitmaps` — 可选哈希，`banner` 和 `dialog` 值指定 MSI 向导使用的项目相对 `.bmp` 文件（分别为 493x58 和 493x312）。未设置的值保留向导内置图稿。

打包后的资源位于平台资源根下的 `app/` 中。Racket 代码应使用 `rivet/resources` 的 `resource-path`（`rivet` 也会重新导出），不要猜测可执行文件相对路径。该根目录下的文件名 `rivet-app-info.rktd` 保留给 Rivet 生成的应用身份：

```racket
(require rivet/resources)

(define defaults
  (call-with-input-file (resource-path "config" "defaults.rktd") read))
```

macOS 宿主包中的 SwiftPM `resources` 声明与打包不兼容：`Bundle.module` 会在 `Contents/` 旁的 `.app` 根目录寻找其 bundle，那是 `codesign` 会拒绝的未封装内容，而且生成的 bundle 本身不是可签名 bundle。因此当 Swift 包声明 resources 时，`raco rivet package` 会失败关闭。迁移方式是在上面的 `resources` 中声明同一份数据，并在原生代码中从 `Contents/Resources/app` 读取：

```swift
let root = Bundle.main.resourceURL   // Contents/Resources (packaged)
let dataURL = root!.appendingPathComponent("app/locales/en.json")
```

在 `raco rivet dev` 期间，根目录是 `.rivet/stage/app`。Windows 和 Linux 包把它放在可执行文件旁的 `app/`；macOS 包把它放在 `Contents/Resources/app`。原生 UI 代码可以使用这些相同的平台原生位置。只有测试和特殊宿主才应设置 `RIVET_RESOURCE_ROOT` 或参数化 `current-resource-root`。

产品资源必须显式声明；Rivet 不会从目录名推断资源契约。例如，一个在原生宿主间共享翻译和 emoji 目录的产品应配置：

```racket
(resources . ("shared/i18n" "shared/emoji.json"))
```

保留的路径在构建期间是 `.rivet/stage/app/shared/i18n/...`，在 Windows 和 Linux 包中是 `app/shared/i18n/...`，在 macOS 应用中是 `Contents/Resources/app/shared/i18n/...`。原生宿主代码应解析该平台资源根并追加相同的 `shared/...` 相对路径。不要把产品文件复制到 `stage/res`：`res` 是 Rivet 的嵌入后端区域，包含 `core.zo`；`app` 才是经过验证的应用资源契约。这种显式声明让 build、package 和 `raco rivet verify` 在三个平台上行为一致。

在此功能之前创建的项目仍然有效，因为这三项设置都是可选的。要在旧生成宿主中嵌入 Windows 图标，请从当前宿主模板加入 Rivet 的条件 `RIVET_WINDOWS_ICON_RC` `ResourceCompile` 项，或在保留应用 UI 源码的前提下重新生成宿主项目。

## 应用数据目录

资源是只读的，随应用一起发布。可变的用户数据——文档、偏好、缓存、数据库——由产品在运行时写入，Rivet 有意不提供相关 API：位置遵循各平台约定，并保持在产品控制之下。

- **Windows**：`%APPDATA%\<publisher>\<name>`（漫游；大型缓存使用 `%LOCALAPPDATA%`）。
- **macOS**：`~/Library/Application Support/<identifier>`（可清理缓存另用 `~/Library/Caches/<identifier>`）。
- **Linux**：设置了 `XDG_DATA_HOME` 时用 `$XDG_DATA_HOME/<identifier>`，否则用 `~/.local/share/<identifier>`；缓存在 `$XDG_CACHE_HOME` 或 `~/.cache` 下。

绝不要写入用户主目录根、安装目录或 `dist/`、`build/`（Rivet 拥有的生成根）。`rivet.rktd` 中的应用标识符就是约定的目录名。

产品应为该目录保留一个小的、可测试的解析器，并支持环境变量覆盖（例如 `<PREFIX>_DATA_DIR`），这样验收套件可以注入一次性根目录，而不触碰开发者的真实配置——参见[产品验收证据](product-acceptance.md)和原生 UI 启动编排，二者都依赖这个钩子。以原子方式写文件（在同一目录写临时文件再重命名），并防御性加载：截断或损坏的文件应回退到默认值（并给出诊断），而不是在启动时崩溃。

## 用户可见字符串：shared/i18n

需要显示用户可见字符串的项目使用单一扁平来源：`shared/i18n/zh.json` 和 `shared/i18n/en.json`，各自是键集合完全相同的扁平 `string -> string` JSON 对象。运行 `raco rivet i18n` 验证该对等契约并重新生成嵌入宿主表（`windows/GeneratedI18n.hpp`、`linux/GeneratedI18n.hpp` 和 `macos-host/Sources/RivetHost/GeneratedI18n.swift`）。宿主通过随包加载器查找键（Windows 和 Linux 上是 `rivet_app::i18n::tr`，macOS 上是 `GeneratedI18n.tr`）：当前语言，然后另一种语言，最后是键本身——因此缺失或未翻译的键绝不会静默渲染成另一个宿主硬编码的文案。如果其他工具在运行时读取原始 JSON，通过 `resources` 暂存 `shared/i18n` 目录；嵌入表是权威的运行时来源。对等契约被破坏或嵌入表与共享源漂移时，`raco rivet doctor --release` 会失败，任何对等违规都会以非零状态退出。

## 部署目标

- `macos-min-version` — 两段或三段式 macOS 部署版本，例如 `14.0` 或 `14.1`。向后兼容默认值是 `14.0`。
- `windows-min-version` — 四段式 Windows 平台版本，例如 `10.0.19041.0`。向后兼容默认值是 `10.0.19041.0`。

项目配置是应用级唯一事实来源：

- `raco rivet build` 通过 `RIVET_MACOS_MIN_VERSION` 把 `macos-min-version` 同时传给生成的 SwiftUI 宿主和 Rivet 的 Swift 运行时包。
- macOS 打包会把同一值写入最终 app `Info.plist` 的 `LSMinimumSystemVersion`。
- `raco rivet verify` 会从打包后的 app 读回 `LSMinimumSystemVersion`，并拒绝不匹配。
- `raco rivet build` 通过 `RIVET_WINDOWS_MIN_VERSION` 把 `windows-min-version` 传给 MSBuild；生成的 WinUI 项目用它作为 `WindowsTargetPlatformMinVersion`。

不要在生成的 `Package.swift` 或 `RivetHost.vcxproj` 中直接修改部署目标。修改 `rivet.rktd`，让 build、package、verify、CI 和未来工具都观察到同一个值。

## 校验规则

项目加载时会校验 `rivet.rktd`；错误值会报错，而不是静默回退默认值。不明显的约束包括：

- `name`、`module`、`entry`、`display-name`、`publisher` 和 `version` 是非空字符串；
  `protocol` 必须是整数 `1`。
- `identifier` 匹配 `^[A-Za-z0-9][A-Za-z0-9.-]*$`；它用于反向域名的
  bundle/应用 ID，不是人类可读的发布者名。
- `build` 是正的有符号 64 位整数。
- `url-schemes` 是 RFC 3986 scheme 名（`^[A-Za-z][A-Za-z0-9+.-]*$`）。
- `file-associations` 条目的 `extension` 匹配
  `^\.[A-Za-z0-9][A-Za-z0-9._-]*$`。
- `resources` 与 `macos-resource-files` 是唯一的项目相对路径；`resources` 拒绝
  `.git`、`.rivet`、`build`、`dist` 和符号链接，`macos-resource-files` 拒绝 `..`
  段。
- `device-rpcs` 是唯一 symbol，字符集 `[A-Za-z0-9._-]`，每个名称最多 124 个 UTF-8
  字节。
- `macos-localizations` 是非空、无重复的 BCP 47 列表，例如 `"zh-Hans"` 和 `"en"`。
- `windows-installer-bitmaps` 只接受 `banner` 和 `dialog` 键，值都是项目相对 `.bmp`。
- `linux-desktop-id` 是反向域名；`linux-binary-name` 使用 `[A-Za-z0-9._-]` 且不能为空。
- 图标和安装器图稿键强制扩展名（`.ico`、`.icns`、`.png`、`.rtf`、`.bmp`）且必须是
  项目相对路径。

## 兼容性

加载旧项目时，上述所有发布/部署元数据都是可选的。Rivet 通过集中默认值保留 0.1 行为，因此升级 Rivet 包不要求立即迁移配置。

新脚手架会显式写入这些值，便于应用所有者审查并有意修改。
