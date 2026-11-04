# Documentation map / 文档导航

This page is the canonical map of Rivet documentation. Start with one path and
follow links only when the work crosses that boundary; the root README remains
a product overview rather than a second documentation index.

## Language status / 语言状态

English pages are the normative technical source. Complete Simplified Chinese
counterparts exist for the public entry journeys: [README](../README.zh-CN.md),
[Using Rivet](USING.zh-CN.md), [Getting started](getting-started.zh-CN.md),
[Continuous integration](ci.zh-CN.md), [API stability](api-stability.zh-CN.md),
and [Apple release readiness](apple-release-readiness.zh-CN.md). Pages without
a `中文` link are currently English-only; they are not silently bilingual and
their translation status is tracked as remaining work, starting with
release/update, diagnostics, and system-service guides. Protocol
and architecture references stay English as the single normative definition.

中文：英文页面是规范性技术来源。公开入门旅程已提供完整中文对照（见上方链接）；
未标注“中文”的页面目前只有英文，不声称双语对等。翻译按“发布/更新 → 配置 →
诊断 → 系统服务”的顺序补齐；协议与架构规范保持单一英文定义。

## Build an application / 开发应用

- [Getting started](getting-started.md) · [中文](getting-started.zh-CN.md)
- [Project configuration](configuration.md) · [中文](configuration.zh-CN.md)
- [Diagnostics and cleanup](diagnostics.md)
- [Continuous integration](ci.md) · [中文](ci.zh-CN.md)
- [Agent-native development](agent-native.md)
- [Product acceptance evidence](product-acceptance.md)

## Understand contracts / 理解契约

- [Architecture](architecture.md) — process, runtime, UI, Android, and service boundaries
- [RVT1 protocol](protocol.md) and [runtime limits](runtime-limits.md)
- [Racket CS embedding](embedding.md)
- [API stability](api-stability.md) · [中文](api-stability.zh-CN.md)
- [Large payloads, pagination, and progress](large-payloads.md)

## Native platform integration / 原生平台集成

- [System services](system-services.md)
- [Windows host integration](windows-native-window.md)
- [Linux display policy](linux-display.md)
- [Real-time chart series](chart-series.md)
- [Typed device communication](device-communication.md)
- [Network device channel design](network-device-channel.md) — protocol, pairing, and selected Apple/Windows/Android transport foundations exist; product wiring and real-device qualification remain unverified

## Ship and maintain / 发布与维护

- [Package verification](package-verification.md)
- [Production signing](production-signing.md)
- [Apple release readiness](apple-release-readiness.md) · [中文](apple-release-readiness.zh-CN.md) — channel-specific bundle preflight and App Store evidence boundaries
- [Release and updates](release-and-updates.md)
- [Cross-product adoption inventory](adoption.md) — which products run which release/update contract parts
- [Releasing the Rivet framework](releasing.md)
- [Native UI end-to-end testing](native-ui-testing.md)
- [Protocol fuzzing](fuzzing.md) and [performance benchmarks](benchmarks.md)
- [Desktop closeout and mobile start plan](desktop-closeout-mobile-plan.md)

## Maintenance rule / 维护规则

Each topic has one canonical owner. Add a new page only when it defines a
durable boundary that cannot fit an existing owner; status snapshots and
completed milestones belong in the active plan or changelog, not permanent
standalone pages. When deleting or merging a page, update all repository links
and run `raco test rivet/tests/documentation.rkt`.

Active plans are temporary. When their exit gates close, move lasting decisions
and operating instructions into the canonical guides above, record the release
result in `CHANGELOG.md`, and delete the plan instead of preserving a second
history of the same feature. Durable protocol and security rationale stays in
its owning guide until the implementation supersedes it.

## Adoption and support

[English guide](USING.md) · [简体中文](USING.zh-CN.md): fit, maturity, upgrade boundaries and support. This user path links to the existing canonical technical owners above.
