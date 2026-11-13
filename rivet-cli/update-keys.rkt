#lang racket/base

;; Generate the Ed25519 update-signing keypair in the shape the family
;; verifiers consume. Every product used to carry this in its own shell
;; script; the drift produced a stale key location and a base64/hex mismatch
;; in movebit (rivet #453). One command now owns key generation and the two
;; output encodings products embed.

(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         json
         net/base64
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         "openssl-tool.rkt"
         "project.rkt")

(provide parse-update-keys-arguments
         run-update-keys-command)

(define default-key-id-env "RIVET_UPDATE_KEY_ID")

(define (parse-update-keys-arguments arguments)
  (let loop ([remaining arguments]
             [options (hasheq)])
    (define (with key tail value)
      (if (hash-has-key? options key)
          (raise-arguments-error 'update-keys
                                 (format "~a may be specified only once" key))
          (loop tail (hash-set options key value))))
    (match remaining
      ['() options]
      [(list* "--key" value tail) (with 'key tail value)]
      [(list* "--key-id" value tail) (with 'key-id tail value)]
      [(list* "--force" tail) (loop tail (hash-set options 'force? #t))]
      [(list* "--json" tail) (loop tail (hash-set options 'json? #t))]
      [(cons argument _)
       (raise-arguments-error 'update-keys "unknown argument"
                              "argument" argument)])))

(define (default-key-path project)
  (build-path (find-system-path 'home-dir)
              (if project
                  (string-append "." (project-name project))
                  ".rivet")
              "update-signing-key.pem"))

;; Generate through libcrypto only: its PKCS#8 encoding is the one OpenSSL
;; (and therefore the PEM path in `sign-manifest`) reads back. Sodium and
;; decaf can sign and verify, but their private-key datum is not guaranteed
;; to be OpenSSL-compatible; the OpenSSL 3 fallback below writes the
;; standard encoding instead.
(define (native-ed25519-key)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define implementation (get-pk 'eddsa libcrypto-factory))
    (and implementation
         (generate-private-key implementation '((curve ed25519))))))

(define (pem-bytes der)
  (define encoded (bytes->string/utf-8 (base64-encode der #"")))
  (string-append
   "-----BEGIN PRIVATE KEY-----\n"
   (string-join
    (for/list ([offset (in-range 0 (string-length encoded) 64)])
      (substring encoded offset
                 (min (string-length encoded) (+ offset 64))))
    "\n")
   "\n-----END PRIVATE KEY-----\n"))

(define (write-private-key! path der force?)
  (make-parent-directory* path)
  (call-with-output-file path
    #:exists (if force? 'truncate/replace 'error)
    (lambda (out) (display (pem-bytes der) out)))
  (unless (eq? (system-type 'os) 'windows)
    (file-or-directory-permissions path #o600))
  path)

(define (openssl-generate! openssl path)
  (define status
    (parameterize ([current-output-port (open-output-nowhere)]
                   [current-error-port (open-output-nowhere)])
      (system*/exit-code openssl "genpkey" "-algorithm" "ed25519"
                         "-out" (path->string path))))
  (unless (zero? status)
    (raise-arguments-error 'update-keys
                           "OpenSSL could not generate an Ed25519 key"
                           "key" path
                           "openssl" openssl))
  (define der-temp (make-temporary-file "rivet-update-key-~a.der"))
  (define spki-temp (make-temporary-file "rivet-update-key-spki-~a.der"))
  (dynamic-wind
   void
   (lambda ()
     (for ([arguments (in-list
                       (list (list "pkey" "-in" (path->string path)
                                   "-outform" "DER" "-out" (path->string der-temp))
                             (list "pkey" "-in" (path->string path) "-pubout"
                                   "-outform" "DER" "-out" (path->string spki-temp))))])
       (define converted
         (parameterize ([current-output-port (open-output-nowhere)]
                        [current-error-port (open-output-nowhere)])
           (apply system*/exit-code openssl arguments)))
       (unless (zero? converted)
         (raise-arguments-error 'update-keys
                                "OpenSSL could not export the generated key"
                                "key" path
                                "openssl" openssl)))
     (values (file->bytes der-temp) (file->bytes spki-temp)))
   (lambda ()
     (for ([temporary (in-list (list der-temp spki-temp))])
       (when (file-exists? temporary) (delete-file temporary))))))

(define (hex-string value)
  (string-join
   (for/list ([byte (in-bytes value)])
     (if (< byte 16)
         (string-append "0" (format "~x" byte))
         (format "~x" byte)))
   ""))

(define (run-update-keys-command arguments)
  (define options (parse-update-keys-arguments arguments))
  (define project (find-project))
  (define key-path
    (string->path (or (hash-ref options 'key #f) (default-key-path project))))
  (define key-id
    (or (hash-ref options 'key-id #f)
        (getenv default-key-id-env)
        (raise-arguments-error
         'update-keys
         "a key id is required: pass --key-id or set RIVET_UPDATE_KEY_ID"
         "convention" "<product>-<year>-<month>")))
  (define force? (hash-ref options 'force? #f))
  (when (and (file-exists? key-path) (not force?))
    (raise-arguments-error
     'update-keys
     "the private key already exists; delete it or pass --force to replace it"
     "key" key-path))
  ;; Prefer OpenSSL 3 for generation: its PKCS#8 PEM is the encoding every
  ;; product verifier and `sign-manifest` read back. Racket keygen remains
  ;; the fallback for hosts without an OpenSSL 3 binary.
  (define openssl (openssl-3-executable))
  (define-values (der spki)
    (cond
      [openssl
       (define-values (der spki)
         (openssl-generate! openssl key-path))
       (unless (eq? (system-type 'os) 'windows)
         (file-or-directory-permissions key-path #o600))
       (values der spki)]
      [else
       (define key (native-ed25519-key))
       (unless key
         (raise-arguments-error
          'update-keys
          "no Ed25519 provider is available: install OpenSSL 3 or set OPENSSL_BIN"))
       (define der (pk-key->datum key 'PrivateKeyInfo))
       (write-private-key! key-path der force?)
       (values der (pk-key->datum key 'SubjectPublicKeyInfo))]))
  (define raw-key
    (subbytes spki (- (bytes-length spki) 32)))
  (define der-base64 (bytes->string/utf-8 (base64-encode der #"")))
  (define spki-base64 (bytes->string/utf-8 (base64-encode spki #"")))
  (define raw-base64 (bytes->string/utf-8 (base64-encode raw-key #"")))
  (define spki-hex (hex-string spki))
  (define raw-hex (hex-string raw-key))
  (if (hash-ref options 'json? #f)
      (write-json
       (hasheq 'private-key (path->string key-path)
               'key-id key-id
               'private-key-der-base64 der-base64
               'public-key-spki-hex spki-hex
               'public-key-raw-hex raw-hex
               'public-key-raw-base64 raw-base64
               'public-key-spki-base64 spki-base64)
       (current-output-port))
      (begin
        (printf "Private key: ~a  (0600; back this up)\n" key-path)
        (printf "key-id: ~a\n" key-id)
        (printf "GitHub secret (DER base64, e.g. UPDATE_ED25519_PRIVATE_KEY_B64):\n")
        (printf "  ~a\n" der-base64)
        (printf "Public key SPKI hex:\n  ~a\n" spki-hex)
        (printf "Public key SPKI base64:\n  ~a\n" spki-base64)
        (printf "Public key raw 32-byte base64 (for native verifiers that embed base64):\n")
        (printf "  ~a\n" raw-base64)
        (printf "Update module (replace the pinned key with these two literals):\n")
        (printf "  \"302a300506032b6570032100\"\n")
        (printf "  \"~a\"\n" raw-hex)))
  (newline (current-output-port))
  key-path)
