#lang racket/base

;; A generated project must carry a runnable three-platform CI contract, not
;; require the user to discover and copy docs/ci.md.

(require rackunit
         racket/file
         racket/path
         racket/string
         "../../rivet-cli/doctor.rkt"
         "../../rivet-cli/scaffold.rkt")

(define root (make-temporary-file "rivet-scaffold-ci-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    (define project (create-project! "CiDemo" root))
    (define workflow (build-path project ".github" "workflows" "native.yml"))
    (check-true (file-exists? workflow))
    (define text (file->string workflow))
    (for ([needle (in-list '("windows-latest"
                             "macos-latest"
                             "macos-15"
                             "ubuntu-24.04"
                             "raco rivet doctor"
                             "raco rivet schema check rivet-schema.json"
                             "raco rivet acceptance --json"
                             "setup-embed-racket"
                             "libgtk-4-dev"
                             "upload-artifact"))])
      (check-true (string-contains? text needle) needle))
    ;; The pin is the installed release tag, or the explicit `main` fallback.
    (check-regexp-match #px"rivet\\.git#(?:v[0-9]+\\.[0-9]+\\.[0-9]+|main)"
                        text)
    (define installed (installed-rivet-release-version))
    (when installed
      (check-true (string-contains? text (string-append "rivet.git#v" installed))))
    (define readme (file->string (build-path project "README.md")))
    (check-true (string-contains? readme ".github/workflows/native.yml"))
    (check-true (string-contains? readme "linux-icon")))
  (lambda () (delete-directory/files root)))
