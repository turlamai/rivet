#lang racket/base

;; Pure help/version text shared by the CLI and its regression tests. This
;; module must never execute a command on load: main.rkt dispatches at module
;; load, so tests require this file instead of the entry point.

(provide rivet-version-line usage-text)

;; A framework binary must be able to say which release it is. `raco pkg show`
;; is not a substitute: scripts, bug reports and `doctor` output need one
;; stable string that distinguishes a catalog install from a linked checkout.
(define (rivet-version-line)
  ;; Keep doctor lazy: main.rkt must survive a stale bytecode cache in a linked
  ;; checkout before any subcommand module loads (issue #145).
  (define installed-rivet-release-version
    (dynamic-require 'rivet-cli/doctor 'installed-rivet-release-version))
  (define release (installed-rivet-release-version))
  (if release
      (format "rivet ~a" release)
      "rivet unreleased source checkout"))

(define (usage-text)
  (string-append
   "Rivet — build native desktop apps with Racket\n\n"
   "Usage:\n"
   "  raco rivet new <name>              create a new Rivet application\n"
   "  raco rivet doctor                  inspect the local native toolchain\n"
   "  raco rivet doctor --json           emit machine-readable toolchain diagnostics\n"
   "  raco rivet doctor --release        run the release gate: generated-file freshness,\n"
   "                                     schema baseline, update-API keyword contracts, pins\n"
   "  raco rivet entitlements --json     emit the channel entitlement manifest (macOS)\n"
   "  raco rivet entitlements --plist    emit declared entitlements (--dev-overlay for CI)\n"
   "  raco rivet entitlements --check APP   fail closed unless APP matches the manifest\n"
   "  raco rivet entitlements --check-overlay APP  check the ad-hoc CI key set\n"
   "  raco rivet inspect                 show the current project's edit and verification map\n"
   "  raco rivet inspect --json          emit the agent-readable project contract\n"
   "  raco rivet acceptance              run the current platform's declared acceptance suites\n"
   "  raco rivet acceptance --json       emit bounded machine-readable acceptance evidence\n"
   "  raco rivet acceptance --dry-run    validate the manifest and resolve this platform's\n"
   "                                     suites without launching any command\n"
   "  raco rivet acceptance --suite <id>  run only the named suite\n"
   "  raco rivet acceptance --manifest <file>  use an explicit acceptance manifest\n"
   "  raco rivet matrix <report.json>... aggregate per-platform acceptance reports into the\n"
   "                                     cross-platform verification matrix\n"
   "  raco rivet matrix <report.json>... --json  emit the machine-readable matrix\n"
   "  raco rivet verify-remote --repo OWNER/REPO --ref REF [--workflow verify.yml]\n"
   "                                     [--platform <p>] [--artifact-prefix <p>]\n"
   "                                     [--timeout-seconds <n>] [--output-directory <dir>]\n"
   "                                     [--json]  trigger the per-platform acceptance legs\n"
   "                                     and fold their archived reports into the matrix\n"
   "  raco rivet schema --json           emit the current versioned API schema\n"
   "  raco rivet schema --output <file>  write a schema compatibility baseline\n"
   "  raco rivet schema check <file>     reject breaking changes from a baseline\n"
   "  raco rivet schema check <file> --json  emit a machine-readable compatibility report\n"
   "  raco rivet clean                   remove generated .rivet/build/dist artifacts\n"
   "  raco rivet support-bundle [--output <file>] [--log <file>]... [--json]\n"
   "                                      collect a redacted doctor/inspect/log bundle\n"
   "  raco rivet build                   compile backend and native host\n"
   "  raco rivet generate                regenerate Swift, C++, and Kotlin clients\n"
   "  raco rivet generate --check        fail if generated clients differ from the tree\n"
   "  raco rivet dev                     build and run the current app\n"
   "  raco rivet package                 create and verify a development distributable\n"
   "  raco rivet package --production    create, sign, and verify a production distributable\n"
   "  raco rivet package --skip-launch-smoke  package without starting the GUI artifact\n"
   "  raco rivet release                 build signed installer, update manifest, SBOM, and notices\n"
   "  raco rivet release --development   exercise release flow without platform production signing\n"
   "  raco rivet release --without-updates  release without an update manifest or update key\n"
   "  raco rivet release --update-payload <installer>:<glob>[:<component>]\n"
   "                                      add a per-platform update payload to the feed\n"
   "  raco rivet manifest-compose <inputs...> [--output <file>]\n"
   "  raco rivet verify-release-assets --manifest <feed> --dir <dist>\n"
   "                                  --public-key <DER> --key-id <id>\n"
   "                                  --base-url <immutable release-tag URL>\n"
   "                                  [--application-id <id>] [--require <os>:<arch>:<installer>[:component]]...\n"
   "                                      verify signed release asset parity\n"
   "  raco rivet sign-manifest --application-id <id> --version <v> --build <n>\n"
   "                           --channel <stable|beta|dev> --base-url <url>\n"
   "                           --key-id <id> --artifact <platform>:<arch>:<installer>:<file> ...\n"
   "                           [--private-key <der>] [--public-key <der>] [--output <file>]\n"
   "                           [--sidecars] [--minimum-version <v>] [--previous-version <v>]\n"
   "                           [--published-at <ts>] [--rollout <0-100>] [--rollback-allowed]\n"
   "                                      compose a verified family update manifest\n"
   "  raco rivet i18n                    verify shared/i18n parity and regenerate embedded tables\n"
   "  raco rivet measure size [--budget <file>] [--artifact <file>]  artifact sizes/budget\n"
   "  raco rivet measure startup [--artifact <file>] [--seconds <n>]  launch survival\n"
   "  raco rivet compliance              generate SBOM/notices and run the license audit\n"
   "  raco rivet apple-review --channel <developer-id|mac-app-store|ios-app-store>\n"
   "                          --app <path.app> [--json]  inspect actual Apple artifact\n"
   "  raco rivet verify                  re-verify the current packaged artifact\n"
   "  raco rivet verify --production     verify production trust/notarization requirements\n"
   "  raco rivet verify --skip-launch-smoke  verify without starting the GUI artifact\n"
   "  raco rivet help                    show this help\n"
   "  raco rivet --version               print the installed Rivet release version (version, -V)\n"))
