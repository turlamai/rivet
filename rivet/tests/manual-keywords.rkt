#lang racket/base

;; The Scribble signatures are what hosts copy. A documented keyword that the
;; function does not accept fails on a user machine; an implemented keyword
;; that is not documented is undiscoverable. Compare both directions for the
;; update and serve surface that the release gate also scans in host source.

(require rackunit
         racket/file
         racket/list
         racket/runtime-path
         racket/string
         "../backend.rkt"
         "../distribution.rkt")

(define-runtime-path manual "../scribblings/rivet.scrbl")

(define text (file->string manual))

(define (proc-block name)
  (define prefix (string-append "@defproc[(" name))
  (define matches
    (regexp-match-positions* (regexp (regexp-quote prefix)) text))
  (define start
    (for/first ([match (in-list matches)]
                #:when (let ([finish (cdr match)])
                         (or (= finish (string-length text))
                             (char-whitespace? (string-ref text finish))
                             (char=? (string-ref text finish) #\]))))
      (car match)))
  (unless start
    (raise-arguments-error 'manual-keywords
                           "manual has no @defproc for the function"
                           "name" name))
  (define body-start (+ start (string-length prefix)))
  (define tail (substring text body-start))
  (define ends
    (filter values
            (for/list ([marker (in-list '("@defproc[" "@section{" "@subsection{"))])
              (define found
                (regexp-match-positions (regexp (regexp-quote marker)) tail))
              (and found (caar found)))))
  (substring text start
             (+ body-start (if (null? ends) (string-length tail) (apply min ends)))))

(define (documented-keywords name)
  (sort (remove-duplicates
         (for/list ([m (in-list (regexp-match* #px"#:([a-z][a-z0-9-]*)" (proc-block name)))])
           (cadr (regexp-match #px"#:([a-z][a-z0-9-]*)" m))))
        string<?))

(define (implemented-keywords procedure)
  ;; The second value is the complete accepted-keyword list; the first repeats
  ;; the required subset.
  (define-values (_required all) (procedure-keywords procedure))
  (sort (map keyword->string all) string<?))

(define documented
  `(("fetch-update-manifest" ,fetch-update-manifest)
    ("fetch-sibling-asset" ,fetch-sibling-asset)
    ("select-update" ,select-update)
    ("download-update" ,download-update)
    ("make-updater" ,make-updater)
    ("serve" ,serve)
    ("serve-fds" ,serve-fds)))

(for ([entry (in-list documented)])
  (define name (car entry))
  (define procedure (cadr entry))
  (check-equal? (documented-keywords name)
                (implemented-keywords procedure)
                name))
