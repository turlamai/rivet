# Rivet API 稳定性

[English](api-stability.md) · **简体中文**

Rivet 尚未到 1.0，但它的公开接口必须是有意设计的。`rivet`、
`rivet/app-info`、`rivet/backend`、`rivet/keel`、`rivet/protocol`、
`rivet/resources`、`rivet/system`、`rivet/chart`、`rivet/distribution` 与
`rivet/testing` 的全部 phase-0 导出都由 `rivet/tests/public-api.rkt` 固定。

因此，API 变更必须是显式行为：

1. 同时修改实现与文档；
2. 有意更新公开导出快照；
3. 在 `CHANGELOG.md` 记录迁移方式；
4. 使用最低支持的 Racket 版本和当前开发基线运行完整 Racket 测试套件。

## 支持的 Racket 版本

Rivet 目前支持 Racket CS 9.0 及更新版本；`info.rkt` 中的 `base` 下限是权威值。
每个版本都会在该下限和当前开发基线上测试。平台支持范围以 README 中的矩阵为准，
不能从 Racket 版本推断。

## 弃用与移除

1.0 之前，如果不兼容变更能够消除设计陷阱或建立明显更清晰的长期契约，则可以接受，
但实现、文档、导出快照和 `CHANGELOG.md` 迁移说明必须在同一次变更中完成。

1.0 之后，删除或改变公开绑定需要发布 major 版本。移除前必须先在 Scribble
参考和 `CHANGELOG.md` 中标记弃用、给出替代项，并至少保留一个 minor 版本周期。
新增兼容 API 属于 minor 版本，兼容修复属于 patch 版本。弃用警告不能替代替代项的
文档与测试覆盖。

`String`、`Int64`、`Bool`、`(List T)` 等 Schema 类型标识符，是 Rivet
声明形式接受的语法，并不是导出的运行时值。工具应检查规范的 Keel
`app-schema`。
