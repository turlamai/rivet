#lang racket/base

;; Offline release gate for the exact files that are about to be published.
;; Authenticating a signed manifest is necessary but insufficient: a feed
;; may still point to a missing, renamed, or mutated installer. The caller
;; supplies the immutable release-tag URL and the directory of real assets.
;; No network access, update installation, or private signing key is needed.

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "../rivet/distribution/crypto.rkt"
         "../rivet/distribution/manifest.rkt")

(provide verify-release-assets!
         parse-verify-release-assets-arguments
         run-verify-release-assets-command)

(define (asset-name-for-url url base-url)
  (define prefix (string-append (string-trim base-url "/" #:right? #t) "/"))
  (unless (string-prefix? url prefix)
    (raise-arguments-error 'verify-release-assets!
                           "signed asset URL is not in the configured release"
                           "url" url "release base" base-url))
  (define name (substring url (string-length prefix)))
  ;; Only literal, single-segment release file names are accepted. Do not
  ;; decode URL escapes or let a signed path escape the local release dir.
  (unless (and (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._+-]*$" name)
               (not (member name '("." "..")))
               (not (string-contains? name "..")))
    (raise-arguments-error 'verify-release-assets!
                           "signed asset URL has an unsafe or ambiguous filename"
                           "url" url "filename" name))
  name)

(define (artifact-target artifact)
  (list (update-artifact-platform artifact)
        (update-artifact-architecture artifact)
        (update-artifact-installer artifact)))

(define (verify-release-assets! manifest-path release-dir public-key-path
                                #:base-url base-url
                                #:key-id key-id
                                #:application-id [application-id #f]
                                #:required-targets [required-targets '()])
  (unless (and (string? base-url)
               (regexp-match? #px"^https://[^/]+/.+" base-url)
               (not (regexp-match? #px"[?#]" base-url)))
    (raise-argument-error 'verify-release-assets!
                          "immutable HTTPS release base URL" base-url))
  (unless (directory-exists? release-dir)
    (raise-arguments-error 'verify-release-assets!
                           "release directory does not exist" "path" release-dir))
  ;; verify-signed-manifest authenticates the *bytes* before parsing payload.
  (define manifest
    (call-with-input-file manifest-path
      (lambda (in)
        (verify-signed-manifest in
                                (read-ed25519-public-key public-key-path)
                                #:key-id key-id))))
  (when (and application-id
             (not (equal? (update-manifest-application-id manifest)
                          application-id)))
    (raise-arguments-error 'verify-release-assets!
                           "signed application identity does not match"
                           "expected" application-id
                           "actual" (update-manifest-application-id manifest)))
  (define artifacts (update-manifest-artifacts manifest))
  (define names
    (for/list ([artifact (in-list artifacts)])
      (define name (asset-name-for-url (update-artifact-url artifact) base-url))
      (define local-path (build-path release-dir name))
      (unless (file-exists? local-path)
        (raise-arguments-error 'verify-release-assets!
                               "signed release asset is missing"
                               "asset" name "path" local-path))
      (unless (= (file-size local-path) (update-artifact-size artifact))
        (raise-arguments-error 'verify-release-assets!
                               "signed release asset size mismatch"
                               "asset" name
                               "expected" (update-artifact-size artifact)
                               "actual" (file-size local-path)))
      (define actual-hash (sha256-file/hex local-path))
      (unless (string-ci=? actual-hash (update-artifact-sha256 artifact))
        (raise-arguments-error 'verify-release-assets!
                               "signed release asset SHA-256 mismatch"
                               "asset" name
                               "expected" (update-artifact-sha256 artifact)
                               "actual" actual-hash))
      name))
  ;; One physical file cannot stand in for distinct installer identities.
  (define duplicate (check-duplicates names))
  (when duplicate
    (raise-arguments-error 'verify-release-assets!
                           "multiple signed artifact identities point to the same file"
                           "asset" duplicate))
  (define available-targets (map artifact-target artifacts))
  (for ([target (in-list required-targets)])
    (unless (member target available-targets equal?)
      (raise-arguments-error 'verify-release-assets!
                             "required release target is missing from signed manifest"
                             "target" target
                             "available targets" available-targets)))
  manifest)

(define (parse-target value)
  (define parts (map string->symbol (string-split value ":")))
  (unless (and (= (length parts) 3)
               (memq (first parts) '(windows macos linux))
               (memq (second parts) '(x64 arm64))
               (memq (third parts) '(zip msi deb rpm appimage targz)))
    (raise-arguments-error 'verify-release-assets
                           "--require expects platform:arch:installer"
                           "value" value))
  parts)

(define (parse-verify-release-assets-arguments arguments)
  (let loop ([remaining arguments] [options (hasheq)]
             [required-targets '()])
    (match remaining
      ['()
       (for ([key (in-list '(manifest dir public-key base-url key-id))])
         (unless (hash-has-key? options key)
           (raise-arguments-error 'verify-release-assets
                                  "required option is missing" "option" key)))
       (hash-set options 'required-targets (reverse required-targets))]
      [(list* "--require" target tail)
       (loop tail options (cons (parse-target target) required-targets))]
      [(list* (and option (or "--manifest" "--dir" "--public-key"
                              "--base-url" "--key-id" "--application-id"))
              value tail)
       (define key (string->symbol (substring option 2)))
       (when (hash-has-key? options key)
         (raise-arguments-error 'verify-release-assets
                                "option may only occur once" "option" option))
       (loop tail (hash-set options key value) required-targets)]
      [(cons option _)
       (raise-arguments-error 'verify-release-assets
                              "unknown or incomplete option" "option" option)])))

(define (run-verify-release-assets-command arguments)
  (define options (parse-verify-release-assets-arguments arguments))
  (define manifest
    (verify-release-assets!
     (hash-ref options 'manifest)
     (hash-ref options 'dir)
     (hash-ref options 'public-key)
     #:base-url (hash-ref options 'base-url)
     #:key-id (hash-ref options 'key-id)
     #:application-id (hash-ref options 'application-id #f)
     #:required-targets (hash-ref options 'required-targets)))
  (printf "verified ~a signed update assets for ~a ~a\n"
          (length (update-manifest-artifacts manifest))
          (update-manifest-application-id manifest)
          (update-manifest-version manifest))
  (void))
