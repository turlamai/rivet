# Standalone mobile hosts

Rivet products ship as desktop applications today. The standalone mobile
host line — an iOS app intended to embed Racket CS in-process — remains
**experimental**. The generated Xcode project and portable-bytecode (pb)
toolchain have local build evidence. The simulator app builds, installs, and
launches. Experimental CI run 45836246070 reached `racket_boot done` and
`core.zo loaded`, then failed resolving the backend module. No passing
RVT1 RPC/lifecycle test exists. See [#357](https://github.com/turlamai/rivet/issues/357)
for the failing runtime stack. The standalone acceptance gate has not passed. Device signing, App Store submission, and real-device
round trips remain open; Android standalone hosts are not generated.

## Why portable bytecode (pb) on iOS

Apple enforces W^X on iOS: no memory page may be writable and executable
at once, which bans just-in-time code generation. Racket CS normally
compiles code at run time. The pb build (`--enable-pb --enable-mach=tpb64l`)
replaces native code generation with a bytecode interpreter. This is
the design approach for avoiding JIT on an App Store build, **not yet proof**
that the embedded runtime boots or satisfies all executable-memory rules
on iOS. Earlier simulator builds hung during libffi closure allocation
(`S_ffi_closure`); the experimental Mach trampoline build reached module loading. Once functional, interpreted backend work may carry more
runtime overhead; native SwiftUI rendering is separate.

The goal is to compile backend modules once to portable `core.zo` using
a pb `racket` host compiler (currently verified on Linux). Running that
bundle on a particular iOS target still requires a functioning target VM;
the current simulator has not passed this gate.

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

The `host-compiler` stage has been built and run locally on Linux,
sidestepping the observed libffi executable-memory failure on arm64 macOS.
This host-side success does **not** validate libffi closure allocation inside
an iOS simulator process. The experimental CI cross-runner artifact handoff has reached target module loading,
but the complete acceptance gate has not passed.

```bash
platform/ios/build-embedded-racket.sh --stage host-base     --output "$OUT/host-base"
platform/ios/build-embedded-racket.sh --stage host-compiler --output "$OUT/host-compiler" --base-dir "$OUT/host-base"
platform/ios/build-embedded-racket.sh --stage simulator     --output "$OUT/simulator"     --base-dir "$OUT/host-base"
platform/ios/build-embedded-racket.sh --stage device        --output "$OUT/device"        --base-dir "$OUT/host-base"
```

Details the script handles (each was a real failure mode):

- pb builds link libffi; the libffi bundled in the Racket source is
  compiled per SDK and merged into `libracketcs.a`, so hosts link a single
  archive. The pinned Racket 9.3 source disables the built-in Apple ARM64
  executable trampoline table in both `configure` and `configure.ac`,
  selecting the executable-writable allocation fallback. The experimental
  iOS toolchain now re-enables the existing preassembled Mach trampoline table
  in a private source copy and **fails the target build** unless the generated
  libffi configuration and archive prove that selection. This is a targeted
  candidate for the `S_ffi_closure` hang, not evidence that it is repaired
  until simulator Hello/RPC and lifecycle pass.
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
and runs `xcodebuild` for the iOS simulator (arm64). The generated XCTest suite **attempts** backend startup, typed RPCs,
and a stop/restart cycle. It has not passed: experimental CI reached module loading but failed to
resolve `backend` before serving the RVT1 Hello frame. Treat it as a pending
M4 acceptance gate.

The host waits for actual serving state before its first UI RPC. Startup
waits use a cancellable monotonic 180-second deadline; failures return no
backend. A serving VM stops off the main actor, retains exclusive ownership
until native teardown completes, and cannot be reacquired during stopping.
Stalled startup is not forcibly interrupted. These safeguards and their
regression tests still require integrated simulator validation.

Device builds (iPhoneOS SDK, Release configuration, signing) require a
publisher development team and are part of the remaining qualification
gates, not part of `raco rivet build --ios`.

## What is and is not proven

**Local and experimental CI evidence (not a passing acceptance gate):**

- The pb host compiler runs on the Linux build machine and produces a
  backend `core.zo`; simulator/device runtime archives have been cross-built.
- The generated simulator app has built, installed, and launched with the
  pb runtime and boot resources staged.
- [CI run 45836246070](https://github.com/turlamai/rivet/actions/runs/45836246070)
  reached VM boot completion and bytecode loading, then failed module lookup.
  Simulator RVT1 Hello, typed RPC, restart and process-death behavior remain
  **not verified**.

**Before developer-preview status:** repair the libffi/Chez closure path
and show a clean simulator XCTest run with real backend/RVT1 evidence. The
experimental `.github/workflows/ios-libffi-experiment.yml` now defines a
cross-runner gate: Ubuntu builds a real `core.zo` with the Linux pb compiler,
and an Apple Silicon macOS runner cross-builds target libffi/boot files,
installs a fresh simulator and runs `RivetHostTests` for Hello, typed RPC,
and restart. **The gate is not accepted until that exact workflow succeeds.**
Qualify Release signing, runtime restrictions, lifecycle and network
behavior on a physical device separately.
App Store submission/reviewer acceptance and an Android standalone host
are separate uncompleted gates. Keep this branch draft until then.

---

## 独立移动宿主（中文）

目前独立 iOS 宿主仍处于**实验阶段**。`feat/mobile-hosts` 分支包含
Xcode 工程、SwiftUI 宿主、pb（portable bytecode，可移植字节码）工具链
及 XCTest 用例。本地已验证模拟器应用能够编译、安装并启动，但嵌入的
Racket 虚拟机在实验 CI 45836246070 中已完成启动及 core.zo 加载，随后模块解析失败；
**没有通过真实的 RVT1 RPC 或生命周期测试**。
独立宿主的 CI、真机 Release、签名和商店提交均未验收。具体阻塞见
[Issue #357](https://github.com/turlamai/rivet/issues/357)。

### 为什么采用 pb

iOS 限制可写且可执行的内存页；采用
`--enable-pb --enable-mach=tpb64l` 是为了通过字节码解释执行避免 JIT。
这只是技术方案，**不能直接等同于已满足 iOS 运行时及 App Store 要求**。
早期模拟器 VM 在 libffi 的 `S_ffi_closure` 处分配闭包时挂起；实验构建已到达模块加载阶段。
`core.zo` 已可由 Linux 上的 pb 主机编译器生成，但是否能在 iOS 上运行，
必须通过目标 VM 的真实执行证明。

### 工具链与构建

`platform/ios/build-embedded-racket.sh` 具有四个阶段：
`host-base`（原生基础工具链）、`host-compiler`（编译 pb 后端）、
`simulator`（模拟器运行时与 boot 文件）以及 `device`（真机 SDK
运行时与 boot 文件）。目前 Linux 主机编译器与本地交叉构建有证据，
但这不等于目标 iOS VM 已经运行成功。Racket 9.3 内置 libffi 的
`configure` 与 `configure.ac` 默认禁用了 Apple ARM64 已有的可执行
trampoline table。实验工具链已尝试在独立源码副本中启用 Mach 预编译
跳板表，并检查目标 `fficonfig.h` 与归档符号；该尝试不同于 Linux 专用
`FFI_EXEC_STATIC_TRAMP`，**尚无模拟器真实运行通过证据**，不得认定为
已经解决 `S_ffi_closure` 启动阻塞。

```bash
platform/ios/build-embedded-racket.sh --stage host-base --output "$OUT/host-base"
platform/ios/build-embedded-racket.sh --stage host-compiler --output "$OUT/host-compiler" --base-dir "$OUT/host-base"
platform/ios/build-embedded-racket.sh --stage simulator --output "$OUT/simulator" --base-dir "$OUT/host-base"
platform/ios/build-embedded-racket.sh --stage device --output "$OUT/device" --base-dir "$OUT/host-base"

export RIVET_IOS_HOST_RACKET="$OUT/host-compiler/bin/racket"
export RIVET_IOS_RACKET_LIB_DIR="$OUT/simulator/lib"
export RIVET_IOS_BOOT_DIR="$OUT/simulator/runtime"
export RIVET_IOS_RACKET_INCLUDE="$OUT/simulator/include"
raco rivet build --ios
```

当前生成的 XCTest 已包含启动、类型化 RPC 与重启用例，但执行时
最新已有 VM 启动和 core.zo 加载证据，但模块解析失败，仍未通过。
宿主在实际 serving 后才发送 RPC，使用可取消的单调时钟 180 秒超时；
停止操作移出主线程，并在底层退出之前保持独占所有权，禁止重启及获取后端。
启动阻塞时不强行停止 VM。这些保护仍需联合模拟器验收。实验性
`.github/workflows/ios-libffi-experiment.yml` 已添加 Linux pb 编译器
生成 `core.zo` 与 Apple Silicon macOS 目标运行时交叉构建、真实模拟器
`RivetHostTests` 的跨 runner 验收链路。**在该工作流成功之前不得宣称
iOS 已经通过 Hello、RPC 和重启验证**。
之后仍需真机 Release、无 JIT/可执行内存违规、签名、权限、进程
恢复与商店审核的独立验证。Android 独立宿主目前尚未生成。
