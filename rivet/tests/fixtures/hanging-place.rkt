#lang racket/base

;; Test worker that accepts a request and never replies, standing in for a
;; filesystem call parked on a dead SMB share.

(require racket/place)

(provide main)

(define (main channel)
  (place-channel-get channel)
  (sleep 30))
