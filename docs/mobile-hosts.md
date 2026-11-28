# Standalone mobile hosts

Rivet products ship as desktop applications today. The standalone mobile
host line — an iOS app intended to embed Racket CS in-process — remains
**experimental**. The generated Xcode project and portable-bytecode (pb)
toolchain have local build evidence. The simulator app builds, installs, launches, and serves real backend RPCs.
[CI run 45967961326](https://github.com/turlamai/rivet/actions/runs/45967961326/job/140427263801) passed the integrated Apple ARM64 simulator gate on commit
`b476912610114f0bd4844696123069ad9b4f095e`, merged through #501.
This is simulator evidence, not a released mobile product. Device signing,
App Store submission, and real-device round trips remain open; Android
standalone hosts are not generated.

## Why portable bytecode (pb) on iOS

Apple enforces W^X on iOS: no memory page may be writable and executable
at once, which bans just-in-time code generation. Racket CS normally
compiles code at run time. The pb build (`--enable-pb --enable-mach=tpb64l`)
replaces native code generation with a bytecode interpreter. This is
the design approach for avoiding JIT on an App Store build, **not yet proof**
of physical-device execution or App Store compliance. Simulator boot is now verified. Earlier simulator builds hung during libffi closure allocation
(`S_ffi_closure`); the experimental Mach trampoline build reached module loading. Once functional, interpreted backend work may carry more
runtime overhead; native SwiftUI rendering is separate.

The goal is to compile backend modules once to portable `core.zo` using
a pb `racket` host compiler (currently verified on Linux). Running that
bundle on a particular iOS target still requires a functioning target VM;
the Apple ARM64 simulator has passed this gate.

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
The cross-runner artifact handoff and target simulator RPC/lifecycle gate have now passed. Physical-device behavior remains unverified.

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
  libffi configuration and archive prove that selection. The integrated simulator Hello/RPC and lifecycle gate passed with this configuration.
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
and runs `xcodebuild` for the iOS simulator (arm64). The integrated XCTest suite verifies backend startup, typed RPCs, orderly stop, and fresh-process relaunch. A second VM boot in the same process previously crashed; the host now retires that runtime and rejects a second boot. Restart is tested using separate Xcode test invocations, each requiring an initial counter of zero.

The host waits for actual serving state before its first UI RPC. Startup
waits use a cancellable monotonic 180-second deadline; failures return no
backend. A serving VM stops off the main actor, retains exclusive ownership
until native teardown completes, and cannot be reacquired during stopping.
Stalled startup is not forcibly interrupted. These safeguards passed the integrated simulator gate.

Device builds (iPhoneOS SDK, Release configuration, signing) require a
publisher development team and are part of the remaining qualification
gates, not part of `raco rivet build --ios`.

## What is and is not proven

- Linux pb compilation and Apple ARM64 simulator runtime build passed.
- [CI run 45967961326](https://github.com/turlamai/rivet/actions/runs/45967961326/job/140427263801) passed real VM startup, Hello, typed RPC, state read/write, readiness cancellation, orderly stop, same-process reboot rejection and fresh-process relaunch with reset state.
- PR #501 passed 26 checks and merged into `feat/mobile-hosts` at `e3b51f9fed7e827e9fae3095afd916d66dd85e1c`.
- The experimental workflow `.github/workflows/ios-libffi-experiment.yml` provides this evidence; the complete generated-product CLI path, physical-device Release signing, runtime restrictions, networking, and App Store acceptance remain separate gates. Android standalone is not implemented. The main integration PR #472 remains draft.

---

## 独立移动宿主（中文）

目前独立 iOS 宿主仍处于**实验阶段**。Linux pb 编译器、Apple ARM64 模拟器运行时、SwiftUI 宿主已经通过真实模拟器专项验收。[CI run 45967961326](https://github.com/turlamai/rivet/actions/runs/45967961326/job/140427263801) 在提交 `b476912610114f0bd4844696123069ad9b4f095e` 上通过；#501 的 26 项检查全部通过并合并至 `feat/mobile-hosts`。这不代表正式移动产品已经发布。真机、Release 签名、商店审核仍待验收。

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
目标模拟器 VM 已通过实际运行验收，真机仍未验证。Racket 9.3 内置 libffi 的
`configure` 与 `configure.ac` 默认禁用了 Apple ARM64 已有的可执行
trampoline table。实验工具链已尝试在独立源码副本中启用 Mach 预编译
跳板表，并检查目标 `fficonfig.h` 与归档符号；该尝试不同于 Linux 专用
`FFI_EXEC_STATIC_TRAMP`，该配置已通过真实模拟器 Hello、RPC 和生命周期验收，但真机尚未验证。

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

联合 XCTest 已验证 VM 启动、Hello、类型化 RPC、状态读写、取消等待和正常停止。此前同一进程第二次启动 VM 发生崩溃，因此停止后禁止再次初始化，改用两次独立 Xcode 测试调用验证新进程重启，每次要求计数器初值为 0。宿主使用可取消的单调时钟 180 秒超时，停止操作移出主线程，底层退出前保持独占所有权。启动阻塞时不强行停止 VM。

上述证据来自实验工作流 `.github/workflows/ios-libffi-experiment.yml`，不是完整生成产品 CLI、真机 Release、签名、权限、网络及商店审核的验收。主线集成 PR #472 仍为草稿；Android 独立宿主尚未实现。
