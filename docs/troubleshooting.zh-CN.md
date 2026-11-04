# 排错指南

[English](troubleshooting.md) · **简体中文**

先拿到可机器读取的事实，不要靠猜：

```bash
raco rivet --version
raco rivet doctor
raco rivet doctor --json
raco rivet inspect --json
```

`doctor` 报告工具链、嵌入运行时和项目就绪状态，缺少必需组件时会打印 “Fix next”。
`inspect` 报告项目真实的编辑点、成熟度和安全生命周期命令。把报告粘贴到 issue
之前，请先抹掉私有路径和应用数据。

## 命令还没读到项目就失败

**`no rivet.rktd found in this directory or its parents`**

在项目根目录（包含 `rivet.rktd` 的目录）运行命令，或使用支持显式项目路径的命令。
`raco rivet new <name>` 会新建子目录，不会初始化已有目录。

**`invalid project name`**

项目名必须以字母开头，只包含字母、数字、`_` 和 `-`。重命名目录或换一个名字；
除非在 `rivet.rktd` 中设置 `identifier`，应用标识符会从项目名推导。

**配置错误指出了某个键**

修 `rivet.rktd`，不要修生成文件。可接受的键、默认值和校验规则见
[项目配置](configuration.md)。生成的 `Package.swift`、`RivetHost.vcxproj` 和
CMake 文件都是输出，`raco rivet build` 会重写它们。

## 构建失败

**拉取新的 Rivet 修订后，`raco rivet` 以 linklet 或
“instantiate-linklet: mismatch” 崩溃**

这是 linked checkout 的陈旧字节码缓存，不是项目缺陷：

```bash
find . -name compiled -type d -prune -exec rm -rf {} +
raco setup rivet
```

完整症状见 [CONTRIBUTING](../CONTRIBUTING.md)。

**`doctor` 报告缺少原生工具链**

按 “Fix next” 安装对应平台的工具链：

- Windows：带 C++ 工作负载的 Visual Studio Build Tools 和 Windows SDK；
  只有构建 MSI 时才需要 WiX v4 或更新版本。
- macOS：Xcode 和命令行工具（`xcode-select --install`）；生产签名还需要
  Developer ID 身份和 notary profile。
- Linux：GTK4 开发文件、CMake、C++ 编译器、`pkg-config` 和 `ldd`。

然后重跑 `raco rivet doctor`。

**Linux 找不到可嵌入的 Racket CS 运行时**

`raco rivet build` 需要可嵌入的 Racket CS 运行时，而不只是 `racket` 可执行文件。
把 `RIVET_RACKET_LIBRARY` 和 `RIVET_RACKET_BOOT_DIR` 指向为嵌入构建的运行时，
或使用生成 CI 工作流所用的同一个 setup action
（`turlamai/rivet/.github/actions/setup-embed-racket`）。完整契约见
[嵌入](embedding.md)和[持续集成](ci.md)。

**生成的客户端文件与工作树不一致**

```bash
raco rivet generate --check
raco rivet generate
```

把重新生成的 Swift/C++/Kotlin 文件和导致变化的 backend 改动一起提交。不要手改
生成客户端；`doctor --release` 会拒绝陈旧或手改的工作树。

**打包后的应用与 `raco rivet dev` 行为不同**

`dev` 把资源暂存在 `.rivet/stage/app`；打包后 Windows/Linux 从可执行文件旁的
`app/` 读取，macOS 从 `Contents/Resources/app` 读取。开发时正常、打包后失效的
路径，几乎总是猜了可执行文件相对路径而不是使用 `resource-path`。运行
`raco rivet package` 并启动打包产物，再执行 `raco rivet verify`。

## 应用启动后失败

**没有窗口，或进程立刻退出**

在终端运行 `raco rivet dev` 并抓第一条错误，然后：

```bash
raco rivet doctor
raco rivet clean
raco rivet build
```

Linux 上确认处于 Wayland 或 X11 会话且有 GTK4 运行时；macOS 上从 Finder 启动
打包后的 `.app`，以区分 bundle 问题和终端环境问题；Windows 上在 IDE 之外启动
打包后的可执行文件，观察真实工作目录和 DLL 搜索路径。

**后端已启动但某个 RPC 失败**

未捕获的 backend 异常会变成有界 Error frame，而不是进程退出。检查原生诊断 sink
和应用日志。诊断默认关闭且保持静默，见[诊断](diagnostics.md)。如果长任务看起来
卡住，注意 RVT1 Cancel 会拆除请求，但 handler 目前没有协作式取消检查——把工作
切成页级 RPC。

## 打包、签名与发布

**`release` 或 `package --production` 因缺少凭据而失败关闭**

生产模式拒绝产出未签名产物。按[生产签名](production-signing.md)设置环境变量，
或用 `raco rivet package` / `raco rivet release --development` 产出开发产物。
开发产物不是发布者可信产物，必须如实标注。

**AppImage 发布因缺少图标失败**

AppImage 需要 `rivet.rktd` 中的 `linux-icon`；打包会失败关闭，而不是发布占位图。
添加 PNG 后重试。deb/rpm 只是警告，但 desktop entry 会不完整。

**macOS 应用被 Gatekeeper 或公证拒绝**

检查 `codesign --verify --deep --strict`、notary profile 名称和
`raco rivet verify --production`。ad-hoc 签名的开发构建本来就需要右键打开，
不能作为已公证的证据。

**Windows MSI 构建找不到 WiX**

安装 WiX Toolset v4 或更新版本，并让它出现在 `PATH` 中。MSI 是面向人的安装器；
便携 ZIP 才是更新负载。

**发布 feed 返回 404，或客户端说没有可用更新**

确认 feed URL、channel 名称和 manifest 文件名与发布实际产出的名称
（`update-<channel>.json`）一致，并确认 manifest 的应用 id、平台、架构和安装器
类型与已安装构建匹配。用不同 key id 签名的 feed 会被设计性拒绝；密钥轮换要走
双信任窗口，而不是修改已发布的 manifest。

**更新下载完成但没有安装**

托管更新有意停在“已验证的产物”：安装同意、提权、重启和健康策略属于宿主。检查
平台 handoff（MSI/AppImage）、journal 和下次启动的恢复路径。在读
[发布与更新](release-and-updates.md)之前，不要手工删除 journal 或备份。

## 验收与 CI

**`acceptance` 因缺少覆盖或超时失败**

manifest 必须声明当前平台的每个 requirement，每个 suite 都有有界超时。跳过、未运行
或平台不匹配的 leg 不算通过。检查 JSON 报告和归档产物；`acceptance --dry-run`
可以在不启动命令的情况下校验 manifest。见[产品验收](product-acceptance.md)。

**生成项目没有原生 CI**

新项目包含 `.github/workflows/native.yml`。既有项目可按[持续集成](ci.md)接入；
保持所有 Rivet pin 指向同一个发布版本。

## 清理并重来

```bash
raco rivet clean     # 删除 .rivet/、build/、dist/
```

`clean` 不会删除应用源码、`rivet.rktd`、schema baseline 或验收 manifest。要移除
Rivet 本身，使用 `raco pkg remove rivet`；这不会删除生成项目或用户数据。应用数据
位于[项目配置](configuration.md#application-data-directories)记录的平台目录；
删除前先备份。

## 报告 Bug

附上 `raco rivet --version`、`raco rivet doctor --json` 的输出、平台与架构、完整
命令和最小复现。先移除凭据、签名密钥、私有路径和客户数据。
