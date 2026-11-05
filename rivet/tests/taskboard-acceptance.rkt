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

(define raco (find-executable-path "raco"))
(check-true (path-string? raco))

(parameterize ([current-directory taskboard])
  (check-equal? (system*/exit-code raco "rivet" "acceptance" "--dry-run")
                0))
