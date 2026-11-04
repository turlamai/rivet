#lang racket/base

(require racket/file
         racket/path
         racket/runtime-path
         "codegen.rkt"
         "doctor.rkt"
         "project.rkt")

(provide create-project!)

(define-runtime-path rivet-root "..")

(define (safe-project-name? s)
  (regexp-match? #px"^[A-Za-z][A-Za-z0-9_-]*$" s))

(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'error (lambda (out) (display text out))))

(define backend-template
  #<<RKT
#lang racket/base

(require rivet/backend)

(provide start greeting)

(define (greeting name)
  (format "Hello, ~a!" name))

(define-event notification : String)
(define-state counter : Int64 0)

(define-rpc (greet [name String] : String)
  (greeting name))

(define-rpc (notify [message String] : Void)
  (notification message)
  (void))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
  )

(define acceptance-template
  #<<ACCEPTANCE
#hasheq(
 (version . 1)
 (requirements
  . (#hasheq((kind . contract) (platforms . (windows macos linux)))
     #hasheq((kind . unit) (platforms . (windows macos linux)))
     #hasheq((kind . native-build) (platforms . (windows macos linux)))))
 (suites
  . (#hasheq((id . schema-contract)
             (kind . contract)
             (platforms . (windows macos linux))
             (command . ("raco" "rivet" "schema" "check" "rivet-schema.json" "--json"))
             (timeout-seconds . 120)
             (evidence . ()))
     #hasheq((id . starter-smoke)
             (kind . unit)
             (platforms . (windows macos linux))
             (command . ("raco" "test" "tests/"))
             (timeout-seconds . 120)
             (evidence . ()))
     #hasheq((id . native-build)
             (kind . native-build)
             (platforms . (windows macos linux))
             (command . ("raco" "rivet" "build"))
             (timeout-seconds . 1800)
             (evidence . ())))))
ACCEPTANCE
  )

(define (starter-readme name)
  (format
   (string-append
    "# ~a\n\n"
    "A first-party native desktop app powered by Racket and Rivet.\n\n"
    "## Start here\n\n"
    "```bash\n"
    "raco rivet inspect --json\n"
    "raco rivet schema --json\n"
    "raco rivet doctor\n"
    "raco rivet acceptance --json\n"
    "raco rivet dev\n"
    "```\n\n"
    "`doctor` checks the local Racket/native toolchain and prints actionable fixes when something required is missing. `dev` rebuilds the Racket backend, regenerates the typed native client, builds the current platform host, and launches the app.\n\n"
    "## Edit the app\n\n"
    "- Shared Racket logic: `app/backend.rkt`\n"
    "- Windows UI: `windows/MainWindow.xaml` and `windows/MainWindow.xaml.cpp`\n"
    "- macOS UI: `macos-host/Sources/RivetHost/ContentView.swift` and `RivetHostApp.swift`\n"
    "- Linux UI: `linux/src/main.cpp` (GTK4)\n"
    "- Packaged application resources and icons: configure `resources`, `windows-icon`, `macos-icon`, and `linux-icon` in `rivet.rktd`; AppImage release fails closed without `linux-icon`\n"
    "- Continuous integration: `.github/workflows/native.yml` builds and runs acceptance on Windows, macOS, and Linux; keep its Rivet pin in sync with your installed release\n"
    "- App identity/deployment targets: `rivet.rktd`\n"
    "- Versioned public API baseline: `rivet-schema.json`\n"
    "- Executable completion evidence: `rivet-acceptance.rktd`; its `starter-smoke`\n"
    "  suite runs `tests/smoke.rkt`, so replace that scenario with real product behavior\n\n"
    "## Design and verify the native interaction\n\n"
    "Use the running native app as the interactive prototype; a separate mockup is optional. Before coding a user-facing flow, write its behavior into the product's existing design/spec: initial state, action, visible result, saved effect, error/recovery, per-platform presentation, and evidence. Follow `AGENTS.md` for save/cancel/focus/keyboard and accessibility rules. Review the packaged window, capture a screenshot when supported, and exercise the workflow through native UI automation. A green build alone is not a UX pass.\n\n"
    "## When Racket does not already have the capability\n\n"
    "Run `raco rivet inspect --json` and read `capability-sourcing`. Prefer a built-in or maintained Racket package; keep platform-owned features in the native host; use a small safe FFI wrapper for a stable C ABI; use an argv-based subprocess for coarse-grained tools; reserve a sidecar for persistent or crash-isolated runtimes. The generated `AGENTS.md` contains the safety and packaging checks.\n\n"
    "## Ship a build\n\n"
    "```bash\n"
    "raco rivet acceptance --json\n"
    "raco rivet build\n"
    "raco rivet package\n"
    "raco rivet verify\n"
    "```\n\n"
    "Full tutorial: https://github.com/turlamai/rivet/blob/main/docs/getting-started.md\n"
    "中文教程: https://github.com/turlamai/rivet/blob/main/docs/getting-started.zh-CN.md\n"
    "Native-host CI: https://github.com/turlamai/rivet/blob/main/docs/ci.md\n"
    "Rivet website: https://rivet.jrtx.site\n")
   name))

(define starter-agents
  #<<AGENTS
# Rivet agent contract

Human-first. Agent-native. Local by design.

## Start every task here

```bash
raco rivet inspect --json
raco rivet doctor --json
```

`inspect` is the machine-readable project map. It identifies the shared Racket
backend, each native UI edit point, platform maturity, generated directories,
and safe lifecycle commands. `doctor` reports the exact local toolchain and
returns a failing exit status when the current host is not usable.

Before editing an existing repository, inspect `git status`, fetch its tracked
remote, and update with fast-forward-only semantics. If the worktree is dirty,
the branch has diverged, or the remote is unavailable, stop and report that
state; never hide it with stash, reset, or generated-file cleanup.

## Architecture boundary

- Keep shared application and domain logic in `app/backend.rkt`.
- Keep Windows UI native in WinUI 3 / C++/WinRT under `windows/`.
- Keep macOS UI native in SwiftUI/AppKit under `macos-host/`.
- Keep Linux UI native in GTK4 under `linux/`.
- Do not introduce a cross-platform UI DSL or bypass RVT1 with an ad-hoc IPC.
- iOS/iPadOS/watchOS and Android are foundation targets until their
  generated app, embedding, packaging, signing, and device workflows exist.

## Native interaction workflow

Treat the running first-party native application as the interactive prototype.
A separate mockup or design tool is optional, not a precondition for coding.
Before changing a user-facing flow, read the product's canonical design
specification if one exists. If none exists, place the first scenario in the
product README or create one canonical spec, not a competing document. Record
a scenario with these fields:

`scenario -> initial state -> user action -> visible result -> persisted effect
-> failure/recovery -> per-platform presentation -> acceptance evidence`.

Define the primary action and navigation, selection versus activation, draft
lifetime, explicit-save versus auto-save behavior, cancellation, Escape order,
focus restoration, undo, keyboard/IME behavior, and empty/loading/error/offline
states before writing the host views. Users must be able to tell whether an
edit was saved, is pending, or failed; never silently discard a draft.

Implement the same user-visible semantics with each OS's own controls and
conventions, not pixel-identical layouts. Give native elements stable accessible
names and identifiers, keyboard reachability, readable scaling, and clear
focus/error feedback. Review real packaged windows with screenshots where
supported and exercise the primary workflow using native UI automation.
Verify the visible result AND persisted effect across restart, plus cancel
and failure/recovery paths. A green build, RPC-only test, or screenshot alone
is not UX acceptance; if a native leg or visual review is missing, say so
rather than reporting it as passed.

Rivet's interaction contract and platform driver guidance:
https://github.com/turlamai/rivet/blob/main/docs/agent-native.md#author-the-product-interaction-contract
https://github.com/turlamai/rivet/blob/main/docs/native-ui-testing.md

## Capability sourcing

When a feature is not already present, do not reject Racket or add another
runtime by reflex. Read `capability-sourcing` from `inspect --json`, then choose
the narrowest boundary that fits:

1. Prefer a Racket built-in or maintained package. Discover candidates with
   `raco docs <term>`, `raco pkg show`, and
   `raco pkg catalog-show --all --only-names`; inspect a candidate with
   `raco pkg catalog-show --modules <package>`.
2. Put UI, lifecycle, accessibility, notification, device, and other
   platform-owned behavior in the first-party native host.
3. Use FFI for a stable C ABI that needs frequent, low-latency in-process
   calls. Hide `ffi/unsafe` behind a small safe module with explicit ownership,
   callback, thread, ABI, and native-library packaging rules.
4. Use `subprocess` or `system*` for a mature executable doing coarse-grained
   work. Pass an executable and argv directly; never construct a shell command.
   Add a version probe, timeout, bounded/concurrently drained output, exit-code
   handling, cancellation, packaging, and license checks.
5. Use a sidecar only for a persistent runtime, streaming workload, unstable
   ABI, or required crash isolation. Own authentication, protocol versioning,
   resource limits, restart/shutdown, packaging, and offline behavior.
6. Implement the capability only when it is small or security-critical and
   owning it is cheaper than owning the dependency boundary.

For every choice, verify Racket 9.0 CS support, license/redistribution terms,
all target OS/architectures, upstream maintenance, reproducible installation,
failure behavior, packaged dependency closure, and a clean-machine smoke test.

## Ownership

Source you may edit:

- `app/`
- `windows/`
- `macos-host/`
- `linux/`
- `rivet.rktd`
- `rivet-schema.json` when an API compatibility break is intentional
- `rivet-acceptance.rktd` when product acceptance requirements change
- declared application resources

Generated output you should not hand-edit:

- `windows/GeneratedBackend.hpp`
- `macos-host/Sources/RivetHost/GeneratedBackend.swift`
- `linux/GeneratedBackend.hpp`
- `.rivet/`
- `build/`
- `dist/`
- `windows/Generated Files/`
- `windows/obj/`
- `windows/RivetHost/`
- `macos-host/.build/`

`raco rivet build` regenerates the typed clients. Use `raco rivet clean` to
remove transient build output while keeping the generated client sources that
make the native API reviewable.

## Verification loop

This project includes a source-controlled `rivet-schema.json` API baseline.
Refresh it only after deliberately changing the public backend schema:

```bash
raco rivet schema --output rivet-schema.json
```

Before accepting later API changes, run the compatibility gate. Adding a new
RPC, Event, State, Record, or Enum type is compatible; removing one or changing
a type, argument order, result, Record field/order, or an existing Enum's
cases/order is breaking:

```bash
raco rivet schema check rivet-schema.json --json
```

`rivet-acceptance.rktd` is the source-controlled completion contract. Add a
suite for every behavior a change claims, keep native UI drivers native to the
platform, and never weaken requirements or expected evidence merely to make a
change green. Run the current platform's required suites with:

```bash
raco rivet acceptance --json
```

Do not call work complete when a required suite was skipped, was not run on its
declared platform, timed out, or exercised only a development substitute for
the packaged artifact named by the product contract.

```bash
raco rivet build
raco rivet dev
raco rivet package
raco rivet verify
```

Pull-request CI must run `raco rivet build` for the Windows, macOS, and Linux
hosts on the same runner image classes used for release. A release job must not
be the first place native source is compiled. Follow Rivet's native-host CI
guide: https://github.com/turlamai/rivet/blob/main/docs/ci.md

After changing RPC, Event, State, Record, or Enum declarations, run the
compatibility gate and rebuild before editing code that consumes generated native APIs.
Update the baseline only when a breaking change is intentional and governed by
the application's release policy. Preserve the first `rivet: error:` line and
nearby compiler output when diagnosing a failure.
AGENTS
  )

;; A generated project must compile on every supported native host before its
;; first release. The pin is the installed Rivet release; a source checkout
;; falls back to `main` with an explicit warning in the file.
(define (starter-ci-workflow)
  (define release (installed-rivet-release-version))
  (define pin (if release (string-append "v" release) "main"))
  (format
   #<<YAML
# Generated by Rivet ~a. Keep every Rivet pin below in sync when you upgrade.
# A generated project owns this file: edit jobs, not the pinned contract.
name: native-hosts

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.event_name }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v7
      - uses: Bogdanp/setup-racket@v1.15
        with:
          architecture: x64
          distribution: full
          variant: CS
          version: '~a'
      - run: raco pkg install --auto --no-docs 'https://github.com/turlamai/rivet.git#~a'
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet acceptance --json > acceptance-report.json
        shell: bash
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: acceptance-report-windows
          path: acceptance-report.json

  macos:
    strategy:
      fail-fast: false
      matrix:
        runner: [macos-latest, macos-15]
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v7
      - uses: Bogdanp/setup-racket@v1.15
        with:
          architecture: x64
          distribution: full
          variant: CS
          version: '~a'
      - run: raco pkg install --auto --no-docs 'https://github.com/turlamai/rivet.git#~a'
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet acceptance --json > acceptance-report.json
        shell: bash
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: acceptance-report-macos-${{ matrix.runner }}
          path: acceptance-report.json

  linux:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - name: Set up embeddable Racket CS
        uses: turlamai/rivet/.github/actions/setup-embed-racket@~a
      - name: Install GTK4 development files
        run: |
          sudo apt-get update
          sudo apt-get install --yes libgtk-4-dev
      - name: Install the matching Rivet package
        run: raco pkg install --auto --no-docs 'https://github.com/turlamai/rivet.git#~a'
      - run: raco rivet doctor
      - run: raco rivet schema check rivet-schema.json
      - run: raco rivet acceptance --json > acceptance-report.json
        shell: bash
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: acceptance-report-linux
          path: acceptance-report.json
YAML
   pin (version) pin (version) pin pin pin))

(define starter-smoke-test
  #<<SMOKE
#lang racket/base

;; A generated project starts with one real test so `raco rivet acceptance`
;; proves behavior instead of only compiling. Replace this scenario with the
;; product's smallest critical flow.
(require rackunit
         "../app/backend.rkt")

(check-equal? (greeting "Rivet") "Hello, Rivet!")
SMOKE
  )

(define starter-update-config
  #<<UPDATE-CONFIG
;; Generated update feed configuration. Fill in all three values before the
;; module can check for updates. The public key is the raw 32-byte Ed25519 key,
;; base64-encoded, matching the key used to sign the release feed.
;; Optional: add (install-kind . msi) or (install-kind . appimage) when the
;; detected portable shape is wrong for your installer.
#hasheq((feed-url . "")
        (public-key-base64 . "")
        (key-id . "")
        (channel . stable))
UPDATE-CONFIG
  )

(define starter-update-module
  #<<UPDATE-MODULE
#lang racket/base

;; Generated update check/download surface. Installation, restart, health and
;; consent remain in the native host; see README.md and Rivet's release guide.

(require json
         racket/file
         racket/path
         racket/string
         rivet/app-info
         rivet/distribution
         rivet/resources
         rivet/system)

(provide update-configured?
         check-for-updates!
         download-update!
         cancel-update!
         update-state
         current-update-data-directory)

(define current-update-data-directory (make-parameter #f))

(define (read-config)
  (call-with-input-file (resource-path "shared" "update.rktd") read))

(define (config-ref config key default)
  (hash-ref config key default))

(define (decoded-public-key config)
  (define encoded (config-ref config 'public-key-base64 ""))
  (and (string? encoded)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (base64-string->bytes encoded))))

(define (update-configured?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define config (read-config))
    (define key (decoded-public-key config))
    (define feed (config-ref config 'feed-url ""))
    (define key-id (config-ref config 'key-id ""))
    (and (string? feed) (not (string=? (string-trim feed) ""))
         (string? key-id) (not (string=? (string-trim key-id) ""))
         (bytes? key) (= 32 (bytes-length key)))))

(define updater (box #f))

(define (current-updater)
  (cond
    [(unbox updater) (unbox updater)]
    [else
     (unless (update-configured?)
       (error 'update
              "update feed is not configured; fill in shared/update.rktd"))
     (define config (read-config))
     (define data-directory
       (or (current-update-data-directory)
           (build-path (find-system-path 'pref-dir)
                       (app-identifier)
                       "updates")))
     (make-directory* data-directory)
     (define settings
       (make-settings-store (build-path data-directory "settings.json")))
     (define adapter
       (updater-settings-adapter
        (lambda (key) (settings-ref settings key #f))
        (lambda (key value) (settings-set! settings key value))))
     (define configured-kind (config-ref config 'install-kind #f))
     (define created
       (make-updater
        #:application-id (app-identifier)
        #:current-version (app-version)
        #:channel (string->symbol
                   (format "~a" (config-ref config 'channel 'stable)))
        #:install-kind
        (if configured-kind
            (string->symbol (format "~a" configured-kind))
            (current-install-kind))
        #:public-key (decoded-public-key config)
        #:key-id (config-ref config 'key-id "")
        #:manifest-url (config-ref config 'feed-url "")
        #:data-directory data-directory
        #:rollout-bucket (resolve-rollout-bucket! adapter)))
     (set-box! updater created)
     created]))

(define (check-for-updates!)
  (updater-check! (current-updater)))

(define (download-update!)
  (updater-download! (current-updater)))

(define (cancel-update!)
  (when (unbox updater)
    (updater-cancel! (unbox updater))))

(define (update-state)
  (if (unbox updater)
      (updater-state (unbox updater))
      (hasheq 'phase "idle"
              'percent 0
              'message #f
              'downloadedPath #f
              'availableVersion #f
              'currentVersion "")))
UPDATE-MODULE
  )

(define starter-updates-readme
  (string-append
   "\n## Online updates (generated)\n\n"
   "`app/update.rkt` checks and downloads a signed update into the shared\n"
   "`shared/update.rktd` feed before any native installation. Fill in\n"
   "`feed-url`, `public-key-base64` and `key-id`; until then the module fails\n"
   "closed with a clear message.\n\n"
   "The generated module stops at a verified download. Installation, restart,\n"
   "consent and rollback stay in each native host: use MsiHandoff on Windows,\n"
   "AppImageHandoff on Linux, and RivetUpdate on macOS. See\n"
   "https://github.com/turlamai/rivet/blob/main/docs/release-and-updates.md.\n"))

(define (create-project! name [parent (current-directory)]
                            #:with-updates? [with-updates? #f])
  (unless (safe-project-name? name)
    (raise-arguments-error 'rivet-new
                           "invalid project name; use letters, digits, '-' or '_'"
                           "name"
                           name))
  (define root (build-path parent name))
  (when (or (directory-exists? root) (file-exists? root))
    (raise-arguments-error 'rivet-new "destination already exists" "path" root))

  (make-directory* root)
  (write-text (build-path root "README.md")
              (string-append (starter-readme name)
                             (if with-updates? starter-updates-readme "")))
  (write-text (build-path root "AGENTS.md") starter-agents)
  (write-text
   (build-path root "rivet.rktd")
   (format
    "#hasheq((name . ~s) (display-name . ~s) (publisher . ~s) (version . ~s) (build . ~s) (identifier . ~s) (release-channel . stable) (url-schemes . ()) (file-associations . ()) (resources . ~s) (device-rpcs . ()) (macos-min-version . ~s) (windows-min-version . ~s) (backend . \"app/backend.rkt\") (module . \"backend\") (entry . \"start\") (protocol . 1))\n"
    name
    name
    name
    default-project-version
    default-project-build
    (default-project-identifier name)
    (if with-updates? '("shared") '())
    default-macos-min-version
    default-windows-min-version))
  (write-text (build-path root "rivet-acceptance.rktd") acceptance-template)
  (write-text (build-path root ".github" "workflows" "native.yml")
              (starter-ci-workflow))
  (write-text (build-path root "app" "backend.rkt") backend-template)
  (write-text (build-path root "tests" "smoke.rkt")
              starter-smoke-test)
  (when with-updates?
    (write-text (build-path root "app" "update.rkt") starter-update-module)
    (write-text (build-path root "shared" "update.rktd")
                starter-update-config))
  (write-text
   (build-path root ".gitignore")
   (string-append
    ".rivet/\n"
    "build/\n"
    "dist/\n"
    "windows/Generated Files/\n"
    "windows/obj/\n"
    "windows/RivetHost/\n"
    "macos-host/.build/\n"
    ".DS_Store\n"))

  (define windows-template (build-path (simplify-path rivet-root #t) "platform" "windows" "host"))
  (unless (directory-exists? windows-template)
    (error 'rivet-new "Windows host template is missing: ~a" windows-template))
  (copy-directory/files windows-template (build-path root "windows"))

  (define macos-template (build-path (simplify-path rivet-root #t) "platform" "macos" "host"))
  (unless (directory-exists? macos-template)
    (error 'rivet-new "macOS host template is missing: ~a" macos-template))
  ;; Keep the app host directory distinct from Rivet's own platform/macos
  ;; package. SwiftPM uses the final path element as local package identity.
  (copy-directory/files macos-template (build-path root "macos-host"))

  (define linux-template (build-path (simplify-path rivet-root #t) "platform" "linux" "host"))
  (unless (directory-exists? linux-template)
    (error 'rivet-new "Linux host template is missing: ~a" linux-template))
  (copy-directory/files linux-template (build-path root "linux"))
  ;; A fresh project starts with a usable compatibility gate. Builds never
  ;; rewrite this source-controlled baseline; applications update it only when
  ;; an API change is deliberate.
  (write-schema-snapshot! (load-project root) (build-path root "rivet-schema.json"))
  root)
