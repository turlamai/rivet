#lang racket/base

;; Publish-time tests exercise the signed wrapper and the *physical* bytes,
;; not merely an unsigned JSON fixture or filename heuristics.

(require crypto
         crypto/all
         rackunit
         racket/file
         racket/path
         "../distribution/crypto.rkt"
         "../distribution/manifest.rkt"
         "../../rivet-cli/verify-release-assets.rkt")

(use-all-factories!)

(define root (make-temporary-file "rivet-release-asset-gate-~a" 'directory))
(define assets (build-path root "assets"))
(make-directory assets)
(define asset (build-path assets "example-1.2.3-linux-x64.tar.gz"))
(call-with-output-file asset
  (lambda (out) (write-bytes (make-bytes 4096 42) out)))
(define key (generate-private-key 'eddsa '((curve ed25519))))
(define other-key (generate-private-key 'eddsa '((curve ed25519))))
(define pub-path (build-path root "pub.der"))
(call-with-output-file pub-path
  (lambda (out) (write-bytes (pk-key->datum key 'SubjectPublicKeyInfo) out)))
(define base "https://github.com/turlamai/example/releases/download/v1.2.3")
(define entry
  (update-artifact 'linux 'x64
                   (string-append base "/example-1.2.3-linux-x64.tar.gz")
                   (sha256-file/hex asset) (file-size asset)
                   'targz '() #f))
(define signed
  (update-manifest "site.jrtx.example" "1.2.3" 1 'stable
                   "2026-11-01T00:00:00Z" "0.0.0" #f #t 100
                   (list entry)))
(define feed (build-path root "update-manifest.json"))
(define (sign! manifest [secret key] [key-id "example-2026"])
  (call-with-output-file feed #:exists 'truncate/replace
    (lambda (out) (write-signed-manifest manifest secret key-id out))))
(define (check! [base-url base] #:targets [targets '()])
  (verify-release-assets! feed assets pub-path
                          #:base-url base-url
                          #:key-id "example-2026"
                          #:application-id "site.jrtx.example"
                          #:required-targets targets))

(sign! signed)
(check-equal? (update-manifest-version (check!)) "1.2.3")
(check-equal? (update-manifest-version
               (check! base #:targets '((linux x64 targz #f))))
              "1.2.3")
(check-exn #rx"required release target"
           (lambda () (check! base #:targets '((macos arm64 zip)))))
(check-exn #rx"signed asset URL is not in"
           (lambda () (check! "https://github.com/other/example/releases/download/v1.2.3")))
(check-exn #rx"immutable release tag"
           (lambda ()
             (check! "https://github.com/turlamai/example/releases/latest/download")))
;; Never authenticate a manifest that claims an installer kind incompatible
;; with the physical package's filename, even when its digest is correct.
(sign! (struct-copy update-manifest signed
                    [artifacts (list (struct-copy update-artifact entry
                                                  [installer 'msi]))]))
(check-exn #rx"does not match installer kind" (lambda () (check!)))
(sign! signed)
(check-exn #rx"application identity"
           (lambda ()
             (verify-release-assets! feed assets pub-path
                                     #:base-url base
                                     #:key-id "example-2026"
                                     #:application-id "site.jrtx.wrong")))
(check-exn #rx"unexpected key"
           (lambda ()
             (verify-release-assets! feed assets pub-path
                                     #:base-url base #:key-id "wrong-key")))

;; A forged manifest signed with another private key must fail before its
;; bytes are trusted, even when it claims the same key id.
(sign! signed other-key)
(check-exn #rx"signature verification failed" (lambda () (check!)))
(sign! signed)

;; Same byte length, different contents: the digest gate still catches it.
(call-with-output-file asset #:exists 'truncate/replace
  (lambda (out) (write-bytes (make-bytes 4096 43) out)))
(check-exn #rx"SHA-256 mismatch" (lambda () (check!)))
(call-with-output-file asset #:exists 'truncate/replace
  (lambda (out) (write-bytes (make-bytes 4096 42) out)))
(delete-file asset)
(check-exn #rx"release asset is missing" (lambda () (check!)))
(call-with-output-file asset
  (lambda (out) (write-bytes (make-bytes 4095 42) out)))
(check-exn #rx"size mismatch" (lambda () (check!)))
(call-with-output-file asset #:exists 'truncate/replace
  (lambda (out) (write-bytes (make-bytes 4096 42) out)))

;; A signed path still must not escape the release directory, even if the
;; signature was produced by a legitimate but misconfigured publisher.
(for ([url (in-list
            (list (string-append base "/../private.key")
                  (string-append base "/nested/asset.zip")
                  (string-append base "/asset.zip?download=1")))])
  (sign! (struct-copy update-manifest signed
                      [artifacts (list (struct-copy update-artifact entry
                                                    [url url]))]))
  (check-exn #rx"unsafe or ambiguous filename" (lambda () (check!))))
(sign! signed)

;; A CLI ZIP must not satisfy a required *app* ZIP target. The
;; component is part of the signed artifact identity.
(sign! (struct-copy update-manifest signed
                    [artifacts (list (struct-copy update-artifact entry
                                                  [component 'cli]))]))
(check-exn #rx"required release target"
           (lambda () (check! base #:targets '((linux x64 targz #f)))))
(check-equal? (update-manifest-version
               (check! base #:targets '((linux x64 targz cli))))
              "1.2.3")
(sign! signed)

(define args
  (parse-verify-release-assets-arguments
   (list "--manifest" (path->string feed)
         "--dir" (path->string assets)
         "--public-key" (path->string pub-path)
         "--base-url" base
         "--key-id" "example-2026"
         "--application-id" "site.jrtx.example"
         "--require" "linux:x64:targz")))
(check-equal? (hash-ref args 'required-targets) '((linux x64 targz #f)))
(check-exn #rx"required option is missing"
           (lambda () (parse-verify-release-assets-arguments '())))
(check-exn #rx"expects platform:arch:installer"
           (lambda ()
             (parse-verify-release-assets-arguments
              (list "--require" "bogus:arch:whatever"))))
(run-verify-release-assets-command
 (list "--manifest" (path->string feed)
       "--dir" (path->string assets)
       "--public-key" (path->string pub-path)
       "--base-url" base "--key-id" "example-2026"
       "--require" "linux:x64:targz"))

(delete-directory/files root)
