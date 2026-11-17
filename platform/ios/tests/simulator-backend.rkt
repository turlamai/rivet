#lang racket/base

;; Standalone iOS pb simulator acceptance fixture.
;; The committed GeneratedBackend.swift in platform/ios/host exposes these
;; exact RPC/State contracts; the Linux pb compiler bundles this module into
;; core.zo, while the macOS iOS Simulator loads it with its target boot files.
;; Do not replace the real simulator RPC gate with a local Racket-only test.
(require rivet/backend)

(provide start)

(define-state counter : Int64 0)

(define-rpc (greet [name : String] : String)
  (string-append "Hello, " name "!"))

(define (start input-fd output-fd)
  (serve-fds input-fd output-fd))
