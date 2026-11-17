# Standalone mobile hosts

Rivet products ship as desktop applications today. The standalone mobile
host line — an iOS app intended to embed Racket CS in-process — remains
**experimental**. The generated Xcode project and portable-bytecode (pb)
toolchain have local build evidence. The simulator app builds, installs, and
launches, but its embedded Racket VM has not finished booting and no passing
RVT1 RPC/lifecycle test exists. See [#357](https://github.com/turlamai/rivet/issues/357)
for the failing runtime stack. The branch has no completed CI evidence for
the standalone flow. Device signing, App Store submission, and real-device
round trips remain open; Android standalone hosts are not generated.

## Why portable bytecode (pb) on iOS

Apple enforces W^X on iOS: no memory page may be writable and executable
at once, which bans just-in-time code generation. Racket CS normally
compiles code at run time. The pb build (`--enable-pb --enable-mach=tpb64l`)
replaces native code generation with a bytecode interpreter. This is
the design approach for avoiding JIT on an App Store build, **not yet proof**
that the embedded runtime boots or satisfies all executable-memory rules
on iOS. The simulator VM currently hangs during libffi closure allocation
(`S_ffi_closure`). Once functional, interpreted backend work may carry more
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
an iOS simulator process. A CI cross-runner artifact handoff has been designed,
but no successful WIP-branch CI run establishes it.

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
and runs `xcodebuild` for the iOS simulator (arm64). The generated XCTest suite **attempts** backend startup, typed RPCs,
and a stop/restart cycle. It has not passed: in the latest sampled local
run, the embedded pb VM stalls in `S_ffi_closure` before serving the
RVT1 Hello frame. Treat it as a pending M4 acceptance gate.

The experimental host now waits for the actual serving state before sending
its first UI RPC. A failed or expired 180-second startup wait must return no
backend and show a visible failure instead of sending an RPC to a stalled VM.
The simulator XCTest gate also asserts `isReady` before each RPC. These are
fail-closed readiness safeguards, **not** a fix or passing simulator proof
for the underlying libffi/Chez boot hang.

Device builds (iPhoneOS SDK, Release configuration, signing) require a
publisher development team and are part of the remaining qualification
gates, not part of `raco rivet build --ios`.

## What is and is not proven

**Local branch evidence (not a passing CI gate):**

- The pb host compiler runs on the Linux build machine and produces a
  backend `core.zo`; simulator/device runtime archives have been cross-built.
- The generated simulator app has built, installed, and launched with the
  pb runtime and boot resources staged.
- The live process still hangs inside `S_ffi_closure` during VM boot.
  Simulator RVT1 Hello, typed RPC, restart and process-death behavior are
  **not verified**. This supersedes earlier optimistic notes.

**Before developer-preview status:** repair the libffi/Chez closure path,
show a clean simulator XCTest run with real backend/RVT1 evidence, add
cross-runner CI for the entire pb toolchain+app, and qualify Release signing,
runtime restrictions, lifecycle and network behavior on a physical device.
App Store submission/reviewer acceptance and an Android standalone host
are separate uncompleted gates. Keep this branch draft until then.

---

## 独立移动宿主（中文）

目前独立 iOS 宿主仍处于**实验阶段**。`feat/mobile-hosts` 分支包含
Xcode 工程、SwiftUI 宿主、pb（portable bytecode，可移植字节码）工具链
及 XCTest 用例。本地已验证模拟器应用能够编译、安装并启动，但嵌入的
Racket 虚拟机尚未完成启动，**没有通过真实的 RVT1 RPC 或生命周期测试**。
独立宿主的 CI、真机 Release、签名和商店提交均未验收。具体阻塞见
[Issue #357](https://github.com/turlamai/rivet/issues/357)。

### 为什么采用 pb

iOS 限制可写且可执行的内存页；采用
`--enable-pb --enable-mach=tpb64l` 是为了通过字节码解释执行避免 JIT。
这只是技术方案，**不能直接等同于已满足 iOS 运行时及 App Store 要求**。
当前模拟器 VM 在 libffi 的 `S_ffi_closure` 处分配闭包时挂起。
`core.zo` 已可由 Linux 上的 pb 主机编译器生成，但是否能在 iOS 上运行，
必须通过目标 VM 的真实执行证明。

### 工具链与构建

`platform/ios/build-embedded-racket.sh` 具有四个阶段：
`host-base`（原生基础工具链）、`host-compiler`（编译 pb 后端）、
`simulator`（模拟器运行时与 boot 文件）以及 `device`（真机 SDK
运行时与 boot 文件）。目前 Linux 主机编译器与本地交叉构建有证据，
但这不等于目标 iOS VM 已经运行成功。arm64 macOS 上 libffi 闭包的
可执行内存限制也不能通过简单打开 static-trampoline 编译开关解决。

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
Racket VM 卡在 `S_ffi_closure`，尚未通过。实验宿主现在必须等待实际的
serving 状态才执行首个 UI RPC；180 秒超时或启动失败会返回空值并显示
失败状态，不会将尚未就绪的后端误认为成功。XCTest 在 RPC 前也会核对
`isReady`。这些是防止误报及无限等待的保护措施，**并未修复或验证通过**
libffi/Chez 的启动阻塞。下一步仍须通过真实模拟器 Hello/RPC/生命周期
验收，再建立完整 CI。
之后仍需真机 Release、无 JIT/可执行内存违规、签名、权限、进程
恢复与商店审核的独立验证。Android 独立宿主目前尚未生成。
