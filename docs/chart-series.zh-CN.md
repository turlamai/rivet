# 实时图表序列

[English](chart-series.md) · **简体中文**

Rivet 产品通过一个共享数据平面渲染实时时间序列（同步收敛、引擎遥测、仿真器轨迹）。本页是
权威约定：Racket 状态持有者、wire 批格式，以及三个桌面宿主的原生控件契约。

参考实现位于 Taskboard 示例：两条合成序列从 `examples/taskboard/app/backend.rkt` 流入
GTK4 `rivet::ui::ChartArea`、SwiftUI `RivetChartView`（RivetUI）和 WinUI 3
`rivet::win_ui::ChartControl`。

## 形状

- **状态持有者（Racket）：** `rivet/chart` 为每条序列维护一个环形缓冲区。样本是精确整数的
  `(timestamp-ns . value)` 对。时间戳严格递增；值有意保持整数——ns 偏移、ps 偏移、ppm 漂移
  和帧计数都是整数原生量，而 Rivet 的类型表面没有 Float 可丢失精度。
- **高速推送（event）：** 产品声明
  `(define-event chart-batch : ChartBatchEnvelope)`，record 携带
  `[series : String] [batch : Bytes]`。ticker 以 UI 节奏（30–60 Hz）排空 ring，每条序列发出
  一个 batch；batch 只携带宿主尚未收到的样本。
- **拉取（RPC）：** window RPC 返回最近窗口加绝对 watermark，用于初始绘制和缺口恢复。

## 批格式

全程小端。C++ 解码器：`runtime/include/rivet/chart_batch.hpp`。Swift 解码器：
`platform/macos/Sources/RivetUI`。三个实现（包括 `rivet/chart.rkt`）由共享 golden 字节
固定；改变布局是三个实现及其测试套件的版本化契约变更。

| 偏移 | 大小 | 字段 |
| ---: | ---: | --- |
| 0 | 4 | magic `0x52564331`（"RVC1"） |
| 4 | 4 | u32 样本数 |
| 8 | 8 | 首个样本的 i64 绝对索引 |
| 16 | 16×n | 每样本：i64 timestamp-ns, i64 value |

绝对索引是首个 batch 样本被追加时，序列历史上追加过的样本总数。宿主维护 watermark（它期望
的下一个索引）；batch 起始超过 watermark 说明 Racket ring 已驱逐未排空样本，宿主通过其
类型化 RPC 重新拉取窗口，而不是猜测。

## 吞吐包络

`benches/event-throughput.rkt` 通过管道驱动真实 serve 路径（Racket 侧编码 + 帧 + 管道写入，
客户端 read-frame 排空）：

| 批形状 | 吞吐 |
| --- | ---: |
| 2 样本 tick batch（48 B） | ~52 000 events/s |
| 16 样本 drain batch（272 B——128 Hz 流以 30 Hz 排空） | ~32 000 events/s |
| 完整 16 384 样本窗口（256 KiB，恢复路径） | ~70 events/s（每个约 14 ms） |

双序列产品负载（每序列 30–60 Hz 的 batch）比容量低三个数量级；约束瓶颈是原生重绘节奏，
而不是 event 通道。有意不提供单独的流式 transport。

## 宿主侧控件

| 宿主 | 控件 | 说明 |
| --- | --- | --- |
| Linux（GTK4） | 平台库中的 `rivet::ui::ChartArea` | `GtkDrawingArea` + Cairo；仅主线程 |
| macOS / Apple | `RivetChartView` + `RivetChartModel`（RivetUI） | SwiftUI `Canvas`；model 为 `@MainActor` |
| Windows | `rivet::win_ui::ChartControl` | WinUI 3 `Canvas` + 持久 `Polyline`；仅 UI 线程 |

三者接受相同的三类输入：序列规格（id、label、color、unit）、装饰（阈值线、事件标记），以及
已解码 batch 或完整窗口替换。RVT1 event 回调到达 reader 线程——在触碰控件之前派发到主循环/
dispatcher queue，与所有其他 Rivet event 完全一样。

功能：多序列滚动窗口、y 自动缩放或固定范围、带标签的阈值线、事件标记、带逐序列读数的悬停
光标，以及跟随最新值的无障碍描述（由原生 UI 套件演练）。

## 集成清单

1. 声明 envelope record 和 event；require `rivet/chart`。
2. 按采样率创建覆盖窗口的容量序列（默认 16 384 样本 ≈ 128 Hz 下 2 分钟）。
3. 从引擎线程追加（`chart-series-append!` 已同步）。对单个活动 `serve`，独立引擎线程可以
   UI 节奏（30–60 Hz）发出；存在多个并发 server 时，从特定已连接 RPC handler 启动 ticker。
   见下文所有权规则。
4. 暴露 window RPC 用于初始绘制和缺口恢复。
5. 在宿主中于主线程把 batch 喂给控件，并把控件的 gap 回调接到 window RPC。

## Event ticker 线程所有权

`emit-event!` 优先使用 server 拥有的线程参数。该参数缺失时，独立后台线程可以通过**唯一**
活动 `serve` 连接发出。这让文件监视器、图表引擎和其他长寿命 worker 无需轮询即可发布进度。
共享 writer 通道仍提供有界背压；回退不是无限制的进程级广播。

当一个 Racket 进程中存在**多个** `serve` 实例时，无关 worker 没有安全方式选择接收者。此时
回退会抛出 `multiple Rivet servers are active; emit from a server-owned thread`，而不是把
event 泄漏到错误连接。server 退出时回退也会被移除。管理多个会话的产品应在相关 server 的
已连接 RPC handler 中创建 ticker，使 thread-local emitter 无歧义地标识目标：

```racket
(define batch-ticker #f)
(define-rpc (start-chart-stream : Void)
  (unless batch-ticker
    (set! batch-ticker
          (thread
           (lambda ()
             (let loop ()
               (sleep 0.033)
               (emit-current-chart-batches!) ; product's typed chart-batch event
               (loop))))))
  (void))
```

产品必须定义 `emit-current-chart-batches!`，并为其 ticker 提供停止/取消策略。从已连接 RPC
handler 启动是多 server 产品的推荐选择。单 server 应用可以改用既有独立引擎线程；它必须处理
断连，且不能在 `serve` 退出后继续发出。

这个回退**仅适用于单 server**。当多于一个 `serve` 实例活动时，它拒绝有歧义的广播。显式的
per-server event-handle API 需要单独审查的所有权和生命周期契约。
