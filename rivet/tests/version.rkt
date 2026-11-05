#lang racket/base

;; The CLI must identify the running Rivet release without reading raco's
;; package database, because bug reports and scripts need one stable line.
(require rackunit)

(define version-line (dynamic-require 'rivet-cli/usage 'rivet-version-line))
(check-regexp-match
 #px"^rivet (?:[0-9]+\\.[0-9]+\\.[0-9]+|unreleased source checkout)$"
 (version-line))
