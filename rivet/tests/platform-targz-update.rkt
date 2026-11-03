#lang racket/base

(require file/gzip
         file/tar
         rackunit
         racket/file
         racket/path
         "../../rivet/distribution.rkt"
         (submod "../../rivet/distribution/platform-adapter.rkt" test-support))

(check-equal? (platform-installer-policy 'linux 'targz) 'portable)
(check-equal? (platform-installer-policy 'windows 'targz) 'unsupported)
(check-equal? (platform-installer-policy 'macos 'targz) 'unsupported)

(define root (make-temporary-file "rivet-targz-update-~a" 'directory))
(define attributes (hasheq 'permissions #o755 'modify-seconds 0))
(define (file-entry name [value #"new"])
  (tar-entry 'file (string->path name) (open-input-bytes value)
             (bytes-length value) attributes))
(define (archive name entries)
  (define path (build-path root name))
  (define tar-bytes
    (let ([out (open-output-bytes)])
      (tar->output entries out)
      (get-output-bytes out)))
  (call-with-output-file path
    (lambda (out) (gzip-through-ports (open-input-bytes tar-bytes) out #f 0)))
  path)

(define (write-text path value)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display value out))))

(dynamic-wind
  void
  (lambda ()
    ;; Container parsing runs on every host; transaction execution below is
    ;; Linux-only, so no simulated platform can masquerade as native proof.
    (define valid (archive "valid.tar.gz" (list (file-entry "payload/version.txt"))))
    (define staged (stage-targz! valid (build-path root "valid-stage")))
    (check-equal? (file->bytes (build-path staged "version.txt")) #"new")
    (check-false (file-exists? (build-path root "valid-stage" "archive.tar")))

    (define rejected
      (list
       (archive "empty.tar.gz" '())
       (archive "multiple.tar.gz" (list (file-entry "one/a") (file-entry "two/b")))
       (archive "file-root.tar.gz" (list (file-entry "not-a-directory")))
       (archive "traversal.tar.gz" (list (file-entry "../escape.txt")))
       (archive "absolute.tar.gz" (list (file-entry "/escape.txt")))
       (archive "escaping-link.tar.gz"
                (list (tar-entry 'link (string->path "payload/link")
                                 (string->path "../../escape.txt") 0 attributes)))
       (archive "link-root.tar.gz"
                (list (tar-entry 'link (string->path "payload")
                                 (string->path "elsewhere") 0 attributes)))))
    (define malformed (build-path root "malformed.tar.gz"))
    (write-text malformed "not gzip")
    (for ([path (in-list (cons malformed rejected))]
          [index (in-naturals)])
      (define stage (build-path root (format "rejected-~a" index)))
      (check-exn exn:fail? (lambda () (stage-targz! path stage)))
      (check-false (directory-exists? stage)))
    (check-false (file-exists? (build-path root "escape.txt")))

    (when (eq? (current-update-platform) 'linux)
      (define (candidate-for path)
        (define artifact
          (update-artifact 'linux 'x64 "https://updates.example/application.tar.gz"
                           (sha256-file/hex path) (file-size path) 'targz '() #f))
        (update-candidate
         (update-manifest "dev.rivet.tar-test" "2.0.0" 2 'stable
                          "2026-11-03T00:00:00Z" "1.0.0" "1.0.0"
                          #t 100 (list artifact))
         artifact))
      (define candidate (candidate-for valid))
      (for ([healthy? (in-list '(#t #f))])
        (define target (build-path root (if healthy? "success" "rollback")))
        (write-text (build-path target "version.txt") "old")
        (define journal (path-add-extension target ".json"))
        (define restarted? #f)
        (define installation
          (prepare-platform-installation
           candidate valid #:target target
           #:restart (lambda () (set! restarted? #t) 'restarted)
           #:health-check (lambda () healthy?)
           #:verify-staged
           (lambda (payload)
             (check-equal? (file->bytes (build-path payload "version.txt")) #"new"))))
        (if healthy?
            (check-equal? (execute-platform-installation! installation #:journal-path journal)
                          'restarted)
            (check-exn #rx"failed its health check"
                       (lambda () (execute-platform-installation! installation
                                                                  #:journal-path journal))))
        (check-true restarted?)
        (check-equal? (file->string (build-path target "version.txt"))
                      (if healthy? "new" "old")))

      ;; Malformed archives never rename the existing installation.
      (define target (build-path root "rejected-install"))
      (write-text (build-path target "version.txt") "untouched")
      (for ([path (in-list (cons malformed rejected))])
        (define installation
          (prepare-platform-installation (candidate-for path) path #:target target
                                         #:restart (lambda () (error 'test "must not restart"))
                                         #:health-check (lambda () #t)))
        (check-exn exn:fail? (lambda () (execute-platform-installation! installation)))
        (check-equal? (file->string (build-path target "version.txt")) "untouched"))))
  (lambda () (delete-directory/files root)))
