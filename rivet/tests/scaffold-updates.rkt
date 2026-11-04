#lang racket/base

;; The opt-in updater scaffold must produce a compiling, fail-closed backend
;; surface and register its config directory as an application resource.

(require rackunit
         racket/file
         racket/path
         racket/string
         "../../rivet-cli/scaffold.rkt")

(define root (make-temporary-file "rivet-scaffold-updates-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    (define project (create-project! "UpdateDemo" root #:with-updates? #t))
    (define update-module (build-path project "app" "update.rkt"))
    (define config-path (build-path project "shared" "update.rktd"))
    (check-true (file-exists? update-module))
    (check-true (file-exists? config-path))

    (define config (call-with-input-file config-path read))
    (check-equal? (hash-ref config 'feed-url) "")
    (check-equal? (hash-ref config 'public-key-base64) "")
    (check-equal? (hash-ref config 'key-id) "")

    (define project-text (file->string (build-path project "rivet.rktd")))
    (check-true (string-contains? project-text "(resources . (\"shared\"))"))

    (dynamic-require update-module #f)
    (define configured? (dynamic-require update-module 'update-configured?))
    (define update-state (dynamic-require update-module 'update-state))
    (define check! (dynamic-require update-module 'check-for-updates!))
    (check-false (configured?))
    (check-equal? (hash-ref (update-state) 'phase) "idle")
    (check-exn #rx"not configured"
               (lambda () (check!)))

    (define readme (file->string (build-path project "README.md")))
    (check-true (string-contains? readme "Online updates (generated)"))
    (check-true (string-contains? readme "MsiHandoff"))

    ;; Opting out leaves the project unchanged.
    (define plain-root (make-temporary-file "rivet-scaffold-plain-~a" 'directory))
    (define plain (create-project! "PlainDemo" plain-root))
    (check-false (file-exists? (build-path plain "app" "update.rkt")))
    (check-false (file-exists? (build-path plain "shared" "update.rktd")))
    (check-false
     (string-contains? (file->string (build-path plain "rivet.rktd"))
                       "shared")))
  (lambda () (delete-directory/files root)))
