#lang racket/base

;; The Linux and Windows native integration harnesses intentionally share one
;; Racket sample (issue #456). Byte equality is the contract: a change made to
;; one platform's harness surface must reach the other, or the sample must be
;; replaced by a generated file first.

(require rackunit
         racket/file
         racket/path
         racket/runtime-path)

(define-runtime-path repository-root-reference "../..")
(define repository-root (simplify-path repository-root-reference #t))

(define linux-sample
  (build-path repository-root "platform" "linux" "Integration" "backend.rkt"))
(define windows-sample
  (build-path repository-root "platform" "windows" "Integration" "backend.rkt"))

(check-true (file-exists? linux-sample))
(check-true (file-exists? windows-sample))
(check-equal? (file->bytes windows-sample)
              (file->bytes linux-sample)
              "platform/linux and platform/windows Integration samples must stay byte-identical")
