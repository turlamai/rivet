# 包校验

[English](package-verification.md) · **简体中文**

Rivet 把包校验视为打包的一部分，而不是可选的 CI 步骤。

`raco rivet package` 构建 Release/自包含原生应用，组装可分发布局，在适当时签名 macOS
开发 bundle，然后在报告成功之前校验结果。打包始终是干净的原生构建：Windows 使用
MSBuild 的 `Rebuild` target，macOS 重建 SwiftPM scratch tree，Linux 重建 CMake build
tree。增量缓存仍可用于 `raco rivet build` 和 `raco rivet dev`，但它们绝不能决定哪个源码
修订进入发布物。

用 `raco rivet verify` 对 `dist/` 中已有产物重新运行同样的检查。`raco rivet package`
之后，Rivet 校验解包后的平台包。`raco rivet release` 之后，临时解包包已被有意删除，因此
命令会安全解包并校验便携发布 ZIP。归档必须恰好包含一个目录，其名称与预期平台包匹配，
临时校验副本随后总会被删除。

`raco rivet package --production` 增加发布者签名/信任步骤，`raco rivet verify
--production` 重新运行对应的生产信任检查。

## 启动冒烟

平台特定的结构、依赖和信任检查通过后，Rivet 从系统临时目录启动打包后的可执行文件。
产物必须存活五秒。Rivet 然后终止进程并报告成功。提前退出会使校验失败，并给出退出状态和
有界 stdout/stderr 诊断；每个流并发排空，最多捕获 64 KiB，因此嘈杂的失败不会死锁校验或
无界增长内存。

在包目录之外启动是有意的。它演练与 Finder、Explorer 或桌面启动器相同的可重定位资源和
外部库假设，而不是意外地让相对路径通过校验器的当前目录生效。

当 Rivet 检测到交互式 Windows 会话、当前 macOS 控制台用户，或 Linux `DISPLAY`/Wayland
会话时，启动冒烟默认运行。无头环境会打印显式跳过通知。打包机器无法打开 GUI 应用时，可用
`package` 或 `verify` 的 `--skip-launch-smoke`；该 flag 只跳过进程启动，绝不跳过常规布局、
依赖、元数据、签名或安装器检查。它可与 `--production` 以任意顺序组合。

冒烟门禁证明产物能在初始进程和嵌入运行时启动后存活。它不能替代应用特定的 UI 交互或
无障碍测试。

## Windows

Windows 校验器检查便携目录包含 WinUI 可执行文件、编译后的 Racket backend、三个 Racket CS
boot 文件和嵌入的 Racket CS DLL。

然后对每个根 EXE/DLL 使用 MSVC `dumpbin /DEPENDENTS`。每个导入 DLL 必须解析到便携目录中
随包的另一个文件，或当前 Windows 系统目录/API-set 契约。无法解析的导入会使校验失败。

这能抓住常见发布失败模式：包在开发者机器上构建正确，却意外依赖本地安装的 Racket 运行时、
Visual Studio 运行时组件或 Windows App Runtime 组件，而这些没有复制进可分发布目录。

`windows-min-version` 在 `rivet.rktd` 中配置。Rivet 构建环境把它作为
`WindowsTargetPlatformMinVersion` 传给生成的 WinUI 项目，而不是在项目模板中存第二份应用
特定最低版本。

`raco rivet doctor` 报告发现的 `dumpbin.exe`。因此 Visual Studio C++ 工具是 Windows
打包工具链的一部分，而不只是编译工具链。

生产校验模式下，Rivet 还要求 Windows SDK `signtool.exe`，并在常规依赖闭包审计后对
`RivetHost.exe` 运行 `signtool verify /pa /v`。

## macOS

macOS 校验器检查 `.app` 布局、应用可执行文件、`Info.plist`、编译后的 Racket backend、
boot 文件和嵌入的 `Racket.framework`。

然后校验：

- 嵌套 Racket framework 签名；
- 用 `codesign --deep --strict` 校验完整 app 签名；
- 主可执行文件通过 `@rpath/Racket.framework/...` 而非开发者机器绝对路径链接 Racket；
- 可执行文件的 load command 包含 `@executable_path/../Frameworks`；
- 随包 Racket framework 的 install name 是 `@rpath/Racket.framework/Versions/.../Racket`；
- `Info.plist` 通过 `plutil -lint`；
- `LSMinimumSystemVersion` 与 `rivet.rktd` 的 `macos-min-version` 完全一致。

开发包可以使用 ad-hoc 签名，但其运行时布局必须已经可重定位且内部一致。

生产校验模式下，Rivet 还会运行 `xcrun stapler validate` 要求已 staple 的公证 ticket，
并让 Gatekeeper 用 `spctl --assess --type execute` 评估应用。

## Linux

Linux 校验器检查应用目录、可执行位、编译后的 Racket backend、三个 boot 文件和配置的应用
资源。然后对 GTK4 宿主运行 `ldd`，拒绝每个未解析的共享库依赖。Racket CS 本身静态链接；
GTK4 和常规 Linux 系统库仍是原生发行依赖。

生产校验模式下，校验器还要求确定性的 `<name>-<version>-linux-<arch>.tar.gz` 及其分离
签名。它从打包目录重建该归档，要求逐字节一致，并用 `RIVET_LINUX_SIGN_PUBLIC_KEY` 校验
Ed25519 签名。它还会校验生成的 `.deb`、`.rpm` 和 AppImage 结构、元数据、暂存负载和启动器
行为。这些原生格式目前不会单独获得 Rivet 产物签名；tarball 签名不替代 apt/dnf 仓库元数据
信任或发行版自己的签名策略。

这些检查证明 Rivet 产出的产物内部一致。它们本身不证明每个受支持发行版上的包管理器事务或
桌面集成；那些需要应用声明的发布矩阵上的真实生命周期运行。

## CI

Windows、macOS 和 Linux 的 package-smoke job 运行 `raco rivet package`，然后再次运行
`raco rivet verify`。它们演练真实生成应用和打包资源；Windows 和 macOS 还会覆盖部署目标，
使这些平台元数据路径也被覆盖，而不仅是默认值。交互式 Windows 和 macOS runner 还执行启动
门禁。无头 Linux runner 保留静态/包检查，并打印跳过启动通知，除非 job 提供图形会话。

常规 pull-request CI 不包含发布者证书或 Apple 公证凭据，因此有意只演练开发打包。生产凭据
解析由平台无关的 Racket 测试覆盖；由证书支撑的生产签名属于可信发布者发布环境。
