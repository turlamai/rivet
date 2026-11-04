# 产品验收证据

[English](product-acceptance.md) · **简体中文**

`raco rivet acceptance` 把产品的“完成定义”变成可执行、受源码控制的契约。它补充
RackUnit 和各平台原生 UI 工具，而不是替代它们，也不引入共享 UI 选择器语言。

命令读取 `rivet-acceptance.rktd`，校验每个声明的 requirement 在所需的每个平台上都有
suite，然后运行当前宿主上的 suite。每个命令以 executable + argv 启动，不经过 shell。
Rivet 执行超时、并发排空 stdout/stderr、每个流最多捕获 64 KiB、检查退出状态，并在报告
成功前校验声明的证据路径。

## Manifest

把 manifest 提交在项目根：

```racket
#hasheq(
 (version . 1)
 (requirements
  . (#hasheq((kind . contract) (platforms . (windows macos linux)))
     #hasheq((kind . native-ui) (platforms . (windows)))))
 (suites
  . (#hasheq((id . core)
             (kind . contract)
             (platforms . (windows macos linux))
             (command . ("raco" "test" "racket/"))
             (timeout-seconds . 300))
     #hasheq((id . windows-ui)
             (kind . native-ui)
             (platforms . (windows))
             (command . ("pwsh" "-File" "scripts/e2e/windows.ps1"))
             (timeout-seconds . 900)
             (evidence
              . (#hasheq((path . ".rivet/acceptance/windows/accessibility.json")
                         (kind . accessibility-snapshot))
                 #hasheq((path . ".rivet/acceptance/windows/screen.png")
                         (kind . screenshot))
                 ".rivet/acceptance/windows/trace.json"))))))
```

支持的 suite 类型：

- `unit`：隔离的实现测试；
- `contract`：产品行为、schema、golden 输出和真实存储；
- `bridge`：生成客户端经 RVT1 到嵌入 backend；
- `native-build`：第一方平台宿主的编译；
- `native-ui`：通过无障碍驱动与原生产品交互；
- `package`：可分发布物的行为或结构；
- `release`：安装器、更新、回滚、签名或生产信任。

Suite id 是唯一 symbol。Platforms 是 `windows`、`macos`、`linux` 的非空子集。Command
是非空 argv 字符串列表；shell 语法、重定向、管道和命令插值都不会被解释。每个 suite
命令以项目根为当前目录运行，因此 suite 命令中的路径相对项目。超时是正整数，上限两小时。
Evidence 条目是 `.rivet/acceptance/` 下的文件路径。Rivet 在 suite 启动前删除每个声明的
文件，然后要求 suite 重新创建它，因此早先绿色运行留下的陈旧产物不能满足当前运行。
`native-ui`、`package` 和 `release` suite 必须声明至少一个证据文件。

证据条目会分类，使远端消费者知道绿色 suite 实际产出了什么。裸路径字符串表示 `generic`
类型；哈希声明 `path` 和一种 `kind`：`accessibility-snapshot`、`screenshot`、
`interaction-trace`、`log` 或 `generic`。无障碍快照是主要的跨平台记录——可在平台间比较的
语义 UI 状态——截图只是补充，因为原生呈现本来就允许不同。`--json` 报告固定记录每个声明
条目的 kind、存在性、字节大小和 SHA-256，因此归档报告能为它所担保的产物提供审计。

`requirements` 是可审查的策略。每个 kind/platform 对必须至少有一个匹配 suite，否则
manifest 会在任何子进程启动前被拒绝。产品所有者应像保护公共 API 变更一样保护
requirements、CI、golden 数据和原生 UI 驱动的变更。如果同一补丁未经明确审查就削弱证据
契约，绿色结果没有意义。

## CI 用法

在每个原生宿主 job 中运行该命令，而不只是 Linux：

```bash
raco rivet acceptance --json
```

JSON 报告包含项目、平台、manifest 路径、配置的 requirements、选中的 suites、有界输出、
耗时、超时状态、退出码和缺失证据。即使 job 失败也要归档它。`--suite <id>` 只用于诊断；
合并门禁应运行当前平台的完整集合。

先在不运行任何东西的情况下校验 manifest——手改出语法错误的
`rivet-acceptance.rktd` 应在几秒内失败，而不是几分钟后才在打包 suite 中失败：

```bash
raco rivet acceptance --dry-run
```

dry run 加载并校验 manifest（形状、requirement 覆盖），解析当前平台的 suites 及其
executable，检查证据路径规则，并在启动任何子进程前退出。其报告标记
`"dry-run": true`，每个 suite 状态为 `"dry-run"`；它是校验记录，不是验收证据，不能作为
平台 leg 喂给 `raco rivet matrix`。

迁移期间使用替代 manifest：

```bash
raco rivet acceptance --manifest path/to/acceptance.rktd --json
```

编辑既有 checkout 前，先检查 worktree、fetch 跟踪的 remote，并只做 fast-forward 更新。
把基础 commit 与验收报告一起记录。工作区脏、分叉或 remote 不可达是停下来报告状态的
理由，不是 stash、reset 或对未知基础声称证据的理由。

## 在进程内驱动嵌入 backend

Contract suite 需要 backend 的真实行为，而不是 mock。backend 是普通 Racket 模块：
require 它会运行 `define-*` 声明，`rivet/backend` 的 `serve` 通过任意 binary port 说
RVT1，因此一个测试进程可以演练真实的嵌入 backend 往返：

1. 实例化被测 backend 模块（声明在模块实例化时注册）。需要“重启后” backend 的测试必须
   在新 namespace 下重新实例化模块，从同一 namespace 取出 `serve`（以及任何
   `record-ref`），并按文件路径 require 模块——引用的 symbol 只在已经认识它的 namespace
   中解析：

   ```racket
   (define ns (make-base-empty-namespace))
   (parameterize ([current-namespace ns])
     (namespace-require/copy `(file ,(path->string backend-path))))
   (define serve-proc
     (parameterize ([current-namespace ns]) (eval #'serve)))
   ```
2. 构造一对 pipe，在 custodian 下的线程运行 `(serve in out)`，并记住 `serve` 会阻塞到
   会话结束；关闭客户端输出端口会结束它。
3. backend 在读取任何内容前于启动时写出 hello 帧，因此客户端第一次 `read-frame` 会观察
   到它。
4. 用 `rivet/protocol` 说 RVT1，它公开导出完整测试表面：`protocol-version`、`frame`
   struct 及其访问器，`message:hello`、`message:request`、`message:response`、
   `message:error`、`message:event`、`message:cancel`、`message:shutdown`、
   `write-frame`、`read-frame`、`encode-value`、`decode-value`，以及限制常量。不存在
   单独的进程内 RPC 入口——协议边界就是被测契约。
5. 断言 wire 可见结果：被接受调用的 response payload、被拒绝输入的 error frame（其
   payload 是编码后的 String 值），以及 State 变更在 response 帧之前发出的保留
   `$state` Event。

```racket
(require rivet/backend
         rivet/protocol)

;; Instantiate the backend module under test (declarations register here).
(dynamic-require (build-path (current-directory) "backend.rkt") #f)

(define-values (backend-in client-out) (make-pipe))
(define-values (client-in backend-out) (make-pipe))
(define server (thread (lambda () (serve backend-in backend-out))))

;; The backend writes the hello frame before reading anything.
(define hello (read-frame client-in))
(unless (eq? (frame-type hello) message:hello)
  (error 'check "expected hello, got ~a" (frame-type hello)))

(write-frame (frame message:request 1
                    (encode-value (list "bump" 41)))
             client-out)
;; A State mutation inside the RPC emits the reserved $state event before
;; the response frame; a rejected input arrives as an error frame instead.
(define state-event (read-frame client-in))
(unless (and (eq? (frame-type state-event) message:event)
             (equal? (decode-value (frame-payload state-event))
                     (list "$state" (list "counter" 41))))
  (error 'check "unexpected $state event: ~e" state-event))
(define response (read-frame client-in))
(define result (decode-value (frame-payload response)))
(unless (equal? result 41)
  (error 'check "expected 41, got ~e" result))

(close-output-port client-out)
(thread-wait server)
```

把它与纯逻辑的 unit 测试和下文 native-ui suite 配合；三者合起来才是 contract
requirement 所说的“真实存储和真实协议边界”。

## 对桌面能力分类

并非每个桌面能力承担相同的对等义务。把每项声明为三类之一，让类别驱动 requirements 列表：

- **Guaranteed**——每个声明桌面平台都要求相同语义；缺少平台即发布失败。这些成为带全部
  桌面平台和匹配 suite 类型的 `requirements` 条目。
- **Conditional capability**——API 与语义处处相同，但运行时可用性可能不同：托盘、全局
  快捷键、安全存储、通知。适配器必须显式报告 supported/unavailable/permission 状态，
  而不是静默失败；suite 断言报告的状态，而不是无条件成功。
- **Platform-specific**——有意的仅原生化行为，不强制跨平台抽象。它被排除在 requirements
  列表之外；平台特定不意味着未验证，而意味着由该平台自己的 suite 验证。

目标是语义对等，而不是完全相同的视觉行为。原生 SwiftUI、WinUI 和 GTK 呈现本来就应不同；
验收证据（无障碍状态、RPC 效果、声明的产物）不能不同。

Guaranteed 特性只有在每个声明平台都运行了其 suite 后才算完成——下面的矩阵正是证明这点。

## 聚合跨平台矩阵

本地操作系统是编辑环境，不是验证边界。每个平台 leg 把验收报告归档为 CI 产物；矩阵把同一
commit 的报告折叠成一个结论：

```bash
raco rivet matrix windows-report.json macos-report.json linux-report.json
raco rivet matrix windows-report.json --json
```

```text
Rivet verification matrix: Taskly - 3 reports

  requirement    windows     macos     linux
  contract          PASS      PASS      PASS
  native-ui         PASS      PASS      FAIL

Cross-platform status: FAIL
```

规则是确定性的：只有该平台报告中同 kind 的通过 suite 才能证明单元格；运行但失败的证据使
单元格失败；某平台没有证据就是缺失，绝不会静默变绿。所有报告必须描述同一项目，因此一个
产品的绿色 leg 不能为另一个产品担保。诊断性的 `--suite` 运行会被接受并在矩阵中标记为
partial，但合并门禁应喂入完整报告。只有每个 required kind/platform 单元格都被证明时退出码
才为绿。

喂入被测 commit 的报告；矩阵只聚合给定内容，不会启发式地偏好更新的运行。

## 从单台主机编排远端验证

`raco rivet verify-remote` 为远离平台 leg 的编辑 Agent 闭环：它在 GitHub Actions 上派发
每个平台的验收 leg，等待运行，下载归档的 `acceptance --json` 报告，并折叠进矩阵：

```bash
raco rivet verify-remote --repo OWNER/REPO --ref <branch-or-sha>
raco rivet verify-remote --repo OWNER/REPO --ref <sha> --platform linux
raco rivet verify-remote --repo OWNER/REPO --ref <sha> --json
```

该命令只驱动 `gh` CLI。默认值编码一个约定——workflow `verify.yml`，产物名
`acceptance-report-<platform>`——`--workflow`/`--artifact-prefix` 可适配产品自己的命名。
Workflow 契约是：`workflow_dispatch` 触发，带 `platform` 输入（`linux`、`windows` 或
`macos`），每个 leg 一次 `raco rivet acceptance --json`，报告用 `if: always()` 上传，使
失败的 leg 仍交出证据。只重跑受影响平台就是 `--platform <name>`；最终结论仍需要每个
required 平台的报告，因为缺失平台绝不会静默变绿。

只有当矩阵通过且每个请求平台都交付报告时，命令才以绿色退出。运行集合落在
`.rivet/verify-remote/`（用 `--output-directory` 调整），`--json` 会把每次运行的结论和
报告路径加入矩阵文档。

## 什么算完成

RackUnit 是共享 Racket 行为的常规所有者。声称采用 Rivet 架构的产品还应额外演练至少一次
真实的生成客户端/嵌入 backend 往返，以及每个受支持桌面平台至少一条关键打包原生 UI 流程。
原生 UI 驱动应断言语义角色、一次 RPC 变更、由此产生的 State/Event 呈现，以及有序关闭。
见[原生 UI 端到端测试](native-ui-testing.md)。

固定 sleep、仅进程存活的冒烟测试、仅 mock 的 backend 调用，或用 CLI 替代 GUI 动作，都是
有用的诊断，但不是相应产品行为的证据。优先使用对可观察状态的有界等待，以及一次性
HOME/config/database 根。绝不要从验收 suite 修改开发者的真实 profile 或杀死无关进程。

Agent 可以选择实现方式，但不能重新解释“完成”：required suite 被跳过、未在声明平台运行、
超时、使用错误产物，或未产出证据，都意味着工作未完成。
