#lang racket/base

;; The CLI reference is a public contract. A command or automation flag that
;; exists in dispatch but not in `raco rivet help` (or either README) is
;; undiscoverable, which is how agents end up scraping usage errors.

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         "../../rivet-cli/usage.rkt")

(define-runtime-path repo-root "../..")

(define help (usage-text))

(define commands
  '("new" "doctor" "entitlements" "inspect" "acceptance" "matrix"
    "verify-remote" "schema" "clean" "support-bundle" "build" "generate" "dev" "package"
    "release" "manifest-compose" "verify-release-assets" "sign-manifest"
    "i18n" "measure" "compliance" "apple-review" "verify" "help"))

(for ([command (in-list commands)])
  (check-true (string-contains? help (format "raco rivet ~a" command))
              command)
  (for ([readme (in-list '("README.md" "README.zh-CN.md"))])
    (check-true
     (string-contains? (file->string (build-path repo-root readme))
                       (format "raco rivet ~a" command))
     (format "~a in ~a" command readme))))

(check-true (string-contains? help "raco rivet --version"))
(for ([readme (in-list '("README.md" "README.zh-CN.md"))])
  (check-true (string-contains? (file->string (build-path repo-root readme))
                                "raco rivet --version")))

;; Automation flags that dispatch accepts must be listed.
(for ([flag (in-list '("--suite" "--manifest" "--plist" "--dev-overlay"
                       "--check-overlay" "--artifact" "--seconds"
                       "--timeout-seconds" "--artifact-prefix"
                       "--output-directory"))])
  (check-true (string-contains? help flag) flag))
