# 诊断与清理

[English](diagnostics.md) · **简体中文**

Rivet CLI 同时提供人类可读和机器可读的工具链诊断。目标是让原生构建失败可检查，
而不必猜测实际选中了哪个 Racket 运行时或平台工具。

## `raco rivet doctor`

常规 doctor 输出会报告当前操作系统与架构、实际使用的 `racket` 和 `raco`
可执行文件，以及 Rivet 选中的 Racket CS 运行时产物。

运行时部分包括：

- Racket 版本；
- include 与 library 目录；
- 存在时的 DLL 目录；
- 精确的 `petite.boot`、`scheme.boot` 和 `racket.boot` 文件；
- Windows 上选中的 Racket CS DLL 与 `.def` 文件；
- macOS 上选中的 `Racket.framework`；
- Linux 上选中的静态 `libracketcs.a`。

它还会报告当前平台使用的原生构建、依赖审计和可选的生产签名工具。

这有意比只打印 Racket 版本更具体。如果机器上有多个 Racket 安装，`doctor` 显示的
路径就是 Rivet 在 build/package 时真正会使用的产物。

### 可操作的失败

缺少必需依赖时，人类可读的 doctor 输出会以 `Fix next:` 结束。修复建议有意保持保守：
它指出需要处理哪个受支持的平台工具链或 Racket 安装，以及修复后应重新运行什么。

例如，不完整的 Windows C++ 环境会指向 Visual Studio 2022 / Build Tools 的
`Desktop development with C++` 工作负载和 Windows SDK；Windows App SDK 是项目包，
Rivet 会在构建时还原。不完整的 macOS 环境会指向 `xcode-select --install`，必要时
还会提示选择 Xcode developer directory。Linux 诊断会检查 CMake、pkg-config、
C++20、GTK 4.10 或更新版本、`ldd` 以及可嵌入的静态 Racket CS 库。运行时发现失败时，
Rivet 会要求完整的 Racket CS 发行版和同一安装的 `raco`。

Linux 源码构建可能把嵌入产物放在运行 `raco` 的 Racket 安装之外。此时把
`RIVET_RACKET_LIBRARY` 指向精确的 `libracketcs.a`，把 `RIVET_RACKET_BOOT_DIR`
指向包含三个 boot 文件的目录；如果它们也来自自定义前缀，可选设置
`RIVET_RACKET_INCLUDE` / `RIVET_RACKET_LIB_DIR`。`doctor` 会在任何构建开始前报告
解析出的文件。

仅发布时需要的工具不会被视为开发阻塞项。缺少 Windows `signtool`、macOS 公证工具
或 Gatekeeper 评估支持时会被报告为可选，开发打包仍然可用。

## `raco rivet doctor --json`

在 CI、Agent、编辑器集成或 bug 报告收集器中使用 JSON 模式：

```text
raco rivet doctor --json
```

该命令向标准输出写一个 JSON 对象，并使用与人类可读 doctor 相同的成功/失败退出状态。
重要的顶层字段包括：

- `os`
- `architecture`
- `rivet-version` — 已安装的 Rivet 发布版本（未版本化的源码 checkout 为
  `null`；`raco rivet --version` 打印同一身份）
- `supported`
- `usable`
- `racket-executable`
- `raco`
- `racket-version`
- `runtime`
- `runtime-error`
- `project-readiness` — 在项目内运行时包含 `root` 和
  `schema-baseline-configured`
- `warnings` — 稳定的 `code`、`severity`、`message` 和 `remediation` 条目；
  已知 code 为 `missing-schema-baseline` 和 `invalid-winui-window-icon-path`
- `tools`

`runtime` 包含上文描述的精确运行时产物路径。`tools` 包含平台相关的可执行文件路径。
warning code 属于自动化契约：消费者可能以它为键，因此重命名必须附带 changelog 和
兼容性说明。Windows `signtool` 或 macOS 公证工具等可选生产工具可以缺失，而正常开发
打包仍可用。

JSON 模式有意只输出数据：不会把人类可读横幅或修复建议混入标准输出。自动化应检查
`usable`、`runtime-error` 和 `tools`，并自行决定如何呈现或补齐缺失依赖。

## `raco rivet clean`

`clean` 只删除 Rivet 生成的项目目录：

```text
.rivet/
build/
dist/
```

它不会删除应用源码、`rivet.rktd`、原生宿主源码或任何其他项目文件。

该操作是幂等的。项目已经干净时，命令成功返回且不改动源码。

如果某个生成路径是符号链接，Rivet 只删除链接本身，不会递归跟随到外部目录。这样清理
范围保持在项目内，避免删除生成产物边界之外的数据。

更换工具链或从陈旧原生构建恢复后的常规流程是：

```text
raco rivet doctor
raco rivet clean
raco rivet build
```

自动化诊断可改用 `raco rivet doctor --json`，并把生成的 JSON 与失败构建日志一起归档。

## 应用日志 sink

`rivet-log` 把结构化记录发给 `current-rivet-log-sink`；默认把 JSONL 写到标准错误。
GUI 进程通常没有终端，而且在 Windows 上第一次写 stderr 可能分配控制台窗口，因此商业应用
应安装文件 sink：

```racket
(require rivet/system)

(current-rivet-log-sink
 (make-rotating-log-sink (build-path data-directory "logs" "app.log")
                         #:max-bytes (* 5 1024 1024)
                         #:max-files 3))
```

该 sink 每行追加一个 JSON 对象；在记录会超过 `#:max-bytes` 之前轮转；最多保留
`#:max-files` 个归档（`.1` 最新）；创建父目录；在 Unix 上把活动文件权限设为
`#:permissions`（默认 `#o600`）。追加由每个 sink 的信号量串行化，因此多个 Racket 线程的
回调不会交错写入一条记录。I/O 错误交给可选的 `#:on-error` 过程，而不是杀死应用；默认忽略，
这对日志是合适的，但也意味着除非提供报告器，磁盘写满会保持静默。设置不是日志：不要在日志
字段中放秘密，sink 不会对应用数据做脱敏。

## 嵌入运行时诊断

Windows、macOS 和 Linux 的嵌入运行时以及 Racket 后端会为生命周期和请求边界事件逐行
输出一个 JSON 对象。它与 RVT1 分离：不增加协议帧、不修改应用负载，也不把运行时耦合到
某个日志提供方。

```json
{"schema":"rivet.diagnostic.v1","layer":"native-client","event":"rpc-dispatch","status":"success","last_protocol_event":"response","request_id":42}
```

每条记录包含：

- `schema`：始终是 `rivet.diagnostic.v1`；
- `layer`：`native-runtime`、`abi-bridge`、`transport`、`protocol`、
  `native-client` 或 `racket-backend`；
- `event` 与 `status`：生命周期边界，以及 `begin`、`success` 或 `failure`；
- `last_protocol_event`：最近观察到的 RVT1 消息类型，首帧之前为 `none`；
- 可选的 `request_id` 与 `message` 字段。

事件流覆盖后端初始化、transport 创建、Hello 握手、逐 RPC 分发、取消、有序关闭、
通道意外关闭、reader 循环失败和后端退出。因此失败记录会说明最后已知边界是 Racket
后端、ABI bridge、RVT1 校验、transport I/O 还是原生客户端。

嵌入应用默认静默。这对原生 GUI 进程很重要：在 Windows 上，第一次写标准错误就可能
分配一个可见的控制台窗口。应用应安装由自己的 logger 或崩溃报告器支撑的 sink。
原生运行时为命令行工具和开发会话保留显式的 JSONL-to-stderr helper：

```cpp
rivet::windows::RacketRuntimeConfig config;
config.diagnostic_sink = [](rivet::DiagnosticRecord const& record) {
  application_log(rivet::diagnostic_json_line(record));
};
```

Linux 运行时配置也提供同一个 `diagnostic_sink` 字段。Apple 平台把 `diagnosticSink:`
传给 `EmbeddedRacketConfiguration.resolvedDefault` 或 `RivetClient`；只有确实需要
stderr 时才使用 `RivetDiagnostics.standardError`。Racket 侧 `serve-fds` 使用
`current-rivet-diagnostic-sink`；直接调用 `serve` 的代码可显式传
`#:diagnostic-sink`。该参数默认是 `void`，因此导入嵌入后端绝不会附带分配控制台。

诊断 sink 在运行时和请求线程上执行。它应当快速、线程安全、非阻塞，且不得回调同一个
运行时。C++ sink 异常与应用生命周期隔离。

Rivet 从不记录 RPC 参数或结果负载。RPC begin 记录可能指出被调用的 API，失败消息可能
包含应用异常文本；请把 JSONL 流当作运维日志数据，并套用与其他崩溃报告相同的脱敏和
保留策略。Racket 侧消息上限为 4096 字符，并避免对任意 raised 值调用自定义打印机。
