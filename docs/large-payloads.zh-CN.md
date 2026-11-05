# 大负载、分页与进度

[English](large-payloads.md) · **简体中文**

RVT1 给单帧 64 MiB 和 2^18 个 value node 预算。这对常规应用流量有意宽松，也有意有限：
真实工作区数据——对 OEM 交付物的语义 diff、包含数万个 identifiable 的包树——放不进一个
响应，也不应该放。本页是让形状在真实数据上保持在预算内的约定层。

## 报告型 RPC：分页

任何结果列表随输入规模增长的 RPC（diff 发现、影响报告、搜索命中）都应返回一页，而不是
整个列表：

```racket
(define-record Page
  ([items : (List DiffEntry)]
   [total : Int64]
   [cursor : (Optional String)]))

(define-rpc (diff-workspaces [cursor : (Optional String)]
                             [limit : Int64]
                             : Page)
  ...)
```

约定：

- **用 cursor，不用 offset。** cursor 对宿主不透明（序列化位置）；当底层数据在页之间变化时，
  offset 会静默损坏。首个请求传 `null`；每个响应要么携带下一个 cursor，要么用 `null`
  cursor 标记结束。
- **`limit` 是宿主控制的上限**，由 backend 校验（封顶——宿主 bug 请求一千万项应失败关闭，
  而不是让帧 OOM）。
- **`total` 只是提示。** 宿主用它显示进度提示（“显示 200 / 14 632”），绝不用于布局不变式。
- Record 已经为这些提供类型——上面的 `Page` 记录就是 backend 中的普通 `define-record`；
  无需特殊 wire 支持。

autarx workbench 是参考消费者：当真实交付物超过 fixture 规模时，`diff_workspaces` 和
`impact_for_ecu` 迁移到这种形状。

## 树型 RPC：窗口化子节点

每个节点子节点数量无界的树（一个 ARXML 包包含数万个 identifiable）绝不应整体返回。约定：

- 加载 RPC 返回**带稳定 id 和子节点计数的节点**，而不是递归展开的树：

```racket
(define-record TreeNode
  ([id : String]
   [label : String]
   [child-count : Int64]))

(define-rpc (load-package [package-id : String] : (List TreeNode))
  ...)

(define-rpc (children [node-id : String]
                      [cursor : (Optional String)]
                      [limit : Int64]
                      : Page)
  ...)
```

- **稳定 id 就是契约。** 宿主基于它们虚拟化（SwiftUI `List` 懒加载行、WinUI
  `ItemsRepeater` 分块）；id 必须在会话内稳定解析到同一节点。
- **`child-count` 驱动展开入口**（带计数的 chevron、加载页时的 spinner），而无需物化孙节点。
- 子节点使用与报告相同的页形状——同样的 cursor 纪律、同样的失败关闭 limit 上限。

专门的 `Tree` wire 类型（不在一帧内物化列表即可获得子节点计数）有意尚未构建：上述约定已经
约束每一帧，wire 类型应等到 autarx 之外的第二个消费者压测该约定之后再引入。

## 进度事件：带类型的 Record，而不是字符串

长操作（索引一千万行交付物）应使用 record 事件报告进度，让宿主渲染确定性进度，而不是解析
字符串：

```racket
(define-record Progress
  ([label : String]         ;; "Indexing ECUC containers"
   [fraction-bps : Int64])) ;; 0..10000 basis points; -1 is indeterminate

(define-event progress : Progress)
```

- `fraction-bps` 是定点 basis points，因为 RVT1 v1 有意没有 `Float64` value tag。宿主除以
  100 得到百分比文本。
- 在 backend 中定义 record，生成的 Swift/C++/Kotlin 客户端会结构化解码——无需按应用解析，
  也无需用字符串走私 `"indexing 42%"`。

**取消是有意留下的缺口。** RVT1 携带 `message:cancel`，但 `define-rpc` handler 目前没有
协作式取消检查；循环处理大工作区的 handler 无法观察 cancel 请求。当前的 backend 侧约定是：
把长工作切成页级批次，跨独立 RPC 调用（上面的分页形状），使每次调用都很短，取消就只是
“停止请求下一页”。handler 内第一方 `(cancel-requested?)` 检查将与第一个真正需要调用中取消
的消费者一起设计。

## 帧预算提醒

- 单个响应必须保持在 64 MiB 和 2^18 个 value node 以下——校验页大小，不要信任它。
- `Bytes` payload（图片、导出）位于 JSON value 树之外，但仍计入帧；按页流式传输，或通过
  宿主读取的文件传递。
- 当宿主确实需要“全部”时，端到端迭代 cursor 页是受支持路径；它很快（每页无 UI 工作），
  且每帧有界。
