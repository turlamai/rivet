#lang racket/base

;; Intentionally byte-identical to the other native Integration sample: both
;; harnesses must exercise the same RVT1 surface.
;; rivet/tests/platform-integration-samples.rkt enforces the parity, so change
;; the two files together (or delete the duplicate deliberately).

(require rivet/backend)

(provide start)

(define-state counter : Int64 10)

(define-rpc (increment [value : Int64] : Int64)
  (add1 value))

(define-rpc (wait-for-cancel : Int64)
  (sleep 3)
  1)

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
