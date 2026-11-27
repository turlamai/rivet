#lang racket/base

(require (prefix-in keel: keel/semver)
         racket/string)

(provide version?
         version-compare
         version<?
         version<=?
         version=?
         version>=?
         version>?
         valid-channel?
         channel-accepts-version?)

;; Keep Rivet's public names and argument errors; Keel owns precedence.
(define (version? value) (keel:semver? value))

(define (version-compare a b)
  (unless (version? a)
    (raise-argument-error 'version-compare "SemVer 2.0 version string" a))
  (unless (version? b)
    (raise-argument-error 'version-compare "SemVer 2.0 version string" b))
  (keel:semver-compare a b))

(define (version<? a b) (= -1 (version-compare a b)))
(define (version<=? a b) (not (= 1 (version-compare a b))))
(define (version=? a b) (zero? (version-compare a b)))
(define (version>=? a b) (not (= -1 (version-compare a b))))
(define (version>? a b) (= 1 (version-compare a b)))

(define (valid-channel? value)
  (memq value '(stable beta dev)))

(define (channel-accepts-version? channel value)
  (unless (valid-channel? channel)
    (raise-argument-error 'channel-accepts-version? "'stable, 'beta, or 'dev" channel))
  (unless (version? value)
    (raise-argument-error 'channel-accepts-version? "SemVer 2.0 version string" value))
  (define core (car (string-split value "+")))
  (define prerelease (regexp-match #px"^[0-9]+\\.[0-9]+\\.[0-9]+-(.+)$" core))
  (case channel
    [(stable) (not prerelease)]
    [(beta)
     (or (not prerelease)
         (for/or ([part (in-list (string-split (cadr prerelease) "."))])
           (regexp-match? #px"(?i:^beta(?:[.-]|$))" part)))]
    [(dev) #t]))
