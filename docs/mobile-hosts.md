# Standalone mobile hosts

Rivet products ship as desktop applications today. The standalone mobile
host line — an iOS app embedding a Racket CS runtime in-process, built and
tested entirely from the repository's own toolchain — is in **foundation**
status: the generated project, the portable-bytecode runtime pipeline, and
simulator lifecycle evidence exist; device signing, App Store submission,
and real-device round trips remain open gates (see `docs/desktop-closeout-mobile-plan.md`
M4 and issue #357). Android standalone hosts are not yet generated.

## Why portable bytecode (pb) on iOS

Apple enforces W^X on iOS: no memory page may be writable and executable
at once, which bans just-in-time code generation. Racket CS normally
compiles code at run time. The pb build (`--enable-pb --enable-mach=tpb64l`)
replaces native code generation with a bytecode virtual machine, so a
Rivet iOS host runs **without JIT and without executable-memory
exceptions** — the property App Store review requires. The cost is
interpretation overhead for backend logic; the native UI keeps its usual
performance.

Because pb bytecode is machine-portable, the backend module is compiled
once on the build machine by a pb `racket` that itself runs on macOS, and
the produced `core.zo` executes on every pb target.

## Toolchain

`platform/ios/build-embedded-racket.sh` builds everything from the pinned
Racket CS source (same version and SHA-256 pin as
`.github/actions/setup-embed-racket`). Stages:

| Stage | Output | Purpose |
|-------|--------|---------|
| `host-base` | prefix | native Racket CS build; bootstraps every pb and cross build |
| `host-compiler` | prefix | native pb (`tpb64l`) racket+raco that compiles product backends to portable bytecode |
| `device` | prefix | cross build of `libracketcs.a` + boot files for the iPhoneOS SDK |
| `simulator` | prefix | cross build of `libracketcs.a` + boot files for the iPhoneSimulator SDK |

```bash
platform/ios/build-embedded-racket.sh --stage host-base     --output "$OUT/host-base"
platform/ios/build-embedded-racket.sh --stage host-compiler --output "$OUT/host-compiler" --base-dir "$OUT/host-base"
platform/ios/build-embedded-racket.sh --stage simulator     --output "$OUT/simulator"     --base-dir "$OUT/host-base"
platform/ios/build-embedded-racket.sh --stage device        --output "$OUT/device"        --base-dir "$OUT/host-base"
```

Details the script handles (each was a real failure mode):

- pb builds link libffi; the libffi bundled in the Racket source is
  compiled per SDK and merged into `libracketcs.a`, so hosts link a single
  archive.
- The CS configure only recognizes a simulator SDK whose path ends in
  `iPhoneSimulator.sdk`; the script passes a canonically named symlink.
- `make install` of a cross build re-runs host-side steps that assume the
  binaries run locally, so the embedding layout (static archive, boot
  files, headers) is harvested from the build tree following the official
  install recipe instead.
- Racket's pure-Racket Mach-O signer misplaces ad-hoc signatures on pb
  binaries; the script routes signing through the system `codesign`.

## Generated iOS host

`raco rivet new` copies `platform/ios/host` into `ios-host/`: an Xcode
project (app + XCTest targets) whose SwiftUI app boots the embedded
backend from `Bundle.main`'s `runtime/*.boot` + `res/core.zo` — the same
resource layout as the macOS host, served by the same `RivetEmbedding`
APIs. The updater stack is deliberately never linked into the iOS host:
App Store policy forbids a post-review code-download path, so a standalone
iOS app runs only the backend it shipped with.

## Building

```bash
export RIVET_IOS_HOST_RACKET="$OUT/host-compiler/bin/racket"
export RIVET_IOS_RACKET_LIB_DIR="$OUT/simulator/lib"
export RIVET_IOS_BOOT_DIR="$OUT/simulator/runtime"
export RIVET_IOS_RACKET_INCLUDE="$OUT/simulator/include"

raco rivet build --ios
```

This compiles `backend.rkt` with the pb compiler, stages the boot files
and the bundle into `ios-host/runtime` and `ios-host/res` (git-ignored),
and runs `xcodebuild` for the iOS simulator (arm64). The generated XCTest
suite boots the backend inside the app process and exercises typed RPCs
plus an orderly stop/restart cycle — the simulator half of the M4
lifecycle evidence.

Device builds (iPhoneOS SDK, Release configuration, signing) require a
publisher development team and are part of the remaining qualification
gates, not part of `raco rivet build --ios`.

## What is and is not proven

Proven by the framework CI on macOS runners:

- the pb runtime cross-builds for the iOS simulator and device SDKs;
- the generated host compiles and links the pb runtime into a real app;
- the backend boots and serves typed RPCs in the simulator process, and
  restarts with identical observable state after an orderly stop.

Not yet proven (open gates): physical-device run under Release
constraints, code signing with publisher credentials, App Store submission
itself, and the Android standalone host. Treat the iOS line as developer
preview only after those close in the product repository that consumes
it.

---

## 独立移动宿主(中文)

Rivet 的独立移动宿主线处于 **foundation** 状态:已具备生成的 Xcode 工程、
可移植字节码运行时管线与模拟器生命周期证据;设备签名、App Store 提交、
真机往返仍是未关闭的门禁(见 `docs/desktop-closeout-mobile-plan.md` M4
与 issue #357)。Android 独立宿主尚未生成。

### 为什么 iOS 用可移植字节码(pb)

Apple 在 iOS 上强制 W^X:内存页不可同时可写、可执行,即禁止 JIT。pb 构建
(`--enable-pb --enable-mach=tpb64l`)以字节码虚拟机取代本地代码生成,使
Rivet iOS 宿主**无 JIT、无可执行内存异常**地运行——这正是 App Store 审核
要求的性质。代价是后端逻辑有解释开销;原生 UI 性能不受影响。

pb 字节码与机器无关:后端模块由构建机上的 pb `racket` 编译一次,产出的
`core.zo` 可在所有 pb 目标上执行。

### 工具链

`platform/ios/build-embedded-racket.sh` 从与 CI 相同 pin 的 Racket CS
源码构建全部产物。四个阶段:`host-base`(原生构建,引导后续一切)、
`host-compiler`(跑在 macOS 上的 pb racket/raco,把产品后端编译成可移植
字节码)、`simulator`/`device`(交叉构建各 SDK 的 `libracketcs.a` 与
boot 文件)。脚本处理过的真实故障:pb 需要的 libffi 按 SDK 编译并并入归档、
模拟器 SDK 路径需以 `iPhoneSimulator.sdk` 结尾、交叉构建的 `make install`
会重跑宿主侧步骤(改为按官方配方直接收割)、Racket 自带的 Mach-O 签名器
对 pb 二进制定位错误(改走系统 `codesign`)。

### 构建命令

```bash
export RIVET_IOS_HOST_RACKET="$OUT/host-compiler/bin/racket"
export RIVET_IOS_RACKET_LIB_DIR="$OUT/simulator/lib"
export RIVET_IOS_BOOT_DIR="$OUT/simulator/runtime"
export RIVET_IOS_RACKET_INCLUDE="$OUT/simulator/include"

raco rivet build --ios
```

流程:用 pb 编译器编译 `backend.rkt`,把 boot 文件与字节码束布点到
`ios-host/runtime`、`ios-host/res`(已 git-ignore),再以模拟器目标
(arm64)运行 `xcodebuild`。生成的 XCTest 在应用进程内启动后端,执行类型化
RPC 与有序停止/重启——即 M4 生命周期证据的模拟器部分。

### 已证明与未证明

框架 CI 已证明:pb 运行时可交叉构建到模拟器与真机 SDK;生成的宿主能把
pb 运行时链接进真实应用;后端在模拟器进程内启动并服务类型化 RPC,有序
停止后重启状态一致。尚未证明(门禁保持打开):真机 Release 运行、发布者
凭据签名、App Store 提交本身,以及 Android 独立宿主。在这些门禁关闭前,
iOS 线只应被视为开发者预览。
