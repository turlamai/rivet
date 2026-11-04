# 原生 UI 端到端测试

[English](native-ui-testing.md) · **简体中文**

Rivet 让 UI 测试保持原生，与它让生产 UI 保持原生是同一个原因：平台的无障碍和交互栈是产品
的一部分。参考 Taskboard 在 Windows 通过 UI Automation、macOS 通过 AXUIElement、Linux
通过 AT-SPI 演练。测试与 WinUI 3、SwiftUI/AppKit 或 GTK4 之间没有共享 widget DSL 或合成
的 Rivet 视图树。

## 行为契约

`Native UI End-to-End` 工作流在测试前先打包应用，并要求每个平台驱动证明以下全部内容：

1. 能发现并激活真实原生窗口；
2. 暴露稳定的语义名称/标识符和角色；
3. 调用 `new-task` 穿过生成的客户端和 RVT1 边界，结果 State 到达原生列表；
4. 调用 `generate-demo` 使 `operation-progress` Event 通过原生无障碍表面可见；
5. 最终 1,000 行 State 到达 UI；
6. 有序 backend 关闭运行至完成。macOS 上 quit Apple Event（Cmd+Q 投递的事件）是已打包
   应用的可靠触发器——信号和关闭按钮不是；见下文启动说明。

每次运行都上传有界交互 trace 和无障碍快照。runner 支持平台截图 API 时还会捕获屏幕图像，
Linux 上还会捕获应用/合成器日志。证据用 `if: always()` 上传，因此失败断言仍可诊断。

## 应用扩展点

产品应用拥有自己的视图，因此也拥有标识符和场景词汇。把这些标识符保留在原生源码中：

- WinUI：`AutomationProperties.AutomationId` 和 `AutomationProperties.Name`；
- SwiftUI/AppKit：`.accessibilityIdentifier`、labels 和原生角色；
- GTK4：`GtkAccessible` 属性和有意义的 widget 角色。

把匹配的驱动复制到 `rivet/tests/native-ui/`，用一条产品关键场景替换参考标识符和动作，并把
驱动加入打包 job。在产品 `rivet-acceptance.rktd` 中把该驱动声明为 `native-ui` suite，使
缺失平台覆盖在 job 开始前就失败；见[产品验收证据](product-acceptance.md)。有用的最小场景
包含一次 RPC 驱动的变更、一个 Event、一条稳定无障碍树断言和有序关闭。仅测试用的协议消息
和跨平台选择器语言有意不是扩展点。

## 在 macOS 上启动已打包应用

macOS 驱动接收应用进程 id（`--pid`）和证据输出目录（`--output`）；suite 命令负责在驱动
周围启动和回收应用。该 runner 的已验证形状：

1. `raco rivet package` 产出开发发布物；在 `dist/` 下找到最新 bundle，并用 bundle
   `Info.plist` 上的 `plutil -extract CFBundleExecutable raw` 找到其可执行文件。默认
   `package` 还会启动产物一次作为启动冒烟——当 suite 自己负责启动时传
   `--skip-launch-smoke`，让运行保持封闭。
2. 在后台启动可执行文件，环境里带一次性数据根（应用自己的覆盖钩子——绝不是开发者的真实
   profile），并把 `$!` 作为驱动的 pid。
3. 驱动完成后通过 quit Apple Event 回收应用（发送
   `osascript -e 'tell application id "..." to quit'` 或通过事件路径投递 Cmd+Q），然后
   轮询 `kill -0`；对同一数据根再启动一次以断言持久效果。不要对已打包应用依赖 `SIGTERM`、
   程序化终止或窗口关闭按钮：在当前 macOS 上，主线程空闲时它们都可能被吞掉，只有 quit
   Apple Event 能可靠运行有序关闭。绝不要在同一应用的第二个实例中驱动键盘阶段：它可能
   报告假阳性的 `frontmost`，而键盘事件路由完全损坏（连点击标题栏也无法恢复）。
4. 用 `swiftc` 编译 Swift 驱动（或在 suite 目录预编译）；驱动要求进程持有 Accessibility
   信任，因此 CI runner 必须把它授予测试宿主。

罕见的嵌入运行时启动竞态可能让已启动实例卡死：backend 应答握手，但窗口永不渲染，同时数十
个 runtime 线程满 CPU 自旋。驱动检测该特征很便宜（对 pid 执行 `ps -o %cpu=`，在就绪窗口
之后仍保持数百百分比且没有 AX 窗口），一次有界地重启新实例是已验证的缓解——payback 和
regexmate suite 都带了它。把卡死作为 runtime 缺陷报告并附诊断 bundle（进程 sample、自旋
特征、应用日志），而不是无限重试；卡死实例不会自愈，必须按精确 pid 杀死。

参考 macOS AX 驱动现在会在 **CI** 运行超时且找不到首个原生窗口时，把有界 `ps` 快照记录到
`startup-spin-process.txt`。如果该测试 PID 仍高于 200% CPU，它还会尝试
`sample PID 3 -file startup-spin.sample.txt` 做三秒原生线程栈采样；权限错误会被记录，但
不会掩盖原始 AX 失败。既有的 `if: always()` CI 产物上传只会在捕获到这些文件时包含它们。
不要仅凭 CPU 特征推断 Chez GC 死锁：修改 runtime 前必须检查栈证据。开发者本地运行不会
自动采样可能敏感的进程；CI 证据可能包含宿主栈路径，并受仓库 CI 保留/访问控制约束。

## 在 macOS 上驱动键盘和焦点

参考驱动的 helper 为真实事件路径而存在——`focus`、`typeText`、`postKey`（Return 是
keycode 36，Escape 是 53）——因为只通过 `AXUIElementSetValue` 驱动的文本字段跳过了用户
实际演练的内容。配方必须尊重四条桌面现实，缺一都会静默失败：

1. **AX focus 写入成功不等于焦点。** 设置 `kAXFocusedAttribute` 可能报告成功，而 field
   editor 从未启动——SwiftUI toolbar item 和 NSView representable 没有自己的 key-view
   loop。聚焦后要验证焦点确实移动（读回 `kAXFocusedAttribute` *并*确认输入文本落下，或
   断言应用 first responder）；托管这类字段的产品应提供显式 key-view loop（模式见
   regexmate key-view 修复）。
2. **输入法会吞掉合成文本。** 第三方 IME（例如拼音输入法）会拦截 CGEvent unicode-string
   事件，使组合文本到不了字段——Escape 等非 unicode 按键事件也可能被吞。输入前用
   TextInput Source API（`TISCopyCurrentKeyboardInputSource` /
   `TISSelectInputSource`）切到 ASCII 输入源，之后恢复原输入源；参考驱动正是为此提供
   TIS helper。
3. **投递的按键会去往用户正在使用的窗口。** 在共享桌面上，CGEvents 路由到当前聚焦应用。
   每次投递按键前验证被测应用是 frontmost，不是就快速失败——没有该检查的驱动可能把
   `Cmd+A` 和 `Delete` 倒进开发者的编辑器。CI 的独占 runner 正是键盘阶段的默认场所。
4. **AX 元素随视图死亡。** 经过空状态可能重建表格，让先前捕获的 `AXUIElement` 引用变成
   僵尸——属性返回陈旧或空值，而应用表面仍在工作。在每个有界等待内从活 AX 树重新查找元素；
   绝不要在可能改变视图结构的场景步骤之间缓存元素引用。

固定 sleep 不是有界 `waitFor` 探针的替代品。

保持快照小：限制递归深度，记录语义字段而不是平台对象转储，绝不包含用户数据或秘密值。失败
产物只应按仓库正常 CI 日志的保留期保留。
