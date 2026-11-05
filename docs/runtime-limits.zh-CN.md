# 运行时限制

[English](runtime-limits.md) · **简体中文**

Rivet 在同一进程内运行可信的应用代码，但运行时仍然施加有界的协议和请求限制，使应用
缺陷无法让工作队列无限增长。

## 待处理请求

`serve` 和 `serve-fds` 接受可选的 `#:max-pending-requests` 关键字，默认是 1024 个
并发请求。

```racket
(serve in out #:max-pending-requests 256)
```

对嵌入原生宿主：

```racket
(serve-fds in-fd out-fd #:max-pending-requests 256)
```

请求在被接纳之后、其终止 Response/Error 被输出队列接受之前，占用一个 pending 槽位。
该限制同时适用于应用 RPC 和 Rivet 保留的 State 请求，因为它们共享同一套请求生命周期。
达到上限时，Rivet 为新请求返回普通的请求级 Error 帧，而不是再创建请求 custodian 和
Racket 线程；已有请求继续运行。

请求 ID 在其条目仍然 pending 时只有一个所有者。如果该条目释放前又到达同一 ID 的
Request，先到的请求获胜，重复帧在解析 payload 之前就被忽略。同样的所有权保护适用于
语法合法但在 native-to-backend 方向上非法的 RVT1 帧类型：这类帧若复用 pending 请求
ID，Rivet 会忽略它，而不是再发出一个同 ID 的 Error。两种冲突下 Rivet 都不能发送第二个
终止帧，因为原生客户端只按 ID 关联终止帧；竞争的 Error 可能吞掉原请求的 continuation。
ID 不在 pending 表中的非法入站帧仍保留正常的请求级 Error 诊断。原始终止帧被输出队列
接受、pending 条目释放后，该 ID 可被后续请求复用。

原生客户端生成 ID 时保持同样的所有权规则。Windows、macOS 和 Linux 只分配非零 UInt64
ID，跳过仍存在于共享原生 pending 表中的 ID，并在同一把锁内完成 ID 选择与 pending
注册。因此 UInt64 回绕会从 1 继续，而不会覆盖更早的请求。原生取消会锁存到对应
Request 帧成功写出之后，所以 Cancel 绝不会在总线上超越 Request。Swift Task 取消若在
注册前获胜则两个帧都不发，其内部取消状态最多发送一个 Cancel；Windows 和 Linux 使用的
共享 C++ 客户端同样会把同一 pending Request 的重复 `cancel(id)` 合并成一个 Cancel 帧。

原生 pending 表默认也独立限制为 1024 个请求。这防止调用方在另一次原生写入被管道背压
阻塞时无限累积 future 或 Swift continuation。Windows 和 Linux 应用可设置
`RacketRuntimeConfig::max_pending_requests`；macOS 应用可设置
`EmbeddedRacketConfiguration.maxPendingRequests` 或对应的 `RivetClient` 初始化参数。
该限制必须为正数。在此边界被拒绝的请求不会被分配 ID，也不会写出 Request 帧；完成或失败
一个已有请求会立即释放其原生槽位。

取消、正常完成和请求失败竞争 pending 条目的终止所有权，只有一方能取得。已取得所有权的
请求会留在 pending 表中，直到其终止帧被输出队列接纳；这时才释放槽位。当原生输出停滞时
这一点很重要：完成的请求不能提前释放槽位，从而允许无限多 worker 堆积在输出背压之后。

State 提交是唯一的短暂取消屏障。在 setter 取得每个 State 的更新顺序锁之前，Cancel 仍然
立即生效，因为还没有发生 State 副作用。State cell 提交后，取消会延迟到对应的保留
`$state` Event 被有界输出队列接受。此区间收到的 Cancel 会标记 pending 请求，但既不杀死
worker 也不释放 pending 槽位。Event 被接纳后，延迟取消会原子地取得终止所有权，发出正常的
`request cancelled` Error，并停止请求 custodian，而不允许正常 Response。这样 backend 与
原生 State 视图保持一致，又不会在输出背压后创建无界 detached 工作。

pending 表需要同步，因为请求 worker 与服务器 reader 循环并发完成。关闭时会在同一把锁下
快照并清空该表，然后停止剩余的请求 custodian。

## 输出背压

`serve` 和 `serve-fds` 还接受 `#:max-outgoing-frames`。默认输出队列最多持有 64 个等待
单写线程处理的帧。

```racket
(serve in out #:max-outgoing-frames 32)
```

队列有意保持有界。如果原生对端停止读取，RPC worker 和 Event 生产者会阻塞，而不是把帧
追加到无界内存队列。reader 在需要发出拒绝或协议 Error 时也会被背压，从而无法以超过
transport 排空速度继续接纳工作。

writer 与应用运行时分开监督。生产者等待输出容量或 writer 终止。输出端口失败时，阻塞的
生产者被释放，内部 reader/请求运行时被关闭，`serve` 传播 writer 错误而不是继续阻塞在
`read-frame`。有序关闭时，Rivet 先停止所有生产者，排空输出队列已接受的全部帧，再停止
writer。

State 更新使用独立的数据锁和更新顺序锁。State cell 在短数据锁下提交，锁在保留
`$state` Event 等待输出容量之前释放。因此纯 Racket `state-ref` 即使在原生 transport
背压时也能观察到已提交值。每个 State 的私有更新顺序锁保持到 Event 被接受，后续 setter
无法超越停滞的更新，`$state` Event 顺序与提交顺序一致。上文描述的取消屏障覆盖同一个
提交到 Event 的区间，因此取消不会留下已提交却缺少原生通知的 State 值。

队列限制是帧数量上限，不替代 RVT1 每帧 64 MiB 限制或 pending 请求限制。这些限制共同
工作：value/frame 限制约束每个条目，输出队列约束缓冲帧，pending 表约束已接纳的请求
worker，包括终止帧仍在等待输出容量的请求。

## Events

Event 标识符在锁下分配，因为多个 RPC worker 可以并发发出 Event。Event 投递仍使用单一
response writer，因此 RVT1 帧不会在输出流上交错。

Event handler 在原生 runtime/reader 线程上执行。应用 UI 代码必须先派发到 WinUI
dispatcher 或 Swift MainActor，再修改 UI 状态。

## Wire 值

RVT1 v1 在 Racket、C++ 和 Swift 中应用相同的资源限制：

- 单个帧 payload 最多 64 MiB；
- 独立的编码值最多 64 MiB，因此它总能作为单个帧 payload 使用；
- 递归编码值最多 64 层嵌套 `List`；
- 一个编码/解码值最多包含 262,144 个 value node，包括根值和每个嵌套 `List` 元素。

值编码器在构造输出时执行字节预算，而不是先分配超大编码 payload 再在写帧时失败。独立
解码器在解析前拒绝大于 64 MiB 的输入。带长度前缀的 `String` 和 `Bytes` 字段在复制前
根据实际剩余输入校验声明长度，因此极小的伪造 payload 无法请求读取数 GB 的字段。

node 预算防止一个很小、甚至只有单帧大小的 wire payload 膨胀成无界数量的语言级
`Value`/list 对象。解码器在预留或构造目标容器前，根据剩余 node 预算校验声明的 `List`
数量。编码器应用同一预算，因此应用侧意外产生的巨型 `List` 会在递归编码其元素之前被拒绝。
大型二进制 payload 应使用 `Bytes`，它无论字节长度都只计一个 value node，并仍受 64 MiB
value/frame 大小限制约束。

State 值在存储前还会作为完整的保留 `$state` Event 预检。无法同步的初始值会被
`define-state` 拒绝。更新在修改 State cell 之前编码 Event，并在成功时复用该 payload，
因此类型正确但超出 RVT1 限制的值不会让 Racket 与原生 State 视图不一致。

声明的 RPC、Event 和 State API 名称限制为 1024 个 UTF-8 字节。入站 RPC 和 State 查找名
使用相同字节上限，并在 `string->symbol` 之前拒绝，防止任意 wire 输入创建超大的注册表
查找符号。错误消息只报告实测长度和配置上限，不回显超大名称。

这些是防御性资源限制，不是应用 schema 限制。正常的 `String`、`Bytes`、`List`、
`Optional`、RPC、State 和 Event 用法不变。

## 失败隔离

格式错误的应用级请求，包括未知 RPC 名和非法参数形状，会作为请求级 Error 帧返回。无法在
RVT1 资源限制内序列化的应用 RPC 结果也会转成请求级 Error 帧：请求在响应编码成功之前
保持可认领，因此序列化失败不会静默吞掉终止响应所有权并让原生客户端永久等待。

应用 RPC worker 还会隔离 Racket 能 raise 的每个值，而不仅是 `exn:fail?` 层次。标准异常
值保留其有界 `exn-message`。如果应用代码 raise 非异常值，Rivet 返回固定诊断，而不是打印
或回显任意对象。两种情况请求都会认领并发出一个终止 Error，然后释放 pending 槽位；因此
异常的 `raise` 不会在杀死 worker 的同时让原生客户端和并发限制永久卡住。

后端生成的 Error 诊断上限为 4096 个 Unicode 字符，更长消息以 `[truncated]` 结尾。已接纳
的请求在竞争取消的终止所有权之前准备好这个有界 Error payload。接纳前的拒绝使用同一个
有界编码器，因此超大的未知 RPC 名或异常消息不会仅仅因为 Rivet 试图报告失败就逃出
reader 循环。
