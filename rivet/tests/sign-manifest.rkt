#lang racket/base

;; Sign-manifest CLI end to end: keygen, sign from named artifacts, verify
;; with the public half, sidecar emission, and the fail-closed publish that
;; deletes the output when verification fails.

(require rackunit
         racket/file
         racket/path
         racket/system
         crypto
         crypto/all
         "../../rivet/distribution/crypto.rkt"
         "../../rivet/distribution/manifest.rkt"
         "../../rivet-cli/openssl-tool.rkt"
         "../../rivet-cli/sign-manifest.rkt")

(use-all-factories!)

(define ed25519-impl
  (get-pk 'eddsa (list libcrypto-factory sodium-factory decaf-factory)))
(define private-key
  (and ed25519-impl
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (generate-private-key ed25519-impl '((curve ed25519))))))

(unless private-key
  (displayln
   "rivet-sign-manifest-tests: skipping; no compatible Ed25519 provider")
  (exit 0))

(define root (make-temporary-file "rivet-sign-manifest-~a" 'directory))
(define private-key-path (build-path root "private.der"))
(define public-key-path (build-path root "public.der"))
(call-with-output-file private-key-path
  #:exists 'truncate/replace
  (lambda (out) (write-bytes (pk-key->datum private-key 'PrivateKeyInfo) out)))
(call-with-output-file public-key-path
  #:exists 'truncate/replace
  (lambda (out)
    (write-bytes (pk-key->datum private-key 'SubjectPublicKeyInfo) out)))

;; --- argument parsing ------------------------------------------------------

(define-values (parsed-artifacts parsed-options)
  (parse-sign-manifest-arguments
   (list "--application-id" "dev.example"
         "--version" "1.2.3" "--build" "7" "--channel" "stable"
         "--base-url" "https://dl.example/app/"
         "--key-id" "release-2026"
         "--artifact" "macos:arm64:zip:App-1.2.3.zip")))
(check-equal? (length parsed-artifacts) 1)
(check-equal? (hash-ref parsed-options 'application-id) "dev.example")
(check-equal? (hash-ref parsed-options 'build) 7)
(check-equal? (hash-ref parsed-options 'channel) 'stable)

(define-values (targz-artifacts _targz-options)
  (parse-sign-manifest-arguments
   (list "--application-id" "dev.example"
         "--version" "1.2.3" "--build" "7" "--channel" "stable"
         "--base-url" "https://dl.example/app/"
         "--key-id" "release-2026"
         "--artifact" "linux:x64:targz:App-1.2.3-linux-x64.tar.gz")))
(check-equal? (requested-artifact-installer (car targz-artifacts)) 'targz)
(check-exn #rx"--artifact expects"
           (lambda () (parse-sign-manifest-arguments (list "--artifact" "macos:arm64:zip"))))
(check-exn #rx"artifact installer must be"
           (lambda () (parse-sign-manifest-arguments (list "--artifact" "macos:arm64:exe:App.zip"))))

;; A feed may carry several installables per platform; the trailing
;; component discriminator selects the CLI/tool artifact (issue #271).
(define-values (component-artifacts _component-options)
  (parse-sign-manifest-arguments
   (list "--artifact" "linux:x64:targz:App-cli.tar.gz:cli")))
(check-equal? (requested-artifact-component (car component-artifacts)) 'cli)
(check-exn #rx"artifact component must be"
           (lambda ()
             (parse-sign-manifest-arguments
              (list "--artifact" "linux:x64:zip:App.zip:docs"))))
(check-false (requested-artifact-component (car targz-artifacts)))
(check-exn #rx"--base-url must be an HTTPS URL"
           (lambda () (parse-sign-manifest-arguments (list "--base-url" "http://dl.example/"))))
(check-exn #rx"unknown argument"
           (lambda () (parse-sign-manifest-arguments (list "--bogus"))))
(check-exn #rx"at least one --artifact"
           (lambda ()
             (sign-manifest! '()
                             (hasheq 'application-id "d" 'version "1" 'build 1
                                     'channel 'stable 'base-url "https://x/"
                                     'key-id "k" 'private-key (path->string private-key-path)))))

;; --- signing end to end ----------------------------------------------------

(define artifact (build-path root "App-1.2.3-macos-arm64.zip"))
(call-with-output-file artifact
  #:exists 'truncate/replace
  (lambda (out) (write-bytes (make-bytes 2048 7) out)))

(define stable-alias (build-path root "update-stable.json"))
(define output
  (sign-manifest!
   (list (requested-artifact 'macos 'arm64 'zip (path->string artifact) #f))
   (hasheq 'application-id "dev.example"
           'version "1.2.3"
           'build 7
           'channel 'stable
           'base-url "https://dl.example/app/"
           'key-id "release-2026"
           'private-key (path->string private-key-path)
           'public-key (path->string public-key-path)
           'output (path->string (build-path root "update.json"))
           'aliases (list (path->string stable-alias))
           'sidecars? #t
           'published-at "2026-10-16T00:00:00Z")))
(check-true (file-exists? output))
;; A transition alias is a byte-identical second feed name.
(check-true (file-exists? stable-alias))
(check-equal? (file->bytes stable-alias) (file->bytes output))

;; Without --output the feed follows the channel, matching `raco rivet release`
;; (`dist/update-<channel>.json`) so per-leg manifests compose by one name.
(define default-root (make-temporary-file "rivet-sign-default-~a" 'directory))
(define default-output
  (parameterize ([current-directory default-root])
    (sign-manifest!
     (list (requested-artifact 'macos 'arm64 'zip (path->string artifact) #f))
     (hasheq 'application-id "dev.example"
             'version "1.2.3"
             'build 7
             'channel 'beta
             'base-url "https://dl.example/app/"
             'key-id "release-2026"
             'private-key (path->string private-key-path)
             'public-key (path->string public-key-path)
             'published-at "2026-10-16T00:00:00Z"))))
(check-equal? (path->string default-output) "dist/update-beta.json")
(check-true (file-exists? (build-path default-root "dist" "update-beta.json")))

;; Identity defaults to the current project, so a product wrapper passes only
;; its feed policy and artifact matrix.
(define defaults-root (make-temporary-file "rivet-sign-project-~a" 'directory))
(call-with-output-file (build-path defaults-root "rivet.rktd")
  #:exists 'truncate/replace
  (lambda (out)
    (write (hasheq 'name "demo"
                   'version "9.9.9"
                   'build 42
                   'identifier "dev.example.defaults"
                   'backend "app/backend.rkt"
                   'module "backend"
                   'entry "start"
                   'protocol 1)
           out)))
(define defaults-output
  (parameterize ([current-directory defaults-root])
    (sign-manifest!
     (list (requested-artifact 'macos 'arm64 'zip (path->string artifact) #f))
     (hasheq 'base-url "https://dl.example/app/"
             'key-id "release-2026"
             'private-key (path->string private-key-path)
             'public-key (path->string public-key-path)
             'output (path->string (build-path defaults-root "update.json"))
             'published-at "2026-10-16T00:00:00Z"))))
(define defaults-manifest
  (call-with-input-file defaults-output
    (lambda (in)
      (verify-signed-manifest in (read-ed25519-public-key public-key-path)))))
(check-equal? (update-manifest-application-id defaults-manifest)
              "dev.example.defaults")
(check-equal? (update-manifest-version defaults-manifest) "9.9.9")
(check-equal? (update-manifest-build defaults-manifest) 42)
(check-equal? (update-manifest-channel defaults-manifest) 'stable)

;; The published feed verifies with the public half and carries the exact
;; artifact facts.
(define manifest
  (call-with-input-file output
    (lambda (in) (verify-signed-manifest in (read-ed25519-public-key public-key-path)))))
(check-equal? (update-manifest-application-id manifest) "dev.example")
(check-equal? (length (update-manifest-artifacts manifest)) 1)
(define entry (car (update-manifest-artifacts manifest)))
(check-equal? (update-artifact-url entry)
              (format "https://dl.example/app/~a"
                      (path->string (file-name-from-path artifact))))
(check-equal? (update-artifact-size entry) 2048)
(check-equal? (update-artifact-sha256 entry) (sha256-file/hex artifact))

;; Sidecars are appended (`<artifact>.sha256`), matching release and the
;; documented download-page convention, not path-add-extension's `_zip` form.
(define sidecar (string->path (string-append (path->string artifact) ".sha256")))
(check-true (file-exists? sidecar))
(check-false
 (file-exists? (path-add-extension artifact #".sha256")))
(check-regexp-match
 #px"^[0-9a-f]{64}  App-1\\.2\\.3-macos-arm64\\.zip"
 (file->string sidecar))

;; A PEM private key is converted once by the command, so a product wrapper
;; does not need its own openssl conversion step.
(define openssl (openssl-3-executable))
(when openssl
  (define pem-key (build-path root "private.pem"))
  (check-equal?
   (system*/exit-code openssl "pkey"
                     "-inform" "DER" "-in" (path->string private-key-path)
                     "-outform" "PEM" "-out" (path->string pem-key))
   0)
  (define pem-output (build-path root "pem-update.json"))
  (sign-manifest!
   (list (requested-artifact 'macos 'arm64 'zip (path->string artifact) #f))
   (hasheq 'application-id "dev.example"
           'version "1.2.3"
           'build 7
           'channel 'stable
           'base-url "https://dl.example/app/"
           'key-id "release-2026"
           'private-key (path->string pem-key)
           'public-key (path->string public-key-path)
           'output (path->string pem-output)
           'published-at "2026-10-16T00:00:00Z"))
  (define pem-manifest
    (call-with-input-file pem-output
      (lambda (in)
        (verify-signed-manifest in (read-ed25519-public-key public-key-path)))))
  (check-equal? (update-manifest-version pem-manifest) "1.2.3"))

;; --- fail-closed publish ---------------------------------------------------

;; A wrong public key deletes the output instead of leaving an unverified
;; feed on disk.
(define wrong-public (build-path root "wrong.der"))
(call-with-output-file wrong-public
  #:exists 'truncate/replace
  (lambda (out) (write-bytes (make-bytes 44 3) out)))
(define other-artifact (build-path root "Other-1.0.0-linux-x64.zip"))
(call-with-output-file other-artifact
  #:exists 'truncate/replace
  (lambda (out) (write-bytes (make-bytes 128 9) out)))
(define other-output (build-path root "other-update.json"))
(check-exn #rx"verification failed|unexpected key|malformed|could not decode"
           (lambda ()
             (sign-manifest!
              (list (requested-artifact 'linux 'x64 'zip (path->string other-artifact) #f))
              (hasheq 'application-id "dev.example"
                      'version "1.0.0"
                      'build 1
                      'channel 'stable
                      'base-url "https://dl.example/other/"
                      'key-id "release-2026"
                      'private-key (path->string private-key-path)
                      'public-key (path->string wrong-public)
                      'output (path->string other-output)))))
(check-false (file-exists? other-output))

;; --- key-rotation dual-trust window (issue #370) ---------------------------

;; A second keypair plays the "next" release key. During the window the
;; client still primary-trusts the old key id and additionally trusts the
;; next key id, each wrapper verified against its own paired public key.
(define next-private-key
  (generate-private-key ed25519-impl '((curve ed25519))))
(define next-public-key-path (build-path root "next-public.der"))
(call-with-output-file next-public-key-path
  #:exists 'truncate/replace
  (lambda (out)
    (write-bytes (pk-key->datum next-private-key 'SubjectPublicKeyInfo) out)))

(define rotation-output (build-path root "rotation-update.json"))
(call-with-output-file rotation-output
  #:exists 'truncate/replace
  (lambda (out)
    (write-signed-manifest manifest next-private-key "release-2027" out)))

;; Without the dual-trust window the next-key feed is rejected outright.
(check-exn #rx"unexpected key"
           (lambda ()
             (call-with-input-file rotation-output
               (lambda (in)
                 (verify-signed-manifest
                  in (read-ed25519-public-key public-key-path)
                  #:key-id "release-2026")))))

;; Inside the window it verifies against the next key's own public half.
(define rotation-manifest
  (call-with-input-file rotation-output
    (lambda (in)
      (verify-signed-manifest
       in (read-ed25519-public-key public-key-path)
       #:key-id "release-2026"
       #:trusted-keys
       (list (cons "release-2027"
                   (read-ed25519-public-key next-public-key-path)))))))
(check-equal? (update-manifest-application-id rotation-manifest)
              (update-manifest-application-id manifest))

;; A trusted id whose signature does not verify under its paired key fails
;; closed instead of falling back to the primary key.
(check-exn #rx"verification failed"
           (lambda ()
             (call-with-input-file rotation-output
               (lambda (in)
                 (verify-signed-manifest
                  in (read-ed25519-public-key public-key-path)
                  #:key-id "release-2026"
                  #:trusted-keys
                  (list (cons "release-2027"
                              (read-ed25519-public-key public-key-path))))))))

(delete-directory/files root)
(when (directory-exists? defaults-root) (delete-directory/files defaults-root))
