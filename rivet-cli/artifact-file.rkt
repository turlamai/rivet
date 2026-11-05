#lang racket/base

;; One sidecar convention for every release artifact: append `.sha256` and
;; write the conventional `<hash>  <filename>` line. Callers must not use
;; path-add-extension here: it treats the final extension as part of the base
;; name and would produce `app_zip.sha256` instead of `app.zip.sha256`.

(require racket/file
         racket/path
         "../rivet/distribution/crypto.rkt")

(provide sidecar-path
         write-sha256-sidecar!)

(define (sidecar-path artifact)
  (string->path (string-append (path->string artifact) ".sha256")))

(define (write-sha256-sidecar! artifact)
  (define sidecar (sidecar-path artifact))
  (call-with-output-file sidecar
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out "~a  ~a~n"
               (sha256-file/hex artifact)
               (path->string (file-name-from-path artifact)))))
  sidecar)
