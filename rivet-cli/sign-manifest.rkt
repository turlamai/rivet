#lang racket/base

;; Builds the release update manifest from a dist directory, signs it with
;; the distribution signer, and refuses to publish anything unsigned or
;; unverified. Products keep only their asset-naming conventions: each
;; artifact is named explicitly on the command line, and the manifest URL is
;; the base URL joined with the file name.

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         "../rivet/distribution/crypto.rkt"
         "../rivet/distribution/identity.rkt"
         "../rivet/distribution/manifest.rkt"
         "artifact-file.rkt"
         "openssl-tool.rkt"
         "project.rkt")

(provide sign-manifest!
         parse-sign-manifest-arguments
         (struct-out requested-artifact))

(struct requested-artifact (platform architecture installer path component)
  #:transparent)

(define (parse-artifact-spec who spec)
  (define parts (string-split spec ":"))
  (unless (or (= (length parts) 4) (= (length parts) 5))
    (raise-arguments-error who
                           "--artifact expects <platform>:<arch>:<installer>:<file>[:<component>]"
                           "value" spec))
  (define platform (string->symbol (list-ref parts 0)))
  (define architecture (string->symbol (list-ref parts 1)))
  (define installer (string->symbol (list-ref parts 2)))
  (unless (memq platform '(windows macos linux))
    (raise-arguments-error who "artifact platform must be windows, macos, or linux"
                           "value" spec))
  (unless (memq architecture '(x64 arm64))
    (raise-arguments-error who "artifact architecture must be x64 or arm64"
                           "value" spec))
  (unless (feed-installer-symbol? installer)
    (raise-arguments-error
     who
     "artifact installer must be zip, targz, msi, deb, rpm, or appimage"
     "value" spec))
  (define component
    (and (= (length parts) 5)
         (let ([name (string->symbol (list-ref parts 4))])
           (unless (memq name '(app cli tool))
             (raise-arguments-error who
                                    "artifact component must be app, cli, or tool"
                                    "value" spec))
           name)))
  (requested-artifact platform architecture installer (list-ref parts 3)
                      component))

(define (parse-sign-manifest-arguments arguments)
  (let loop ([remaining arguments]
             [artifacts '()]
             [options (hasheq)])
    (define (with key tail value)
      (if (hash-has-key? options key)
          (raise-arguments-error 'sign-manifest
                                 (format "~a may be specified only once" key))
          (loop tail artifacts (hash-set options key value))))
    (match remaining
      ['()
       (values (reverse artifacts) options)]
      [(list* "--application-id" value tail) (with 'application-id tail value)]
      [(list* "--version" value tail) (with 'version tail value)]
      [(list* "--build" value tail)
       (define number (string->number value))
       (unless number
         (raise-arguments-error 'sign-manifest "--build requires an integer" "value" value))
       (loop tail artifacts (hash-set options 'build number))]
      [(list* "--channel" value tail)
       (unless (memq (string->symbol value) '(stable beta dev))
         (raise-arguments-error 'sign-manifest
                                "--channel must be stable, beta, or dev"
                                "value" value))
       (with 'channel tail (string->symbol value))]
      [(list* "--base-url" value tail)
       (unless (and (string? value) (regexp-match? #px"^https://" value))
         (raise-arguments-error 'sign-manifest
                                "--base-url must be an HTTPS URL"
                                "value" value))
       (with 'base-url tail value)]
      [(list* "--key-id" value tail) (with 'key-id tail value)]
      [(list* "--private-key" value tail) (with 'private-key tail value)]
      [(list* "--public-key" value tail) (with 'public-key tail value)]
      [(list* "--output" value tail) (with 'output tail value)]
      [(list* "--minimum-version" value tail) (with 'minimum-version tail value)]
      [(list* "--previous-version" value tail) (with 'previous-version tail value)]
      [(list* "--published-at" value tail) (with 'published-at tail value)]
      [(list* "--rollout" value tail)
       (define number (string->number value))
       (unless (and number (integer? number) (>= number 0) (<= number 100))
         (raise-arguments-error 'sign-manifest
                                "--rollout requires an integer between 0 and 100"
                                "value" value))
       (loop tail artifacts (hash-set options 'rollout number))]
      [(list* "--rollback-allowed" tail)
       (loop tail artifacts (hash-set options 'rollback-allowed? #t))]
      [(list* "--sidecars" tail)
       (loop tail artifacts (hash-set options 'sidecars? #t))]
      [(list* "--alias" value tail)
       ;; Byte-identical second feed name, for products that must keep a
       ;; pre-cutover the alias alive during a transition.
       (loop tail artifacts
             (hash-update options 'aliases (lambda (values) (cons value values)) '()))]
      [(list* "--artifact" spec tail)
       (loop tail (cons (parse-artifact-spec 'sign-manifest spec) artifacts) options)]
      [(cons argument _)
       (raise-arguments-error 'sign-manifest "unknown argument" "argument" argument)])))

(define (require-option who options key)
  (or (hash-ref options key #f)
      (raise-arguments-error who
                             (format "~a is required" key))))

(define (pem-private-key? path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (call-with-input-file path
      (lambda (in)
        (define line (read-line in 'any))
        (and (string? line) (string-prefix? line "-----BEGIN"))))))

;; The distribution signer reads DER (OneAsymmetricKey/PrivateKeyInfo). A
;; product that generates its key with `openssl genpkey` has PEM, so convert
;; once here instead of asking every wrapper to keep the same openssl dance.
(define (private-key-der-path who path)
  (cond
    [(not (pem-private-key? path)) path]
    [else
     (define openssl (openssl-3-executable))
     (unless openssl
       (raise-arguments-error
        who
        "a PEM private key needs OpenSSL 3 to convert to DER; pass a DER key or set OPENSSL_BIN"
        "key" path))
     (define output (make-temporary-file "rivet-sign-manifest-key-~a.der"))
     (define status
       (parameterize ([current-output-port (open-output-nowhere)]
                      [current-error-port (open-output-nowhere)])
         (system*/exit-code openssl "pkey" "-in" (path->string path)
                            "-outform" "DER" "-out" (path->string output))))
     (unless (zero? status)
       (when (file-exists? output) (delete-file output))
       (raise-arguments-error who
                              "OpenSSL could not convert the PEM private key to DER"
                              "key" path
                              "openssl" openssl))
     output]))

(define (join-url base-url file-name)
  (format "~a/~a"
          (string-trim base-url "/" #:right? #t)
          file-name))

(define (sign-manifest! artifacts options)
  ;; Identity fields default to the current project so a product wrapper
  ;; passes only its feed policy and artifact matrix. Explicit flags still
  ;; win (release aggregation and cross-project signing keep working).
  (define project (find-project))
  (define (option-or-project key accessor)
    (or (hash-ref options key #f)
        (and project (accessor project))
        (raise-arguments-error 'sign-manifest
                               (format "~a is required" key)
                               "project" (if project "found" "missing"))))
  (define application-id (option-or-project 'application-id project-identifier))
  (define version (option-or-project 'version project-version))
  (define build (option-or-project 'build project-build))
  (define channel (option-or-project 'channel project-release-channel))
  (define base-url (require-option 'sign-manifest options 'base-url))
  (define key-id (require-option 'sign-manifest options 'key-id))
  ;; One feed name across the release surface: `raco rivet release` writes
  ;; `dist/update-<channel>.json`, and a per-leg hand-signed manifest must use
  ;; the same name so the matrix compose step and product clients agree.
  (define output
    (string->path
     (or (hash-ref options 'output #f)
         (format "dist/update-~a.json" channel))))
  (when (null? artifacts)
    (raise-arguments-error 'sign-manifest
                           "at least one --artifact is required"))
  (define private-key-source
    (string->path
     (or (hash-ref options 'private-key #f)
         (getenv "RIVET_UPDATE_PRIVATE_KEY")
         (raise-arguments-error 'sign-manifest
                                "a private key is required: pass --private-key or set RIVET_UPDATE_PRIVATE_KEY"))))
  (define private-key-der (private-key-der-path 'sign-manifest private-key-source))
  (define private-key
    (if (eq? private-key-der private-key-source)
        (read-ed25519-private-key private-key-source)
        (dynamic-wind
         void
         (lambda () (read-ed25519-private-key private-key-der))
         (lambda ()
           (when (file-exists? private-key-der)
             (delete-file private-key-der))))))
  (define manifest
    (update-manifest
     application-id version build channel
     (or (hash-ref options 'published-at #f)
         (rfc3339-now))
     (hash-ref options 'minimum-version "0.0.0")
     (hash-ref options 'previous-version #f)
     (hash-ref options 'rollback-allowed? #f)
     (hash-ref options 'rollout 100)
     (for/list ([artifact (in-list artifacts)])
       (define path (string->path (requested-artifact-path artifact)))
       (unless (file-exists? path)
         (raise-arguments-error 'sign-manifest
                                "artifact file does not exist"
                                "file" path))
       (update-artifact
        (requested-artifact-platform artifact)
        (requested-artifact-architecture artifact)
        (join-url base-url (path->string (file-name-from-path path)))
        (sha256-file/hex path)
        (file-size path)
        (requested-artifact-installer artifact)
        '()
        (requested-artifact-component artifact)))))
  (make-parent-directory* output)
  (call-with-output-file output
    #:exists 'truncate/replace
    (lambda (out) (write-signed-manifest manifest private-key key-id out)))
  ;; Fail-closed publish: read the written file back and verify the exact
  ;; bytes with the public half when one is available. A failed verification
  ;; deletes the output so an unverified feed cannot be published by accident.
  (define public-key-path
    (or (hash-ref options 'public-key #f)
        (getenv "RIVET_UPDATE_PUBLIC_KEY")))
  (when public-key-path
    (with-handlers ([exn:fail?
                     (lambda (error)
                       (when (file-exists? output) (delete-file output))
                       (raise error))])
      (call-with-input-file output
        (lambda (in)
          (verify-signed-manifest in
                                  (read-ed25519-public-key public-key-path)
                                  #:key-id key-id)))))
  ;; Aliases are byte-identical feed names for a transition cutover. Write
  ;; them only after any public-key verification succeeded, so a bad feed
  ;; cannot survive under a second name.
  (for ([alias (in-list (reverse (hash-ref options 'aliases '())))])
    (define alias-path (string->path alias))
    (unless (equal? (path->complete-path alias-path)
                    (path->complete-path output))
      (make-parent-directory* alias-path)
      (copy-file output alias-path #t)))
  (when (hash-ref options 'sidecars? #f)
    (for ([artifact (in-list artifacts)])
      (write-sha256-sidecar! (string->path (requested-artifact-path artifact)))))
  output)
