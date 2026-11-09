#lang racket/base

;; The maintained Taskboard example must carry the executable definition of
;; done the product documentation requires. `acceptance --dry-run` validates
;; the manifest, platform coverage and command resolution without launching a
;; build, so this stays a bounded check.

(require rackunit
         racket/file
         racket/path
         racket/runtime-path
         racket/system)

(define-runtime-path repo-root "../..")
(define taskboard (build-path repo-root "examples" "taskboard"))

(check-true (file-exists? (build-path taskboard "rivet-acceptance.rktd")))
(check-true (file-exists? (build-path taskboard "rivet-schema.json")))

;; The package builder drives the suite through raco by absolute path, so
;; raco may be absent from PATH while sitting next to the running racket
;; executable. Try PATH first, then the sibling of the current executable.
(define (sibling-raco)
  (define dir (path-only (find-system-path 'exec-file)))
  (and dir
       (for/or ([name (in-list (list "raco" "raco.exe"))])
         (define candidate (build-path dir name))
         (and (file-exists? candidate) candidate))))

(define raco (or (find-executable-path "raco") (sibling-raco)))
(check-true (path-string? raco))

(parameterize ([current-directory taskboard])
  (check-equal? (system*/exit-code raco "rivet" "acceptance" "--dry-run")
                0))
