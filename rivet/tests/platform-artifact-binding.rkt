#lang racket/base

;; Bind the bytes consumed by the platform adapter to an authenticated
;; manifest, even if its caller's previously downloaded file was replaced.
(require crypto
         crypto/all
         file/zip
         rackunit
         racket/file
         racket/path
         "../../rivet/distribution.rkt")

(use-all-factories!)
(define root (make-temporary-file "rivet-artifact-binding-~a" 'directory))
(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display text out))))
(define (make-archive name text)
  (write-text (build-path root "payload" "version.txt") text)
  (define archive (build-path root name))
  (parameterize ([current-directory root]) (zip archive "payload"))
  archive)
(define signer (generate-private-key 'eddsa '((curve ed25519))))
(define pub (datum->pk-key (pk-key->datum signer 'rkt-public) 'rkt-public))
(define key-id "artifact-binding-test")

(dynamic-wind
  void
  (lambda ()
    (define trusted (make-archive "trusted.zip" "aaaaaaa"))
    (define altered (make-archive "altered.zip" "bbbbbbb"))
    (check-equal? (file-size trusted) (file-size altered)
                  "same-size substitution must exercise SHA-256, not just size")
    (define artifact
      (update-artifact (current-update-platform) 'x64
                       "https://updates.example/application.zip"
                       (sha256-file/hex trusted) (file-size trusted) 'zip '() #f))
    (define manifest
      (update-manifest "dev.rivet.binding" "2.0.0" 2 'stable
                       "2026-11-03T00:00:00Z" "1.0.0" "1.0.0"
                       #t 100 (list artifact)))
    (define signed (open-output-bytes))
    (write-signed-manifest manifest signer key-id signed)
    (define verified
      (verify-signed-manifest (open-input-bytes (get-output-bytes signed))
                             pub #:key-id key-id))
    (define candidate
      (select-update
       (updater-config "dev.rivet.binding" "1.0.0" 'stable
                       (current-update-platform) 'x64 pub key-id 0 (* 1024 1024) #f)
       verified #:install-kind 'portable))
    (check-true (update-candidate? candidate))

    (for ([mode (in-list '(valid substituted grown))])
      (define target (build-path root (symbol->string mode) "installed"))
      (write-text (build-path target "version.txt") "old")
      (define downloaded (build-path root (format "downloaded-~a.zip" mode)))
      (copy-file trusted downloaded)
      (define restarted? #f)
      (define installation
        (prepare-platform-installation
         candidate downloaded #:target target
         #:restart (lambda () (set! restarted? #t) 'restarted)
         #:health-check (lambda () #t)
         ;; OS-publisher verification is a separate gate. The manifest-bound
         ;; content check must hold even with an explicit development verifier.
         #:verify-staged void))
      (case mode
        [(substituted) (copy-file altered downloaded #t)]
        [(grown)
         (call-with-output-file downloaded #:exists 'append
           (lambda (out) (write-byte 0 out)))])
      (if (eq? mode 'valid)
          (begin
            (check-equal? (execute-platform-installation! installation) 'restarted)
            (check-true restarted?)
            (check-equal? (file->string (build-path target "version.txt")) "aaaaaaa"))
          (begin
            (check-exn (if (eq? mode 'grown) #rx"size does not match" #rx"SHA-256 does not match")
                       (lambda () (execute-platform-installation! installation)))
            (check-false restarted?)
            (check-equal? (file->string (build-path target "version.txt")) "old")))
      (check-true (file-exists? downloaded))
      (check-false (directory-exists? (path-add-extension target ".rivet-backup")))
      (check-false (directory-exists? (path-add-extension target ".rivet-staging")))
      (check-false
       (for/or ([entry (in-list (directory-list (path-only target)))])
         (regexp-match? #rx"^\\.rivet-artifact-" (path->string entry)))))

    ;; A refusal to start a new transaction must not roll an unrelated old
    ;; backup over the current installation or overwrite its recovery journal.
    (define pending-target (build-path root "pending" "installed"))
    (define pending-backup (path-add-extension pending-target ".rivet-backup"))
    (define pending-journal (build-path root "pending" "transaction.json"))
    (write-text (build-path pending-target "version.txt") "current")
    (write-text (build-path pending-backup "version.txt") "prior")
    (write-text pending-journal "unrelated prior transaction")
    (define pending
      (prepare-platform-installation candidate trusted #:target pending-target
                                     #:restart (lambda () (error 'test "must not restart"))
                                     #:health-check (lambda () #t)
                                     #:verify-staged void))
    (check-exn #rx"unfinished installation"
               (lambda () (execute-platform-installation! pending #:journal-path pending-journal)))
    (check-equal? (file->string (build-path pending-target "version.txt")) "current")
    (check-true (file-exists? (build-path pending-backup "version.txt")))
    (check-equal? (file->string pending-journal) "unrelated prior transaction")
    (delete-directory/files pending-backup)
    (check-exn #rx"unfinished installation journal"
               (lambda () (execute-platform-installation! pending #:journal-path pending-journal)))
    (check-equal? (file->string (build-path pending-target "version.txt")) "current")
    (check-equal? (file->string pending-journal) "unrelated prior transaction"))
  (lambda () (delete-directory/files root)))
