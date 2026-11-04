# 生产签名

[English](production-signing.md) · **简体中文**

Rivet 有意把开发打包和生产信任凭据分开。

- `raco rivet package` 创建常规的自包含开发发布物。macOS 使用 ad-hoc 签名，使 bundle
  能在本地校验。
- `raco rivet package --production` 需要真实的平台签名凭据。Windows 使用 Authenticode
  签名和 RFC 3161 时间戳。macOS 使用 Developer ID 签名、提交 Apple 公证、staple，然后
  做生产校验。Linux 上生产打包是 `raco rivet release`：最终安装器使用分离的 Ed25519
  签名，而不是操作系统级代码签名。
- `raco rivet verify --production` 在已有产物上重新检查平台生产信任要求。当发布清理已经
  删除解包暂存目录时，Rivet 会从便携 ZIP 校验负载。Linux 上它还会重新推导安装器归档并
  校验其 Ed25519 签名。

Rivet 不会在 `rivet.rktd` 中存储证书密码、私钥、Apple 凭据或公证凭据。

## Windows

Windows 生产打包需要 Windows SDK 的 `signtool.exe`。`raco rivet doctor` 会报告是否发现它。

签名身份模式必须二选一。

### 证书存储

设置：

- `RIVET_WINDOWS_SIGN_CERT_SHA1` — 当前 Windows 账户可用的代码签名证书 SHA-1 指纹。
- `RIVET_WINDOWS_TIMESTAMP_URL` — RFC 3161 时间戳服务 URL。

证书私钥保留在 Windows 证书存储或其硬件支撑的提供方中。

### PFX

设置：

- `RIVET_WINDOWS_SIGN_PFX` — PFX/P12 代码签名证书路径。
- `RIVET_WINDOWS_SIGN_PFX_PASSWORD` — PFX 密码。该变量必须存在；允许显式空密码。
- `RIVET_WINDOWS_TIMESTAMP_URL` — RFC 3161 时间戳服务 URL。

Rivet 会把 PFX 密码传给 `signtool`，但有意从错误诊断中省略签名 argv，使失败的签名命令
不会回显秘密。

生产打包会签名 Rivet 的 `RivetHost.exe`。随包的 Racket 和 Windows App SDK DLL 保持与
上游逐字节一致的产物，不会用应用证书重新签名。

签名后，Rivet 会对可执行文件运行常规 DLL 依赖审计和 `signtool verify /pa /v`。

## macOS

这条生产路径是 **Developer ID 网站分发**，不是 Mac App Store 提交。macOS Store/iOS 的
独立风险边界和只读 Apple bundle 预检见
[Apple 发布就绪度](apple-release-readiness.md)。

macOS 生产打包需要在活动 keychain 中安装 Developer ID Application 证书，以及
`notarytool` keychain profile。

设置：

- `RIVET_MACOS_SIGN_IDENTITY` — 传给 `codesign` 的 Developer ID Application 身份。
- `RIVET_MACOS_NOTARY_PROFILE` — 传给
  `xcrun notarytool --keychain-profile` 的 keychain profile 名称。
- `RIVET_MACOS_CHANNEL` — 可选；`developer-id`（默认）或 `mac-app-store`。Mac App Store
  通道目前还没有合格的 entitlement 策略，会失败关闭（issue #358）。

在仓库之外使用 Apple 的 `notarytool store-credentials` 流程创建公证 profile。profile 可以
由 App Store Connect API key 或 Apple ID 凭据支撑；Rivet 只接收 profile 名称。

Entitlement 来自 channel/arch entitlement manifest（`raco rivet entitlements --json`），
不是硬编码列表。生产校验会失败关闭，除非 bundle 以 hardened runtime 签名且其生效
entitlement 与声明 manifest 完全一致；各架构的合格 key 集合见
[Apple 发布就绪度](apple-release-readiness.md)。

生产打包执行以下步骤：

1. 用 hardened runtime 和安全时间戳签名内嵌的 `Racket.framework`。
2. 用同一身份、hardened runtime、安全时间戳和 Rivet entitlement 签名外层 `.app`。
3. 在 `.rivet/notary/` 下创建临时公证 ZIP。
4. 用 `xcrun notarytool submit --wait` 提交。
5. 把已接受的 ticket staple 到 `.app`。
6. 运行常规包校验，外加 `xcrun stapler validate`、Gatekeeper `spctl --assess` 和
   entitlement-manifest 一致性检查。

临时公证 ZIP 是构建产物，不是凭据存储。

## Linux

Linux 没有操作系统级代码签名门禁，因此 Rivet 在安装器层定义生产信任，并复用分发层经过
审计的 Ed25519 原语：

- `raco rivet release` 把已验证的自包含包打成确定性的 `.tar.gz`（排序的 ustar 条目、
  epoch 时间戳、root 所有权、无时间戳的 gzip），并在旁边写出分离的 Ed25519 签名
  `<installer>.sig`（base64）。
- 同一个确定性归档让校验更有力：`raco rivet verify --production` 从打包目录（或发布清理
  后安全解包的便携 ZIP）重建归档，要求与已发布安装器逐字节一致，并用配置的公钥校验分离
  签名。

设置：

- `RIVET_LINUX_SIGN_PRIVATE_KEY` — 用于签名安装器的 DER 编码 Ed25519 私钥路径。
- `RIVET_LINUX_SIGN_KEY_ID` — 签名密钥的公开标识符。
- `RIVET_LINUX_SIGN_PUBLIC_KEY` — 匹配的 DER 编码公钥路径，`raco rivet verify
  --production` 需要它。

在仓库之外用与更新密钥相同的 openssl 流程生成密钥对。`raco rivet release` 还会从已验证
的包负载产出 `.deb`、`.rpm` 和 AppImage 产物。分离的 Ed25519 签名目前覆盖确定性 tarball；
原生格式只做结构校验，不会单独获得 Rivet 产物签名。apt/dnf 仓库签名等仓库元数据信任仍由
仓库运营方负责，与 Rivet 的 tarball 签名分离。

确定性 tarball 是 Rivet 最强的可独立复现 Linux 产物。原生包和 AppImage 也会接受结构、
负载、元数据和依赖校验。应用必须在其声明的发行版生命周期内补齐真实的包管理器安装、
损坏升级恢复、升级、发行版原生降级或回滚、原生 Wayland 启动和卸载证据；AppImage 启动和
原子替换另行门禁。

## CI secrets

生产签名应在独立的可信发布 job 或环境中运行，而不是在 pull-request CI 中。

通过 CI secret store 注入上述环境变量。不要把 PFX 文件或 Apple 私钥提交到仓库。如果 PFX
以编码后的 CI secret 提供，只把它写入 runner 临时目录，并把 `RIVET_WINDOWS_SIGN_PFX` 指向
那里。

macOS 上，在调用 `raco rivet package --production` 之前，在可信 runner 上准备好
Developer ID 证书/keychain 和 `notarytool` profile。

Rivet 自身的 CI 有意只演练开发打包。它验证生产凭据解析器会拒绝不完整或有歧义的配置，
而真正由证书支撑的签名需要发布者自己拥有的凭据。

## 更新内容签名

在线更新使用独立的 Ed25519 密钥；Authenticode、Developer ID、公证和 HTTPS 是额外层次，
不是替代品。只在可信发布环境中设置 `RIVET_UPDATE_PRIVATE_KEY`（DER 编码私钥路径）和
`RIVET_UPDATE_KEY_ID`（公开标识符）。公钥由应用嵌入，私钥绝不能进入源码树或普通
pull-request CI。

`raco rivet release` 先用平台身份（Authenticode、Developer ID 或 Linux Ed25519 产物密钥）
签名所含应用和最终安装器，再用 Ed25519 签名更新 manifest payload。没有更新通道的产品使用
`raco rivet release --without-updates`；平台签名、安装器校验、SBOM 和 notices 保持不变，
只省略更新 manifest 阶段。轮换与回滚策略见[发布与更新](release-and-updates.md)。
