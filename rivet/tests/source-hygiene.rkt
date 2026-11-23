#lang racket/base

;; Whitespace hygiene for every Racket source in the package.
;;
;; The repository does not use `raco fmt`: all 186 tracked .rkt files follow a
;; consistent hand-maintained style that differs from the formatter's output,
;; so a formatter gate would mean reformatting the whole code base for no
;; functional gain. What is worth locking in is the objective hygiene the
;; code base already keeps: no tab characters, no trailing whitespace, at
;; most one blank line in a row, and a final newline. These are the things
;; that produce noisy diffs, merge conflicts and patched-in double blank
;; lines, and they are cheap to check everywhere the suite runs.
;;
;; The Windows development checkout uses core.autocrlf=true, so CRLF is
;; normalized before checking; the rules are about the content Git stores.

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root-reference "../..")
(define package-root (simplify-path repository-root-reference))

(define (skipped-directory? path)
  (member (path->string path) '("compiled" ".git" "build")))

;; Walk the package without descending into VCS/build output directories.
(define (racket-sources directory)
  (append*
   (for/list ([entry (in-list (directory-list directory #:build? #t))])
     (cond
       [(directory-exists? entry)
        (if (skipped-directory? entry) '() (racket-sources entry))]
       [(and (string-suffix? (path->string entry) ".rkt") (file-exists? entry))
        (list entry)]
       [else '()]))))

(define sources
  (sort (racket-sources package-root) string<? #:key path->string))

(check-true (> (length sources) 100)
            "the hygiene check must see the package's Racket sources")

(define (normalize text)
  (string-replace text "\r\n" "\n"))

(define (leading-blank-runs lines)
  ;; 1-based line numbers where a second (or later) consecutive blank line starts.
  (for/list ([line (in-list (rest lines))]
             [previous (in-list lines)]
             [index (in-naturals 2)]
             #:when (and (string=? line "") (string=? previous "")))
    index))

(define violations '())

(for ([path (in-list sources)])
  (define text (normalize (file->string path)))
  (define rel (find-relative-path package-root path))
  (define lines (string-split text "\n"))
  (define (note . message)
    (set! violations (cons (format "~a: ~a" rel (apply string-append message))
                           violations)))

  (for ([line (in-list lines)]
        [index (in-naturals 1)])
    (when (string-contains? line "\t")
      (note "tab character on line " (number->string index)))
    (when (regexp-match? #px"[ \t]+$" line)
      (note "trailing whitespace on line " (number->string index))))

  (define blank-runs (leading-blank-runs lines))
  (unless (empty? blank-runs)
    (note "more than one consecutive blank line at "
          (string-join (map number->string blank-runs) ", ")))

  (unless (string-suffix? text "\n")
    (note "missing final newline")))

(for ([violation (in-list (reverse violations))])
  (eprintf "  ~a\n" violation))

(check-true (empty? violations)
            (format "~a whitespace violation(s); see standard error"
                    (length violations)))
