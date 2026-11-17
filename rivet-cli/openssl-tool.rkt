#lang racket/base

;; Locate an OpenSSL 3 binary. macOS ships LibreSSL, which cannot parse or
;; generate Ed25519 keys, so `find-executable-path "openssl"` alone is not
;; enough. Products used to carry this search in every update-key script.

(require racket/list
         racket/path
         racket/port
         racket/string
         racket/system)

(provide openssl-3-executable)

(define (openssl-version-output executable)
  (define out (open-output-string))
  (define status
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-nowhere)])
      (system*/exit-code executable "version")))
  (and (zero? status) (get-output-string out)))

(define (openssl-3-executable)
  (define default (find-executable-path "openssl"))
  (define candidates
    (remove-duplicates
     (filter values
             (list (getenv "OPENSSL_BIN")
                   "/opt/homebrew/opt/openssl@3/bin/openssl"
                   "/usr/local/opt/openssl@3/bin/openssl"
                   (and default (path->string default))))))
  (for/first ([candidate (in-list candidates)]
              #:when (and (file-exists? candidate)
                          (let ([output (openssl-version-output candidate)])
                            (and output
                                 (string-contains? output "OpenSSL 3")))))
    (string->path candidate)))
