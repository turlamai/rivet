# 发布与更新

[English](release-and-updates.md) · **简体中文**

Rivet 把分发服务保持在 RVT1 之外。应用协议和嵌入式 Racket 生命周期不知道安装器、
更新通道或签名密钥如何工作。应用选择加入 `rivet/distribution`，而 `raco rivet release`
组合既有的 build、package、平台签名、校验、安装器、合规和更新 manifest 阶段。

## 发布命令

生产发布需要平台签名配置以及以下更新变量。Windows 需要 Authenticode 设置，macOS 需要
Developer ID/公证设置；Linux 需要 `RIVET_LINUX_SIGN_PRIVATE_KEY` 和
`RIVET_LINUX_SIGN_KEY_ID`（见[生产签名](production-signing.md)）。

```text
RIVET_UPDATE_BASE_URL=https://downloads.example.com/my-app
RIVET_UPDATE_PRIVATE_KEY=/secure/path/update-ed25519-private.der
RIVET_UPDATE_KEY_ID=release-2026
RIVET_PREVIOUS_VERSION=1.4.2                 # optional rollback metadata
RIVET_MINIMUM_UPDATABLE_VERSION=1.0.0        # optional; defaults to 0.0.0
RIVET_UPDATE_ROLLOUT=100                     # optional; 0..100
```

运行 `raco rivet release`。结果是 Windows 上签名的 MSI、macOS 上签名/公证的 DMG，或
Linux 上 Ed25519 签名的自包含 `.tar.gz`，外加带版本的便携 zip、channel manifest、
CycloneDX SBOM 和 `THIRD_PARTY_NOTICES.txt`。签名通道始终包含便携 zip；Windows 还包含
精确的 MSI，Linux 在启用该格式时包含精确的 AppImage。因此一个 feed 服务每种受支持的安装
形态，无需推导 sibling URL 或信任未签名 sidecar。DMG、deb、rpm 和 tar.gz 仍是直接下载或
包管理器产物。`release --development` 在不做生产平台签名的情况下演练同一流程，但更新
manifest 仍需要其独立的 Ed25519 密钥。

Linux 上发布还会构建原生系统安装器：`.deb`（dpkg-deb，非特权，安装到 `/opt/<name>` 并带
desktop entry）、`.rpm`（rpmbuild BUILDROOT，与发行版无关）、`.AppImage`（打包 GTK4
依赖闭包，因此同一文件可在较旧发行版运行）以及可选的 `.flatpak` bundle。用
`linux-formats` 项目设置选择集合。签名的 tar.gz 和便携 zip 始终保留为发布资产。启用
AppImage 时，签名 manifest 同时携带便携 ZIP 和 AppImage 条目，各自带精确 URL、大小、
SHA-256 和安装器类型；发布还会写出面向人的 `.AppImage.sha256` sidecar，但客户端信任
签名 feed。包管理器安装通过包管理器升级；AppImage 安装使用 Rivet 的已验证原子替换。
AppImage 打包需要 `rivet.rktd` 中的 `linux-icon` PNG——该格式要求顶层图标，Rivet 会
失败关闭而不是发布占位图。

Flatpak bundle 把同一个已验证 tar.gz 包进 GNOME Platform 50 runtime。runtime 选择与
lz4/ncurses 模块 pin 由 Rivet 负责（它们是 payload 在 runtime 之外仅有的 `NEEDED` 项）；
产品在 `flatpak-finish-args` 中声明沙箱，并可用 `flatpak-manifest` 替换整个 manifest。
bundle 以非特权方式加上 `--disable-rofiles-fuse` 构建，沿用同一版本化产物命名，并生成
`.sha256` sidecar。`flatpak-builder` 用 `eu-strip` 剥离闭包；以
`--no-install-recommends` 安装软件包的机器还需要 `elfutils`。Flatpak 安装通过 Flatpak remote 升级，因此该 bundle 刻意不进入签名的
自更新 feed。

有意不提供在线更新通道的应用可以运行 `raco rivet release --without-updates`。该命令仍会
build、package、平台签名、校验，并产出安装器、SBOM 和第三方 notices；只跳过 channel
manifest，且不读取任何 `RIVET_UPDATE_*` 凭据。可与 `--development` 组合，在发布者凭据
存在之前演练未签名发布流程。省略 `--without-updates` 会保持上述失败关闭行为：三项更新
设置全部必需，部分配置即为错误。

## 共享更新工具链

自行发布更新产物的产品（应用旁边的 CLI、旧 feed 别名或手工产物矩阵）使用三个 Rivet 命令，
不再维护各自的更新脚本：

- `raco rivet update-keys --key-id <id>` 在 `~/.<project>/update-signing-key.pem`（或 `--key`）
  生成 Ed25519 密钥对，输出 DER base64 secret、完整 SPKI hex 以及供 verifier 模块使用的
  32 字节 raw hex；文件已存在时必须显式 `--force`。`--json` 为自动化输出相同字段。key id
  是信任根决策，命令不会自动编造。
- `raco rivet check-release-version [tag]` 要求 `rivet.rktd` 版本与 `VERSION`（或
  `--version-file`）及 tag 一致；只有 `--allow-rc` 才接受 `v<version>-rc.N`；并检查每个
  `--carrier <file>` 包含该版本。它取代各仓库的版本预检脚本，包括后端 fallback 这类额外 carrier。
- `raco rivet sign-manifest` 从显式列出的产物构建签名 channel manifest，支持 DER 或 PEM
  私钥、末尾 `:<component>`（`app`、`cli`、`tool`）以及用于过渡 feed 名的 `--alias <file>`
  （字节一致）。产品只保留自己的产物命名与策略。

因此产品 wrapper 只需几行：取得 version/build，调用 `check-release-version`，把产物列表交给
`sign-manifest` 并发布。Rivet 不会猜测产品的产物矩阵；那属于产品知识。

Windows MSI CI 现在会在首次 MSI 安装后从真实的 `Program Files` 安装位置启动可执行文件，
检查原生窗口就绪、有序关闭和进程终止。第二次验收再次启动已安装 v1，并在 **v1 仍在运行**
时升级到 v2，演练真实的 MSI/Restart Manager 路径。它要求完成且不延迟重启、旧可执行文件
终止、新负载已安装。降级和卸载检查保留。这些门禁不模拟点击 WiX Finish，也不证明每个下游
产品的单实例或首次运行业务行为。

Windows MSI 原生 CI 还会在首次启动已安装应用后执行真实的关闭应用 `msiexec /fa` 修复；
要求退出码 0、不延迟重启、已安装负载完整、安装目录之外的一次性用户数据不变。它会在运行中
升级和最终完全卸载时重复用户数据检查。这些是通用框架安装器门禁，不替代每个产品的
profile/数据迁移验收。

MSI Finish 页的 Launch 复选框在首次安装和修复/重装时生效；Rivet 在完全卸载
（`REMOVE="ALL"`）时抑制其启动动作，因此已移除的可执行文件绝不会被启动。这是 WiX 安装器
契约，与 CI 单独的已安装程序启动门禁不同。

品牌化 DMG 打包在转换读写镜像之前用 `hdiutil info` 检查整个后备设备。仅移除 Finder
挂载点不算成功分离。如果旧镜像路径在分离后短暂锁定，打包器会转换同目录私有副本，并在成功
和失败时都删除它。原生测试仍会挂载并检查生成的 DMG；设备未分离或转换失败不算合格安装器。

所有 macOS DMG 都在卷根放置 app bundle 和真实的 `/Applications` 链接，即使产品没有配置
`dmg-background`。普通镜像使用原生 Finder 复制，不依赖 AppleScript 自动化；普通和品牌化
镜像都用 `ditto` 复制已签名 app，以保留 Racket.framework 符号链接。原生 macOS 测试会
挂载普通镜像并检查链接和嵌套 framework 布局。这是首次安装打包证据，不是每个产品首次运行、
数据迁移或更新/回滚的证明。

构建 Windows MSI 需要 WiX Toolset v4 或更新版本。macOS 使用系统 `hdiutil`。Rivet 会签名
最终 MSI/DMG 以及其中包含的应用。Linux 上最终 tarball 会被签名，且由于归档是确定性的，
`raco rivet verify --production` 会从包重新推导并检查分离签名。

## 未签名分发约束

支持在无付费凭据模式下发布，但产品支持页必须原样携带以下诚实约束，而不是埋起来：

- **Windows（`windows=unsigned`）**：首次启动时 MSI 和便携 exe 会显示 SmartScreen 的
  未知发布者警告。支持页应解释该对话框是什么、如何选择 *More info → Run anyway*，以及
  警告为何存在；绝不要指示用户关闭 SmartScreen 或 Defender，也绝不要把二进制描述为已验证。
  升级保持非破坏性（MSI major-upgrade 语义；便携版走已验证原子替换），使用户不必害怕更新
  路径上的对话框。
- **macOS（`macos=adhoc`）**：ad-hoc 签名 bundle 对用户标注为未签名。在真实 Developer ID +
  公证凭据存在之前，Gatekeeper 首次启动要求显式右键打开；更新 feed 仍经 Ed25519 校验，
  代码签名在更新过程中保留。不要在 UI 或文档任何位置声称已公证。
- **Linux（`linux=unsigned-package+signed-update`）**：deb/rpm 通过包管理器及其仓库信任安装；
  AppImage 依靠可执行位运行。不需要发布者账户，更新 feed 的 Ed25519 签名加校验和对等门禁
  提供信任链。架构映射（`x64`/`arm64`）是 feed 契约的一部分，不是下载页约定。

## 发布模式（跨产品标准，issue #371）

这些命名模式是每个基于 Rivet 产品的可复用标准。发布 job 按平台声明模式；它绝不能从承诺的
签名模式静默回退到未签名模式，因为每个签名模式在凭据缺失时都会失败关闭。

| 平台 | 无付费凭据默认 | 可选签名模式 |
| --- | --- | --- |
| macOS | `macos=adhoc` — `raco rivet package` / `release --development`，ad-hoc 签名，标注未签名 | `macos=developer-id+notarized` — 带 `RIVET_MACOS_SIGN_IDENTITY` + `RIVET_MACOS_NOTARY_PROFILE` 运行 `release`；Developer ID 签名、hardened runtime、公证、stapling |
| Windows | `windows=unsigned` — 可安装 MSI + 便携 zip，产品支持页给出坦率的 SmartScreen 说明 | `windows=authenticode` — 带 `RIVET_WINDOWS_SIGN_CERT_SHA1`（或 PFX）+ `RIVET_WINDOWS_TIMESTAMP_URL` 运行 `release`；RFC 3161 时间戳 |
| Linux | `linux=unsigned-package+signed-update` — 无需发布者账户即可产出 deb/rpm/AppImage/tar.gz；更新 feed 仍为 Ed25519 签名 | 与默认相同；Linux 从不需要付费发布者证书 |

每种模式都成立的不变式：

- 操作系统可执行文件签名与更新 manifest 的 Ed25519 校验相互独立。每个在线更新 feed 都经
  Ed25519 签名，并拒绝无效、重放、降级或哈希不匹配的内容，无论平台可执行文件是否带付费
  签名。
- 生产发布阶段在凭据缺失时失败关闭（`rivet-cli/signing-options.rkt`）；
  `raco rivet verify --production` 在最终产物上重新检查信任；`raco rivet
  verify-release-assets` 关闭 manifest/资产对等门禁。没有路径会声称产物并不具备的公证或
  发布者信任。
- `release --development` 用于在凭据存在前演练流程，绝不能作为已发布生产通道的门禁；承诺
  签名模式的产品发布工作流必须运行生产命令，让凭据检查成为门禁。

## 多平台发布矩阵

每种安装格式都在其平台上原生构建，因此家族发布是按平台的矩阵加一个聚合步骤：

| Leg | Runner | 产出 |
| --- | ------ | -------- |
| Windows x64 / ARM64 | `windows-latest` / `windows-11-arm` | MSI + 便携 zip + 单平台 manifest |
| macOS arm64 | `macos-latest` | DMG + zip + manifest |
| macOS x64 | `macos-15-intel` | DMG + zip + manifest |
| Linux x64 / ARM64 | `ubuntu-latest` / `ubuntu-24.04-arm` | deb + rpm + AppImage + tar.gz + manifest |

保持各 leg 可组合的约定：

- 每个 leg 都在同一 tag 的 checkout 中运行 `raco rivet release`，因此 version/build/
  identifier 在构造上完全一致——下面的家族 compose 步骤会拒绝任何不一致。
- 产物遵循家族命名（`<product>-<version>-<os>-<arch>` 加扩展名），因此更新 base URL 是
  一个扁平目录。
- 安装与 runner 架构匹配的 Racket CS 运行时（与 Rivet 自身 `architectures.yml` 演练的
  矩阵相同；校验和固定的 `setup-embed-racket` action 覆盖 Linux leg）。
- 每个 leg 上传自己的 `update-<channel>.json` 后，一个聚合 job 运行：

  ```bash
  raco rivet manifest-compose     windows/update-stable.json macos-arm64/update-stable.json     macos-x64/update-stable.json linux/update-stable.json     --output update-stable.json
  ```

  并设置 `RIVET_UPDATE_PRIVATE_KEY` 和 `RIVET_UPDATE_KEY_ID`。它会在把已认证 payload
  折叠成一个签名家族 manifest 之前校验每个 leg 的 Ed25519 签名和 key ID（每个
  平台/架构一个产物，所有元数据字段验证一致）——取代按产品手写的合并脚本。

每个安装器旁的便携 zip 由同一次 `release` 运行产出；家族更新 feed 和锁定机器直接消费它。

## 更新信任模型

HTTPS 保护传输，但不是更新信任的根。manifest 包含精确的字节 payload 和 Ed25519 签名。
签名 payload 标识应用、版本、构建号、stable/beta/dev 通道、分阶段 rollout 百分比、最低
可更新版本、回滚前驱，以及每个平台产物的 URL、字节大小、SHA-256、安装器类型和参数。

manifest 策略在签名或接受之前作为整体校验。每个发布至少有一个正大小产物；最低版本和前驱
版本都早于本次发布；平台/架构/安装器身份唯一。同一 Linux 目标的便携和 AppImage 产物可以
并存，因为它们的安装器身份不同。带版本的 wrapper、manifest、签名和产物对象都是封闭
schema；未知字段和尾部 JSON 值会失败，而不是被静默忽略。

更新器按以下顺序校验。签名 payload 在 Ed25519 校验成功前始终保持不透明字节；未认证输入
绝不会到达 manifest JSON 解析器。

1. Ed25519 签名和预期 key ID。
2. 应用身份、通道、SemVer 优先级、最低版本、rollout 桶、平台和架构。
3. 下载字节上限和签名预期大小。
4. 完整下载的便携归档的 SHA-256。
5. 该归档所携带应用在 release 和 package 校验中的平台代码签名/信任。

只有之后原生适配器才可以安装。安装、重启或健康检查失败时，仅当签名 manifest 允许回滚才
调用回滚回调。适配器把便携归档解包到同一文件系统的暂存位置，校验暂存平台签名，原子保留
旧安装，并保持该备份直到替换通过健康检查并提交。直接 MSI/MSIX/DMG/PKG/deb/rpm 安装保留
各自的平台事务或包管理器行为；Rivet 的便携适配器会拒绝它们，而不是静默绕过提权、回执或
仓库信任。AppImage 替换作为 Linux 便携策略受支持。私钥绝不属于仓库。在 checkout 之外生成
并保存，例如：

```bash
openssl genpkey -algorithm Ed25519 -outform DER -out update-private.der
openssl pkey -inform DER -in update-private.der -pubout -outform DER -out update-public.der
```

原生宿主只嵌入 `update-public.der`（或其字节）。密钥轮换通过 `key_id` 显式进行，是受支持
且有测试的双信任窗口（issue #370）：

1. 发布一个客户端版本，其更新器把 **下一个** key id 和公钥作为额外受信密钥携带，同时仍
   主要信任当前密钥——`make-updater` 用 `#:trusted-keys` 接收 `(cons key-id
   public-key-bytes)` 列表；macOS 的 RivetUpdate 接收 `additionalTrustedKeys`
   （`[String: String]`，key id → base64 公钥）。
2. 开始用下一个密钥签名发布 feed。窗口内的客户端用受信映射校验 wrapper 的 `key_id`，并用
   **该条目自己的公钥**认证 payload；受信 id 的签名若无法在其配对密钥下通过，会失败关闭，
   而不是回退到主密钥。
3. 舰队完成轮换后，发布主要信任新密钥并移除旧条目的客户端；用已退役密钥签名的 feed 会被
   直接拒绝。

每个 feed 都用其 `key_id` 选中的密钥校验；不存在“任何受信密钥可用于任何签名”的回退，
错误密钥拒绝测试同时覆盖引擎和 macOS 两侧窗口。

## 应用 API

require `rivet/distribution`。`fetch-update-manifest` 在解析前校验，`select-update` 应用
通道/版本/rollout/平台策略，`download-update` 执行限制和哈希。Linux 上把
`(current-install-kind)` 作为 `#:install-kind` 传入。这会检查可执行文件实际的 dpkg/rpm
所有权，而不是假设 `/opt` 或 `/usr` 下每个二进制都由操作系统安装；复制到这些目录的便携
应用仍保持便携。AppImage 的运行时环境仍然优先。包数据库所有权不可用时，检测器会保守地把
`/opt` 或 `/usr` 下的可执行文件视为包管理器安装，而不是尝试不安全替换；其他路径保持便携。
有特殊安装模型的应用应显式传入已知安装器类型。`'portable` 同时接受便携 ZIP 和 Linux
tar.gz feed 形态，因此 `(current-install-kind)` 对 tar.gz-only feed 仍然可用；feed 同时发布
两种形态时，传 `'targz` 强制归档。AppImage 和便携安装只选择各自匹配的 payload，deb/rpm
安装返回 `package-manager` 且不消费 AppImage feed。`prepare-platform-installation` 把已验证
的便携 ZIP、Linux `targz` 归档或 Linux AppImage 变成 Rivet 的第一方原子替换；把结果传给
`execute-platform-installation!`。Linux tar.gz 暂存要求恰好一个真实负载目录，拒绝逃逸
路径/链接和不支持的 tar 条目类型，并在旧安装移动前传播 gzip/解包失败。它与 ZIP/AppImage
复用同一事务锁、journal、重启/健康和回滚机制；产品保留负载特定校验和就绪回调。应用提供
重启和健康回调，因为它拥有进程模型和就绪信号。Windows 和 macOS 上默认暂存负载校验器要求
Authenticode 或深度严格代码签名；开发构建可注入显式校验器。

需要应用内进度 UI 的应用应使用 `make-updater`，而不是重新实现这套编排。`updater-check!`
执行已认证检查和选择，`updater-download!` 启动一个有界后台 worker，`updater-state` 返回
不可变、JSON 安全的轮询快照。`updater-cancel!` 中断活动传输。托管 worker 使用单调的
无进度和总时限，在取消或超时时清理部分文件，并拒绝并发的 check/download 操作。它有意停在
已验证的下载产物：安装同意、提权、重启和健康策略仍属于原生宿主和下文平台安装 API。

`raco rivet new --with-updates` 会生成这套表面的起步版本：`app/update.rkt` 用应用身份、
持久 rollout 桶和 `shared/update.rktd` 包装 `make-updater`；在填入 feed URL、Ed25519 公钥和
key id 之前失败关闭。生成模块有意停在“已验证下载”；安装、重启、同意和回滚仍属于下文原生
宿主适配器。

每个安装持久化一个 0 到 99 的 rollout 桶并传给 `make-updater`；每次检查都生成新值会让
分阶段发布不稳定。托管 API 只接受 Rivet 支持的 Windows、macOS 和 Linux x64/ARM64 目标，
未知架构失败关闭。其轮询阶段词汇稳定：`idle`、`checking`、`available`、`up-to-date`、
`downloading`、`downloaded`、`cancelled` 和 `error`。失败或取消的传输会保留已认证候选供
显式重试；新的检查在获取当前策略前清空它。

传 `#:journal-path` 原子持久化每个破坏性阶段。下次启动时重建同一安装并调用
`recover-platform-installation!`；它只接受完全相同的签名候选和绝对下载/目标/备份路径。
健康检查前的打断会恢复先前负载。幂等提交期间的打断会重复备份清理，而不是把健康应用回滚。

便携执行和恢复共享一个由安装目标身份派生的独占锁，独立于调用方选择的备份路径。该锁在
线程和进程触碰暂存、备份、marker 或 journal 状态之前串行化它们；竞争的更新器会显式失败。
其同级锁文件有意保持持久且为空：该文件上的操作系统锁承载所有权，因此崩溃会释放所有权，
而无需把陈旧文件清理纳入恢复。

更低层的 `make-install-plan`、`execute-install-plan!` 和 `recover-install-plan!` 仍可用于
产品特定的原生安装器。`execute-install-plan!` 接受 `#:commit` 用于健康检查后的幂等清理。
提权留在这些适配器之后，绝不进入 RVT1 或嵌入式运行时。

- `stable` 只接受正式 SemVer 版本。
- `beta` 接受稳定版本和 `beta` 预发布版本。
- `dev` 接受任何有效 SemVer 版本。

构建元数据不影响版本优先级。

## 更新 API 关键字契约

更新器手写的 Racket 侧是一个小而稳定的表面。以下是完整的关键字契约；未列出的关键字会在
运行时被拒绝，已发布版本正是这样在用户机器上失败的。`raco rivet doctor --release` 会按
已安装 rivet 自己的契约扫描宿主源码，因此漂移会在 CI 失败：

- `fetch-update-manifest` 接受 `#:key-id` `#:trusted-keys` `#:maximum-bytes` `#:connect-timeout-seconds` `#:idle-timeout-seconds`。
- `select-update` 接受 `#:install-kind`。
- `download-update` 接受 `#:on-progress` `#:progress-every` `#:stall-timeout-seconds` `#:total-timeout-seconds`。
- `fetch-sibling-asset` 接受 `#:sha256` `#:maximum-bytes` `#:on-progress` `#:connect-timeout-seconds` `#:idle-timeout-seconds`。

向这些函数添加关键字对契约扫描器是兼容新增；删除或重命名是破坏性变更，需要发布说明。

## 发布门禁

在构建安装器之前的发布 CI 中运行 `raco rivet doctor --release`。一个命令和一个退出码覆盖：
生成的客户端文件与全新重新生成一致（`raco rivet generate --check` 单独运行这一项检查）、
已提交的 schema baseline 接受当前 backend、手写宿主源码只使用已安装 rivet 接受的更新 API
关键字，以及仓库中每个 `rivet.git#...` pin 非空且与已安装 rivet 发布一致。门禁失败意味着
发布否则会带上陈旧版本戳、schema 破坏，或只在用户机器上失败的更新器调用。

## macOS 宿主侧更新

上述引擎 API 覆盖更新流程运行在 Racket 的应用。macOS 宿主以原生方式拥有整个流程的应用
不应手写：Swift 包暴露 `RivetUpdate`（`platform/macos`），这是面向已安装 `.app` bundle 的
共享更新客户端。它针对引擎校验的同一签名 wrapper 执行已认证检查
（`RivetUpdateService.check`）、带进度和取消的有界 delegate 驱动产物下载
（`downloadAndInstall`）、按签名 manifest 校验 SHA-256 和大小、`ditto` 解包、bundle 版本
确认，以及带重启的原子换装/回滚。

应用配置四个事实——feed URL、Ed25519 公钥、key id 和 bundle 名——并保留自己的 UI。配置在
构造时失败关闭：非 HTTPS feed（回环演练除外）、格式错误的 bundle 名、空 key id，以及不是
32 个原始 Ed25519 字节的公钥，都会在任何传输开始前被拒绝。下载器会立即拒绝与签名大小
不符的确定性 `Content-Length`，而不是把错误产物下载到底；即使响应没有长度，磁盘文件也
必须匹配签名大小。

下载器有意采用 delegate 驱动。逐字节迭代 `URLSession.AsyncBytes` 时，如果流的
end-of-stream 标志永不出现，continuation 可能永久挂起（在 GitHub CDN 上实际观察到：所有
字节已送达，循环永不唤醒，更新面板卡在 100%）。Delegate 完成回调是确定性的，请求/资源
超时区间约束静默停滞。在 SwiftUI 中驱动它的宿主遵循两条 UX 规则：

- 运行中的传输始终提供显式 Cancel 入口；task 取消会使 session 失效，因此被等待的调用
  总能迅速恢复。
- 除最终换装并重启步骤外，更新界面保持可手势关闭；该步骤本就会终止进程。

安装末尾的 handoff 还包含模块编码的两个陷阱：生成的换装脚本取得工作目录所有权（急切的
`defer` 清理会与脚本的宽限 sleep 竞争并销毁负载——启动时调用
`RivetUpdateService.cleanupStaleWorkDirectories()` 清扫崩溃尝试留下的目录）；已呈现的
SwiftUI sheet 会静默否决 `NSApplication.terminate`，因此模块会结束每个 sheet、终止进程，
并在退出被延迟时停止 run loop——否则幸存的旧进程可能持有单实例 lease 并悄悄杀死重启后的
更新。

## Windows 与 Linux 宿主侧更新

Windows 和 Linux 使用同一个已认证客户端，而不是用 C++ 重写 macOS Swift 模块：
`make-updater` 是共享信任和传输边界。它在解析前校验 Ed25519 wrapper，选择当前安装形态的
产物，执行时限和字节限制，并校验签名大小和 SHA-256。发布 manifest 在 Windows 上同时包含
便携 ZIP 和原生 MSI，在 Linux 上同时包含便携 ZIP 和 AppImage；传
`#:install-kind 'portable`、`'targz`、`'msi` 或 `'appimage`，让宿主绝不推导或 sidecar
信任 sibling URL。

只有最终操作系统 handoff 保持原生，而 Rivet 也提供它：

- Windows 宿主链接 `rivet-host.vcxproj` 并 include
  `platform/windows/update/update_handoff.hpp`。托管更新器产出已验证 MSI 后，
  `MsiHandoff::LaunchVerifiedInstaller` 创建进程专属 handoff，有限等待旧进程退出，运行
  `msiexec /passive /norestart`，为下次启动记录失败，并重启应用。release 回调在 helper
  存在后运行，因此单实例所有权在新进程启动前释放。`ConsumeFailure` 和
  `CleanupStaleAttempts` 完成启动生命周期。
- 应用 AppImage 更新的 Linux 宿主绝不能自己执行换装：在把旧 AppImage 移开和把新文件移入
  之间崩溃会让启动路径没有可执行文件，而死亡进程永远无法运行恢复。因此链接的
  `rivet::platform` target 暴露 `AppImageHandoff::LaunchReplacement`，即
  `MsiHandoff::LaunchVerifiedInstaller` 的进程外对应物。托管更新器产出已验证 AppImage 后，
  handoff 把生成的第一方 shell 脚本写入
  `$XDG_STATE_HOME/Rivet/updates/<application-id>/` 下的进程专属尝试目录，有限等待启动
  进程退出，然后才执行原子替换——在目标旁暂存副本、重新校验 SHA-256、重命名换装、
  schema-1 journal 阶段、幂等回滚——再重启替换并在其存活过 settle 窗口后提交。窗口内死亡的
  替换会恢复先前 AppImage（除非签名 manifest 禁止回滚），并写 `failure.txt` 供下次启动的
  `ConsumeFailure`/`CleanupStaleAttempts` 使用。自身在两次重命名之间死亡的 helper 会被下次
  尝试的 preflight 修复，因此启动路径绝不会没有可执行文件。helper 确认运行后通过
  `release_lease` 回调释放单实例 lease，然后迅速退出。journal 使用与
  `execute-platform-installation!` 相同的字段名和阶段，因此中断的 handoff 在调用方重建 plan
  后仍可用 `recover-platform-installation!` 恢复；helper 可能仍在运行时，不要从重启后的进程
  调用恢复。`DetectLinuxInstallKind` 仍是下载前 UI 策略检查，
  `RelaunchInstalledAppImage` 是提交后的 exec handoff，deb/rpm 安装仍归系统包管理器所有。

产品提供应用 id、当前版本、feed URL、公钥、key id、持久 rollout 桶和本地化 UI。它不拥有
manifest 解析、密码学、下载看门狗、暂存或安装器脚本。

## 外部验证点

CI 可以在没有发布者身份的情况下测试签名、篡改、选择、哈希、打包结构和原生编译。真实发布
仍需要发布者的 Authenticode 证书或 Apple Developer ID/公证 profile、Ed25519 更新密钥、
HTTPS 产物源，以及在受支持操作系统版本上的最终安装/升级/回滚演练。

## 门禁：签名更新 manifest 与暂存资产匹配

仅有一个有效的 Ed25519 签名**并不**证明 GitHub Release 包含所引用的字节。在发布
**publish job** 中，收集完每个平台产物并生成签名 manifest 后，在 `gh release upload`
之前运行离线对等门禁：

```sh
raco rivet verify-release-assets \
  --manifest dist/update-manifest.json \
  --dir dist \
  --public-key /secure/updates-public.der \
  --key-id my-product-2026 \
  --base-url "https://github.com/OWNER/PRODUCT/releases/download/v1.2.3" \
  --application-id site.example.product \
  --require macos:arm64:zip \
  --require windows:x64:msi \
  --require linux:x64:targz
```

公钥必须与已安装客户端嵌入的**同一个**。base URL 是不可变的带版本 release-tag 位置，不是
移动的 `latest/download` feed。门禁校验签名和密钥身份、应用 ID（提供时）、每个产物的 URL
位置和文件名、物理文件存在、精确字节长度、SHA-256 以及声明要求的平台/架构/安装器目标。
它拒绝重复资产名和不安全路径段。它既不下载文件也不修改发布。

`--require` 是**产品特定**的：三段目标检查未标记组件的产物，而
`--require windows:x64:zip:cli` 要求显式 CLI 组件，不能用应用 ZIP 满足。不要为仅 Linux
应用要求 Windows/macOS 资产，也不要为仅 CLI 工具要求桌面安装器。AppImage 安装器使用
`appimage`；便携 Linux 归档更新负载使用 `targz`。如果产品使用独立商店或包管理器 feed，
通过适当的附加门禁校验其通道。

**这是发布前产物一致性门禁，不是已安装升级测试。** 产品特定 CI 仍需要针对实际已安装 MSI、
macOS bundle 和 Linux AppImage/包管理器 handoff 的 N→N+1 检查，包括数据保留、失败恢复和
重启。已发布的签名 `update-stable.json` 无法通过文本替换修复；请用授权密钥重新生成并签名。
