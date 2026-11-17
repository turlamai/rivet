#lang racket/base

;; The AppKit harness deliberately differs from the Linux and Windows samples:
;; it also loads rivet/distribution into the embedded runtime (proving the
;; shared library links there) and leaves the cancellation probe to the other
;; two samples.

(require rivet/backend
         rivet/distribution)

(provide start)

(define-state counter : Int64 10)

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
