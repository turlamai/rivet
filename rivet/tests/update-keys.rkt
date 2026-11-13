#lang racket/base

(require json
         net/base64
         rackunit
         racket/file
         racket/port
         racket/string
         "../../rivet/distribution/crypto.rkt"
         "../../rivet-cli/update-keys.rkt")

(define temp-root (make-temporary-file "rivet-update-keys-~a" 'directory))
(define key-path (build-path temp-root "update-signing-key.pem"))

(define (without-key-id-environment thunk)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"RIVET_UPDATE_KEY_ID" #f)
  (parameterize ([current-environment-variables env])
    (thunk)))

(dynamic-wind
 void
 (lambda ()
   (define json-text
     (with-output-to-string
       (lambda ()
         (run-update-keys-command
          (list "--key" (path->string key-path)
                "--key-id" "product-2026-11"
                "--json")))))
   (define report (string->jsexpr json-text))
   (check-equal? (hash-ref report 'key-id) "product-2026-11")
   (check-equal? (hash-ref report 'private-key) (path->string key-path))
   (check-true (file-exists? key-path))
   (check-true
    (string-prefix? (file->string key-path) "-----BEGIN PRIVATE KEY-----"))

   ;; The DER secret is exactly what the distribution signer reads.
   (define der
     (base64-decode
      (string->bytes/utf-8
       (hash-ref report 'private-key-der-base64))))
   (check-equal? (bytes-length der) 83)
   (define der-path (build-path temp-root "private.der"))
   (call-with-output-file der-path
     #:exists 'truncate/replace
     (lambda (out) (write-bytes der out)))
   (define private-key (read-ed25519-private-key der-path))
   (check-true (bytes? (ed25519-sign private-key #"probe")))

   ;; The pinned-key encodings: full SPKI DER and its raw 32-byte half.
   (define spki-hex (hash-ref report 'public-key-spki-hex))
   (define raw-hex (hash-ref report 'public-key-raw-hex))
   (check-equal? (string-length spki-hex) 88)
   (check-true (string-prefix? spki-hex "302a300506032b6570032100"))
   (check-equal? (string-length raw-hex) 64)
   (check-equal? (substring spki-hex 24) raw-hex)
   (check-equal?
    (bytes-length
     (base64-decode
      (string->bytes/utf-8 (hash-ref report 'public-key-spki-base64))))
    44)
   (check-equal?
    (bytes-length
     (base64-decode
      (string->bytes/utf-8 (hash-ref report 'public-key-raw-base64))))
    32)

   ;; The default path is a project-scoped home directory; the explicit path
   ;; above keeps this test hermetic. Replacing a key needs --force.
   (check-exn
    #rx"already exists"
    (lambda ()
      (without-key-id-environment
       (lambda ()
         (parameterize ([current-output-port (open-output-nowhere)])
           (run-update-keys-command
            (list "--key" (path->string key-path)
                  "--key-id" "product-2026-11")))))))
   (parameterize ([current-output-port (open-output-nowhere)])
     (run-update-keys-command
      (list "--key" (path->string key-path)
            "--key-id" "product-2026-12"
            "--force" "--json")))
   (check-true (file-exists? key-path))

   ;; The key id is a deliberate trust-root decision, not a generated value.
   (without-key-id-environment
    (lambda ()
      (check-exn
       #rx"key id is required"
       (lambda ()
         (parameterize ([current-output-port (open-output-nowhere)])
           (run-update-keys-command
            (list "--key" (path->string (build-path temp-root "other.pem")))))))))

   (check-exn #rx"unknown argument"
              (lambda ()
                (parse-update-keys-arguments (list "--bogus")))))
 (lambda ()
   (when (directory-exists? temp-root)
     (delete-directory/files temp-root))))
