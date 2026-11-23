#lang racket/base

;; Child backend for bridge-test.rkt: a minimal rivet serve loop over stdio.
;; Run as `racket bridge-echo.rkt`; not a test module itself.

(require rivet/backend)

(define-rpc (echo [s : String] : String)
  (string-append s "!"))

(define-rpc (add [a : Int64] [b : Int64] : Int64)
  (+ a b))

(define-event ping : String)

(define-rpc (poke : Void)
  (ping "pong")
  (void))

(module+ main
  (serve (current-input-port) (current-output-port)))