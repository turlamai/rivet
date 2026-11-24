#lang racket/base

(require crypto
         (only-in racket/base [sha256-bytes racket-sha256-bytes])
         (only-in crypto/libcrypto libcrypto-factory)
         (rename-in "crypto-pure.rkt"
                     [generate-private-key pure-generate-private-key]
                     [public-key pure-public-key]
                     [private-key->der pure-private-key->der]
                     [public-key->der pure-public-key->der])
         net/base64
         racket/file
         racket/list
         racket/match
         racket/port
         racket/string)

(provide sha256-bytes
         sha256-file
         sha256-file/hex
         read-ed25519-public-key
         read-ed25519-private-key
         bytes->ed25519-public-key
         ed25519-sign
         ed25519-verify
         bytes->base64-string
         base64-string->bytes)

;; crypto-lib chooses the best available audited provider (OpenSSL, Nettle,
;; libsodium, or Decaf). The manifest pins the algorithm to Ed25519, so a
;; provider that lacks it fails closed instead of falling back to another
;; signature scheme.
;;
;; Rivet's manifest crypto is SHA-256 and Ed25519. The normal runtime
;; provider is libcrypto (OpenSSL 3); a lazy Nettle Ed25519 fallback is used
;; only when that implementation is unavailable on minimal package builders.
;; Requiring crypto/all (or instantiating every factory) would drag in
;; factory modules whose FFI loads run at module-import time — the gmp
;; factory kills the process there on hosts without libgmp, and every
;; embedded app that merely verifies a manifest shipped that landmine
;; (found by packaging a real app for macOS, where the CI-built bundle
;; would not start).
(crypto-factories (list libcrypto-factory))

;; Keep native provider imports lazy. Full desktop distributions already ship
;; OpenSSL 3; importing additional FFI providers during app startup can break
;; otherwise self-contained packaged applications. Reading the
;; `(crypto-factories)` parameter is safe — it never loads a factory module —
;; so an embedder that configured a wider set (the release tooling's
;; `use-all-factories!`, or a host application with its own provider choice)
;; keeps working even when this module's own defaults cannot serve Ed25519.
(define (nettle-candidate)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (dynamic-require 'crypto/nettle 'nettle-factory)))

;; Advertising an EdDSA implementation is not proof that the library behind
;; it can sign with Ed25519: the package builder's libgcrypt accepts the
;; `eddsa` lookup and the key generation, then fails `pk-sign` with "Invalid
;; object". Each factory therefore proves itself once with a fresh key and a
;; sign/verify round trip; a factory that fails any step is treated as absent
;; and the pure backend takes over.
(define proven-factories (make-hash))

(define probe-message #"rivet-ed25519-provider-probe")

(define (proven-ed25519-factory? factory)
  (hash-ref! proven-factories
             factory
             (lambda ()
               (with-handlers ([exn:fail? (lambda (_) #f)])
                 (define implementation (get-pk 'eddsa factory))
                 (define key
                   (generate-private-key implementation '((curve ed25519))))
                 (define public
                   (datum->pk-key (pk-key->datum key 'rkt-public)
                                  'rkt-public
                                  (list factory)))
                 (define signature (pk-sign key probe-message))
                 (and (= 64 (bytes-length signature))
                      (pk-verify public probe-message signature))))))

;; Every native factory that can sign and verify Ed25519 right now, empty
;; when none can. The official Racket 9.3 package builder carries an OpenSSL
;; that predates Ed25519, a libgcrypt that cannot sign with it and no
;; libnettle, so an empty result is a supported runtime state, not an error:
;; decode/sign/verify then route through the pure RFC 8032 backend in
;; crypto-pure.rkt. There is no alternative signature algorithm and no mock.
(define (native-ed25519-factories)
  (remove-duplicates
   (for/list ([factory (in-list (append (crypto-factories)
                                        (list libcrypto-factory)
                                        (list (nettle-candidate))))]
              #:when (and factory
                          (get-pk 'eddsa factory)
                          (proven-ed25519-factory? factory)))
     factory)))

;; A native key object whose own factory failed the probe still carries the
;; standard 32-byte halves in its `rkt-*` datum. Reuse them through the pure
;; backend so a caller that generated the key through `crypto` (as the
;; all-factories tests do) is not stuck with an object nobody can use.
(define (ed25519-half? value)
  (and (bytes? value) (= 32 (bytes-length value))))

(define (pure-from-native key private?)
  (and (available?)
       (let ([datum (with-handlers ([exn:fail? (lambda (_) #f)])
                      (pk-key->datum key (if private? 'rkt-private 'rkt-public)))])
         (match datum
           [(list 'eddsa (? symbol? kind) 'ed25519
                  (? ed25519-half? public) (? ed25519-half? secret))
            (and (eq? kind 'private) (pure-ed25519-key 'private secret))]
           [(list 'eddsa 'public 'ed25519 (? ed25519-half? public))
            (pure-ed25519-key 'public public)]
           [_ #f]))))

(define (no-native-provider who key)
  (raise-arguments-error
   who
   "no native provider can use the Ed25519 key and the pure backend is unavailable"
   "key" key
   "factories configured" (crypto-factories)))

(define (bytes->base64-string value)
  (bytes->string/utf-8 (base64-encode value #"")))

(define (base64-string->bytes value)
  (unless (string? value)
    (raise-argument-error 'base64-string->bytes "string?" value))
  (with-handlers ([exn:fail?
                   (lambda (_)
                     (raise-arguments-error 'base64-string->bytes
                                            "invalid base64 value"
                                            "value" value))])
    (base64-decode (string->bytes/utf-8 value))))

;; SHA-256 is implemented by Racket's core library and must not depend on
;; native crypto providers. This matters on the official package builder,
;; which may compile Rivet without a usable OpenSSL 3 Ed25519 provider.
;; Ed25519 signing/verification still fails closed when its native provider
;; cannot be loaded; the hashing fallback does not change that policy.
(define (sha256-bytes input)
  (racket-sha256-bytes input))

(define (sha256-file path)
  (call-with-input-file path racket-sha256-bytes #:mode 'binary))

(define (sha256-file/hex path)
  (bytes->hex-string (sha256-file path)))

(define (decode-key who raw formats #:origin [origin #f])
  (define factories (native-ed25519-factories))
  (or (and (pair? factories)
           (for/or ([format (in-list formats)])
             (with-handlers ([exn:fail? (lambda (_) #f)])
               (datum->pk-key raw format factories))))
      ;; No native factory serves Ed25519 here; the DER and OpenSSH shapes
      ;; still decode through the pure backend. The rkt-* datum formats are
      ;; native-only by construction (they are produced by a native key
      ;; object) and correctly fail closed without one.
      (pure-decode who raw formats)
      (apply raise-arguments-error who
             "could not decode Ed25519 key"
             (append (list "accepted formats" formats)
                     (if origin (list "path" origin) (list))))))

;; Route a decode request to the pure backend when the requested formats
;; include one it understands. Returns #f for native-only formats and for
;; bytes the pure backend rejects, so the caller always raises the shared
;; "could not decode" error — with the path origin — instead of a backend
;; internal one.
(define (pure-decode who raw formats)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and (pure-available-for? formats)
         (if (for/or ([format (in-list formats)])
               (memq format '(OneAsymmetricKey PrivateKeyInfo rkt-private)))
             (decode-private-bytes who raw)
             (decode-public-bytes who raw)))))

(define (pure-available-for? formats)
  (and (available?)
       (for/or ([format (in-list formats)])
         (memq format '(SubjectPublicKeyInfo openssh-public
                        OneAsymmetricKey PrivateKeyInfo)))))

(define (read-key who path formats)
  (decode-key who (file->bytes path) formats #:origin path))

(define (ensure-ed25519 who key private?)
  (cond
    [(pure-ed25519-key? key)
     (unless (eq? (pure-ed25519-key-kind key) (if private? 'private 'public))
       (raise-arguments-error who
         "key kind does not match the requested operation"
         "expected" (if private? 'private 'public)
         "key kind" (pure-ed25519-key-kind key)))]
    [else
     (unless (pk-key? key)
       (raise-argument-error who "pk-key?" key))
     (define datum (pk-key->datum key (if private? 'rkt-private 'rkt-public)))
     (unless (and (list? datum)
                  (pair? datum)
                  (eq? (car datum) 'eddsa)
                  (member 'ed25519 datum))
       (raise-arguments-error who "key is not Ed25519" "key" key))])
  key)

(define (read-ed25519-public-key path)
  (ensure-ed25519
   'read-ed25519-public-key
   (read-key 'read-ed25519-public-key path
             '(SubjectPublicKeyInfo rkt-public openssh-public))
   #f))

;; Release builds embed the channel's public key as DER hex in app source
;; (the runbook pattern: the private half never lives in a checkout), so
;; the parsed key must be reachable from bytes and not only from a file.
(define (bytes->ed25519-public-key raw)
  (ensure-ed25519
   'bytes->ed25519-public-key
   (decode-key 'bytes->ed25519-public-key raw
               '(SubjectPublicKeyInfo rkt-public openssh-public))
   #f))

(define (read-ed25519-private-key path)
  (ensure-ed25519
   'read-ed25519-private-key
   (read-key 'read-ed25519-private-key path
             '(OneAsymmetricKey PrivateKeyInfo rkt-private))
   #t))

(define (ed25519-sign private-key message)
  (define checked (ensure-ed25519 'ed25519-sign private-key #t))
  (define factories (native-ed25519-factories))
  (cond
    [(pure-ed25519-key? checked) (sign checked message)]
    [(pair? factories)
     (pk-sign (datum->pk-key (pk-key->datum checked 'rkt-private)
                             'rkt-private
                             factories)
              message)]
    [(pure-from-native checked #t) => (lambda (key) (sign key message))]
    [else (no-native-provider 'ed25519-sign checked)]))

(define (ed25519-verify public-key message signature)
  (define checked (ensure-ed25519 'ed25519-verify public-key #f))
  (define factories (native-ed25519-factories))
  (cond
    [(pure-ed25519-key? checked) (verify checked message signature)]
    [(pair? factories)
     (define safe-key
       (datum->pk-key (pk-key->datum checked 'rkt-public) 'rkt-public factories))
     (and (= (bytes-length signature) 64)
          (pk-verify safe-key message signature))]
    [(pure-from-native checked #f)
     =>
     (lambda (key) (and (bytes? signature) (verify key message signature)))]
    [else (no-native-provider 'ed25519-verify checked)]))

;; A fresh Ed25519 private key for key generation and tests: a proven native
;; factory when one exists, otherwise the pure backend. Returns the same key
;; types `read-ed25519-private-key` produces, so callers hand it straight to
;; `ed25519-sign`.
;;
;; Both helpers stay out of the pinned public API of rivet/distribution; the
;; in-package callers reach them through the `keygen` submodule below.
(define (generate-ed25519-private-key)
  (define factories (native-ed25519-factories))
  (cond
    [(pair? factories)
     (generate-private-key (get-pk 'eddsa (car factories)) '((curve ed25519)))]
    [(available?) (pure-generate-private-key)]
    [else
     (raise-arguments-error
      'generate-ed25519-private-key
      "no Ed25519 provider is available: install OpenSSL 3 or the ed25519 package")]))

;; The SubjectPublicKeyInfo DER of a private key from
;; `generate-ed25519-private-key`, the form the release tooling pins.
(define (ed25519-private-key->spki private-key)
  (ensure-ed25519 'ed25519-private-key->spki private-key #t)
  (if (pure-ed25519-key? private-key)
      (pure-public-key->der (pure-public-key private-key))
      (pk-key->datum private-key 'SubjectPublicKeyInfo)))

;; Internal entry points for the in-package key-generation callers; see the
;; comment on `generate-ed25519-private-key`.
(module* keygen #f
  (provide generate-ed25519-private-key
           ed25519-private-key->spki))
