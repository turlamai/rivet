#lang racket/base

;; The central documentation policy requires complete Chinese counterparts for
;; the public journeys. Keep that list executable instead of relying on a
;; maintainer remembering which pages were translated.

(require rackunit
         racket/file
         racket/path
         racket/runtime-path
         racket/string)

(define-runtime-path repo-root "../..")

(define public-journeys
  '("docs/USING.md"
    "docs/getting-started.md"
    "docs/configuration.md"
    "docs/diagnostics.md"
    "docs/troubleshooting.md"
    "docs/release-and-updates.md"
    "docs/package-verification.md"
    "docs/production-signing.md"
    "docs/runtime-limits.md"
    "docs/large-payloads.md"
    "docs/chart-series.md"
    "docs/system-services.md"
    "docs/native-ui-testing.md"
    "docs/product-acceptance.md"
    "docs/ci.md"
    "docs/api-stability.md"
    "docs/apple-release-readiness.md"))

(define (document-lines path)
  (with-handlers ([exn:fail? (lambda (_) 0)])
    (length (file->lines path))))

(define (check-pair relative)
  (define english (build-path repo-root relative))
  (define chinese
    (path-replace-extension english #".zh-CN.md"))
  (check-true (file-exists? english) relative)
  (check-true (file-exists? chinese)
              (format "missing Chinese counterpart for ~a" relative))
  (when (file-exists? chinese)
    (check-true (> (document-lines chinese) 20)
                (format "Chinese counterpart is too small: ~a" relative))
    (define english-text (file->string english))
    (define chinese-text (file->string chinese))
    (check-true (string-contains? english-text
                                  (path->string (file-name-from-path chinese)))
                (format "~a does not link its Chinese counterpart" relative))
    (check-true (string-contains? chinese-text
                                  (path->string (file-name-from-path english)))
                (format "~a does not link back to English" relative))))

(for ([relative (in-list public-journeys)])
  (check-pair relative))

;; The root README pair is a public entry point too.
(define readme (build-path repo-root "README.md"))
(define readme-zh (build-path repo-root "README.zh-CN.md"))
(check-true (file-exists? readme-zh))
(check-true (string-contains? (file->string readme) "README.zh-CN.md"))
(check-true (string-contains? (file->string readme-zh) "README.md"))
