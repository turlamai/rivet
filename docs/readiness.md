# Commercial desktop readiness

Status: living completion contract, started 2026-11-04. Scope: the
Windows/macOS/Linux desktop framework, its CLI, packaging, documentation and
release engineering. Mobile delivery is explicitly out of scope here and stays
in the active [desktop closeout and mobile start plan](desktop-closeout-mobile-plan.md)
and its issues.

This page answers one question: **can a commercial desktop application be built,
shipped, supported and recovered on Rivet without the application reimplementing
a framework responsibility?** It is not a marketing checklist. Every row names
the owning evidence; a row is not "done" because a document says so.

## How to read the states

- **Shipped** — implemented, covered by an automated test or native gate, and
  documented in both public languages when the row is a user journey.
- **Partial** — the mechanism exists but a platform, installation shape, gate
  or user path is missing. The remaining text names what is missing.
- **Missing** — no framework mechanism exists; a product must currently
  reimplement it.
- **Deferred** — deliberately not implemented yet, with a written reason and a
  decision owner. Deferred is not a pass for a promised public behavior.
- **Unverified** — source exists but no current native evidence was available
  while writing this page.

Native Windows/Linux behavior in this checkout is verified only by CI evidence,
not by running those systems here. A source-only audit cannot prove rendering,
focus order, or OS-delivered events.

## Desktop OS integration

The adapter primitives are broader than the generated-host wiring. The 2026-11-04
source audit found that several advertised capabilities are registered or
declared but never connected to application code; those rows are **Partial**, not
Shipped.

| Area | State | Evidence | Remaining |
| --- | --- | --- | --- |
| Window open / close / quit | Shipped | Platform hosts, native UI CI | — |
| Window position/size/maximized restore | **Missing** | No `SetWindowPlacement`, frame autosave, or GTK persistence | Per-platform save/restore helper tied to `rivet/system/settings` |
| Application menu, context menu, accelerators | **Missing** | No `MenuBar`/`MenuFlyout`, `GtkPopoverMenu`, SwiftUI `.commands` | Thin per-platform helpers plus a generated About/Preferences/Quit baseline |
| Tray / status item | Shipped (adapter) | `TrayController`, `NSStatusItem`, StatusNotifierItem | Scaffold does not acquire or wire it; capability reporting is Linux-only |
| System notifications | **Partial** | Windows balloon, `UNUserNotificationCenter`, D-Bus | No macOS delegate (foreground posts suppressed), no click/action routing, no permission/delivery status |
| File and folder dialogs | Shipped | Platform adapters | Default directory, message text, and macOS "allow other types" polish |
| Clipboard | **Partial** | Text-only adapters | No HTML/RTF/image/file-list; document the limit or extend |
| Drag and drop | **Missing** | No `IDropTarget`/`NSDragging`/`GtkDropTarget` | File-drop helpers plus a doc recipe |
| URL schemes and file associations | **Partial** | Windows MSI + macOS `Info.plist` registration | Linux emits no `MimeType`/`x-scheme-handler`; Windows per-machine install writes HKCU keys |
| Activation delivery into app code | **Missing** | macOS router closure never assigned; Windows `ActivationArguments()` and Linux argv never consumed | Wire all three hosts, forward to a Racket activation RPC, add acceptance coverage |
| Single instance | **Partial** | Linux lease + argument forwarding | Windows/macOS lease only (no forwarding); no scaffold acquires the lease; macOS lock lives in purgeable `~/Library/Caches` |
| Launch at login / autostart | Shipped (adapter) | Run key, `SMAppService`, XDG autostart | Scaffold does not wire it; Windows passes `--autostart`, Linux does not |
| Secure storage | Shipped | Credential Manager, Keychain, libsecret | Conditional Linux availability must be checked by the product |
| Settings / structured logging | **Partial** | `rivet/system/settings.rkt`, `rivet-log` sink | No file sink, rotation, retention, or Racket↔native correlation |
| Crash capture | **Partial** | Windows filter + restart, Linux `crash.log` | macOS has no hook at all; Windows writes no dump; Linux does not restart |
| Power / sleep / wake | **Missing** | No `WM_POWERBROADCAST` or `NSWorkspace` sleep hooks | Per-platform helper plus doc |
| Printing | **Missing** | No `NSPrintOperation`, `GtkPrint*`, WinUI print dialog | Print API plus PDF fallback, or an explicit product-owned recipe |
| Spellcheck | **Missing** | No `NSSpellChecker`/GTK spell integration | Document native paths or add a per-platform toggle |
| Theme / dark mode | **Partial** | Linux startup-only helper | Windows/macOS appearance query; live system-change observation |
| Custom fonts | **Missing** | No platform font registration; `docs/fonts.md` does not exist (`docs/fonts/` is website assets) | Bundle via `resources`, register per platform, document |
| Accessibility | **Partial** | Native UI e2e gate; chart labels | Windows chart has no AutomationPeer/role/tab stop; no cross-platform focus contract |
| IME / high-DPI / scaling | **Unverified** | Native controls and manifests only | Verify composed text input and chart rendering at 125–200% |
| About / version / legal / credits | **Missing** | `rivet/app-info` exists; no native surface consumes it | Generated About panel per platform |

## Application capability

| Area | State | Evidence | Remaining |
| --- | --- | --- | --- |
| Typed RPC / Event / State / Cancel | Shipped | `rivet/backend.rkt`, protocol tests, generated Swift/C++/Kotlin clients | Cooperative cancellation below |
| Schema snapshot and breaking-change gate | Shipped | `raco rivet schema`, `rivet-schema.json` | Baseline format is not specified (documentation gap) |
| Pagination, large payloads, runtime limits | Shipped | `docs/large-payloads.md`, `docs/runtime-limits.md`, decoder limit tests | — |
| Real-time chart series | Shipped | `docs/chart-series.md`, chart tests, per-host widgets | `rivet/chart` is missing from the public-API/stability snapshot |
| I18n parity and embedded host tables | Shipped | `raco rivet i18n`, `docs/configuration.md` | Product strings only |
| Cooperative RPC cancellation | **Missing** | `docs/large-payloads.md` records that handlers cannot observe Cancel | Handler-visible check, cleanup window, first real consumer |
| `Float64`, string-key Map, structured Error | **Deferred** | `docs/protocol.md` keeps the RVT1 v1 tag set closed | Phase 8 negotiation plus cross-runtime golden/fuzz evidence |
| Worker-thread FFI scheduling | **Partial** | `docs/agent-native.md` documents the workaround | General fix tracked by issue #363 |

## Distribution, install and update

| Area | State | Evidence | Remaining |
| --- | --- | --- | --- |
| MSI / DMG / deb / rpm / AppImage / tar.gz / portable ZIP | Shipped | `raco rivet release`, installer CI | #405 closes first-install/repair/uninstall qualification gaps |
| Signed update manifest and managed check/download | Shipped | `rivet/distribution`, `make-updater`, trust tests | — |
| Portable ZIP and Linux tar.gz replacement | Shipped | Shared transaction, journal, health/rollback, snapshot binding | New head needs its own native CI before release |
| Windows MSI and Linux AppImage native handoff | Shipped | `update_handoff.hpp`, native CI | Products must migrate off private batch/swap scripts (#397) |
| Linux tar.gz selection and feed entry | **Fixed on `merge/unified-updates-20261104`** | `select-update`, `release --update-payload`, `sign-manifest` | Land the branch and run its native matrix |
| Channel-named feed consistency | **Fixed on `merge/unified-updates-20261104`** | `release` and `sign-manifest` both emit `update-<channel>.json` | Products still hand-roll feeds (#397) |
| Key rotation | Shipped (code) | Dual-trust window, wrong-key tests | Manual omits `#:trusted-keys`; products must ship the next key first |
| Reproducible framework artifacts | **Partial** | `docs/releasing.md` does not claim byte-identical ZIPs | Normalize archive metadata and prove independent rebuilds |
| Microsoft Store MSIX / Mac App Store packaging | **Deferred** | `DISTRIBUTION.md` calls Store MSIX a candidate | Evaluate after a real Store pilot; never convert Store installs silently |
| Update UI and consent | Product-owned | `make-updater` phases | Products own text, consent and data migration |

## Developer experience

| Area | State | Evidence | Remaining |
| --- | --- | --- | --- |
| `new` / `build` / `dev` / `package` / `verify` / `release` | Shipped | CLI tests, docs | — |
| `doctor`, `inspect`, `acceptance`, `schema`, `i18n`, `measure`, `compliance` | Shipped | `rivet-cli`, `docs/diagnostics.md`, `docs/product-acceptance.md` | — |
| CLI version identity | Shipped | `raco rivet --version`, `rivet/tests/version.rkt` | — |
| CLI help/README parity | Shipped (2026-11-04) | `rivet-cli/usage.rkt`, `rivet/tests/cli-help.rkt`; missing automation flags added | Per-command help and `--json` coverage remain |
| Generated project CI workflow | Shipped (2026-11-04) | `rivet-cli/scaffold.rkt` writes `.github/workflows/native.yml`; `rivet/tests/scaffold-ci.rkt` | Release template still manual |
| Generated project release workflow | **Missing** | Only CI is generated; signing/update secrets remain a documented operator step | Add a comment-only release template after the update scaffold exists |
| Generated project updater wiring | **Partial** | `raco rivet new --with-updates` writes `app/update.rkt` + `shared/update.rktd` (check/download, fail-closed) | Native handoff, update UI and consent remain product work |
| Generated project tests | Shipped (2026-11-04) | `tests/smoke.rkt` plus the `starter-smoke` unit suite; scaffold test asserts both | Products still replace the scenario with real behavior |
| CLI exit-code contract | **Partial** | Documented 0/1/2 vocabulary in both diagnostics guides | Parse vs policy failures still collapse to 1; add stable error codes |
| Upgrade/migration guide per release | **Partial** | `docs/USING.md`, `CHANGELOG` | Migration section for public-contract changes |
| API stability and deprecation | **Partial** | `docs/api-stability.md` (pre-1.0) | State Racket 9.0+ explicitly; define deprecation markers/window and a support matrix |

## Documentation

Public user journeys must exist in both languages; protocol and architecture
keep one normative English definition. See the central
[documentation language policy](https://github.com/turlamai/turlamai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md).

| Journey | English | Chinese | Remaining |
| --- | --- | --- | --- |
| README / Using Rivet / Getting started | Yes | Yes | Keep paired facts current |
| Project configuration | Yes | Yes (2026-11-04) | Add the missing `linux-desktop-id` / `linux-binary-name` keys |
| Release and updates | Yes | Yes (2026-11-04) | Keep the feed/handoff/rotation facts current |
| Diagnostics | Yes | Yes (2026-11-04) | Add the remaining exit-code table |
| Troubleshooting and recovery | Yes | Yes (2026-11-04) | Keep commands and failure paths current |
| System services | Yes | Yes (2026-11-04) | The guide must keep the Partial wiring rows visible |
| Production signing / package verification | Yes | Both guides have Chinese counterparts (2026-11-04) | Keep operator facts current |
| Runtime limits / large payloads / charts | Yes | All three guides have Chinese counterparts (2026-11-04) | Keep batch/format facts in sync |
| Native UI testing / product acceptance | Yes | Both guides have Chinese counterparts (2026-11-04) | Keep evidence rules current |
| Architecture / protocol / embedding / agent guidance | Yes | English-only by policy | Keep one normative source |
| API reference (`rivet/scribblings`) | Yes | Not required | Fix the reference gaps below |
| Docs site (`docs/index.html`) | Yes | Yes | Keep command examples in sync with the CLI |

## Reference and contract drift (verified 2026-11-04)

These are documentation defects, not missing features. They matter because
agents and products copy the reference.

- The manual keyword omissions are fixed (2026-11-04): `#:trusted-keys` on
  `make-updater`/`fetch-update-manifest`, `#:diagnostic-sink` on
  `serve`/`serve-fds`, and `#:install-kind` on `select-update` are documented
  and guarded by `rivet/tests/manual-keywords.rkt`.
- `rivet/chart` is absent from `docs/api-stability.md` and
  `rivet/tests/public-api.rkt`, so its exports can change without the gate.
- The Scribble CLI section lists 13 commands while `raco rivet help` exposes
  about 45, including `--version`, `acceptance`, `matrix`, `verify-remote`,
  `generate`, `entitlements`, `i18n`, `measure`, `compliance`, `apple-review`,
  and the manifest commands.
- `linux-desktop-id` and `linux-binary-name` are validated, defaulted and
  consumed but undocumented in `configuration.md`.
- `api-stability.md` never states the minimum Racket version (9.0 in `info.rkt`)
  and has no deprecation window or marker policy.
- There is no exit-code table; a usage error, a failed build and a policy
  rejection all exit 1.
- The documentation test still does not parse every Scribble signature; the
  new `manual-keywords` gate covers the update/serve surface only.
- `rivet/backend` has no `@defmodule`; `rivet/testing` is in the stability
  snapshot but described as internal; doctor/inspect warning codes and the
  `rivet-schema.json` baseline format are unspecified; `message:hello`
  direction and `serve`/`serve-fds` port-closing and error behavior contradict
  the protocol/runtime docs. The chart capacity cap is documented; the
  decoder reads the first index as unsigned, so a negative value is not
  representable and the earlier audit item was withdrawn.

## Repository and release operations

| Area | State | Evidence | Remaining |
| --- | --- | --- | --- |
| License, contributing, security policy | Shipped | `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md` | — |
| Issue forms, PR checklist, code of conduct | Shipped (2026-11-04) | `.github/ISSUE_TEMPLATE`, `PULL_REQUEST_TEMPLATE.md`, `CODE_OF_CONDUCT.md` | — |
| Dependency updates for CI actions | Shipped (2026-11-04) | `.github/dependabot.yml` | Racket package updates remain manual |
| Tag provenance and source-package smoke | Shipped | `docs/releasing.md`, release scripts, CI | — |
| SBOM and third-party notices | Shipped | `raco rivet release`, `compliance` | Product review remains required |
| Vulnerability scanning of dependencies | **Partial** | No automated advisory/license scan in CI | Scheduled scan plus a response policy |
| Support bundle with redaction | Shipped (2026-11-04) | `raco rivet support-bundle`, `rivet/tests/support-bundle.rkt` | Applications still decide which logs to attach |
| Log rotation and retention | Shipped (2026-11-04) | `make-rotating-log-sink`, `rivet/tests/logging.rkt`; docs in both languages | Applications still choose the path and retention policy |
| Crash report capture | **Partial** | `make-crash-file-reporter` covers uncaught Racket exceptions; native hooks exist | macOS has no native fatal-signal hook; Windows writes no dump; Linux does not restart |
| Performance thresholds | **Deferred** | `docs/benchmarks.md` explains why timing has no pass/fail gate | Promote metrics only on stable hardware |
| Windows system-adapter tests | **Missing** | 936 source lines, no test target, no CI job | Win32 test executable for tray/menu/hotkey/clipboard/credential paths |
| macOS system-adapter tests | **Partial** | Clipboard, filters, menu bar, notification availability | Single instance, Keychain, login item, activation router |

## Verified backlog (2026-11-04 source audits)

These are concrete, evidence-backed items not yet reflected by a row above.
They are ordered by user impact, not by repository convenience.

### P1

- **Linux first-run prerequisite.** `getting-started` says to set
  `RIVET_RACKET_LIBRARY`/`RIVET_RACKET_BOOT_DIR` but never shows how to build an
  embeddable Racket CS; only the CI action knows. Add an EN+ZH recipe and link
  it from `doctor`'s remediation.
- **Project upgrade path.** `new` copies host/CI/acceptance templates once and
  nothing refreshes them. Add `raco rivet upgrade --check/--apply` (three-way
  diff that preserves application sources) and an EN+ZH version-pin/update/
  rollback guide.
- **Troubleshooting guide.** Common failures (missing VS/Xcode/GTK, stale
  bytecode, `dev` launch, release icons/keys, `clean`) live in error strings and
  `CONTRIBUTING.md`. Add `docs/troubleshooting.md` plus a Chinese counterpart
  and a docs-map entry.
- **Fresh Linux release checklist.** AppImage fails closed without `linux-icon`,
  but the generated README and getting-started do not mention it. List the icon
  and update-key prerequisites before the first `release`.
- **Help and README drift (partially fixed 2026-11-04).** The missing
  `entitlements`, `acceptance`, `measure` and `verify-remote` flags are now in
  one usage string, and `rivet/tests/cli-help.rkt` checks every command against
  both READMEs. Remaining: per-command `--help`, a command specification that
  dispatch and help share, and the same parity for subcommand flags.
- **Documentation parity gate.** The test checks links and CI pins but not the
  CLI blocks or the must-translate list. Add a check that both READMEs expose
  the same commands/flags and that required journeys have `zh-CN` files.
- **Flagship acceptance manifest (fixed 2026-11-05).** `examples/taskboard`
  now commits `rivet-acceptance.rktd` with backend-contract, schema-contract
  and native-build suites, validated by `acceptance --dry-run` in
  `rivet/tests/taskboard-acceptance.rkt`. Package/native-UI evidence remains
  with the framework workflow and #347.
- **Remaining English-only pages.** The platform-integration reference guides
  (Windows host, Linux display, device communication, adoption/releasing) stay
  English outside the public journey set; protocol and architecture remain the
  single normative source. All public user journeys now have Chinese
  counterparts.

### P2

- `--json` for `measure`, `generate --check`, `verify`/`package`/`release`.
- Scaffold acceptance covers only contract/build; add a package suite (or a
  commented template) so a green run does not ignore the distributable.
- `doctor --fix`/`--fix --dry-run` for a bounded allowlist of safe remediations.
- In-place `raco rivet init`; document project-name and identifier rules.
- Stable CLI error codes (including a JSON error envelope for `inspect --json`)
  and a per-subcommand exit-code table.
- Add the Rivet release version to `doctor --json`.
- Scaffold `shared/i18n` (or make `i18n.hpp` opt-in) and document the command.
- Wire a diagnostic/crash sink into generated hosts.
- Generated-release signing checklist without secrets.
- Removal/uninstall guidance (`raco pkg remove`, app uninstall, data deletion).
- Shell completions and a documented `raco docs rivet` path.
- Landing page: add a copyable install command and qualify Kotlin generation.
- Offline/air-gapped install path (release ZIP + SHA256SUMS) or an explicit
  unsupported statement.
- `new --help` should print help, not become a project name; unknown input names
  the offending token.
- `dev` failure should print a bounded remediation block (doctor, display,
  clean, log location).
- Getting-started tree should list `AGENTS.md`, `rivet-schema.json`,
  `rivet-acceptance.rktd` and `.gitignore`; optionally `git init` the project.
- `@defmodule[rivet/backend]`; resolve `rivet/testing`'s public/internal status.
- Document `doctor` warning codes and the `rivet-schema.json` baseline format.
- Document configuration validation rules (identifier charset, `device-rpcs`
  124-byte cap, localization, formats, build range).
- Enforce the shutdown frame's id/payload or soften the protocol text; clarify
  `serve` vs `serve-fds` port closing and error swallowing; fix `message:hello`
  direction and `emit-event!` failure wording.
- Document `make-chart-series`'s 2^24 cap and validate the chart decoder's
  non-negative first index.
- Specify schema entry shapes and the Keel projection contract.
- Add runnable `rivet/system` and `rivet/distribution` examples.
- Require a real `@defproc`/`@defthing` per export in the documentation test,
  and scan leaf modules.

## Open slices, in order

1. **Activation delivery** — one payload path from OS to a Racket RPC on all
   three platforms, with acceptance coverage. This is the highest-risk broken
   promise because packaging already registers the schemes.
2. **Generated app baseline** — single-instance acquisition, About/Quit, window
   state, CI workflow and release template in `raco rivet new`.
3. **Platform-reference translations (optional)** — Windows host, Linux display
   and device communication. Every public user journey is complete and
   enforced by `rivet/tests/translation-coverage.rkt`.
4. **Crash capture** — a default crash file/bundle on every platform. The
   rotating log sink and the redacted support bundle landed on 2026-11-04.
5. **Menus, notifications, drag-and-drop, fonts** — native helpers with a
   documented recipe, not a shared UI DSL.
6. **Reference-contract repair** — Scribble keywords, chart stability entry,
   CLI list, config keys, exit codes, documentation gate.
7. **Cooperative RPC cancellation** — handler-visible check, cleanup window,
   and a real long-running consumer.
8. **Reproducible framework archives** and **dependency advisory scanning**.
9. **#405 installer qualification** and **#397 consumer update migration**.

## Maintenance rule

Add or change a row only with evidence. A capability that ships as a new public
promise needs both language paths in the same change. A deferred row must keep
its reason and decision owner; silently deleting it is how a commercial promise
becomes marketing. When a row changes state, update `CHANGELOG.md` and the
canonical guide that owns the behavior; this page is the index, not the
specification.
