#lang racket/base

(require crypto
         (only-in racket/base [sha256-bytes racket-sha256-bytes])
         (only-in crypto/libcrypto libcrypto-factory)
         "crypto-pure.rkt"
         net/base64
         racket/file
         racket/list
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

;; Every native factory that can sign and verify Ed25519 right now, empty
;; when none can. The official Racket 9.3 package builder carries an OpenSSL
;; that predates Ed25519 and no libnettle, so an empty result is a supported
;; runtime state, not an error: decode/sign/verify then route through the
;; pure RFC 8032 backend in crypto-pure.rkt. There is no alternative
;; signature algorithm and no mock.
(define (native-ed25519-factories)
  (remove-duplicates
   (for/list ([factory (in-list (append (crypto-factories)
                                        (list libcrypto-factory)
                                        (list (nettle-candidate))))]
              #:when (and factory (get-pk 'eddsa factory)))
     factory)))

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
  (cond
    [(pure-ed25519-key? checked)
     (sign checked message)]
    [else
     (define safe-key
       (datum->pk-key (pk-key->datum checked 'rkt-private)
                      'rkt-private
                      (or (native-ed25519-factories)
                          ;; The key exists as a native object, so a native
                          ;; factory that understands Ed25519 existed when it
                          ;; was produced; if none does now, fail loudly
                          ;; rather than with a bare contract error.
                          (raise-arguments-error
                           'ed25519-sign
                           "no native provider can parse the Ed25519 private key"
                           "factories configured" (crypto-factories)))))
     (pk-sign safe-key message)]))

(define (ed25519-verify public-key message signature)
  (define checked (ensure-ed25519 'ed25519-verify public-key #f))
  (cond
    [(pure-ed25519-key? checked)
     (verify checked message signature)]
    [else
     (define safe-key
       (datum->pk-key (pk-key->datum checked 'rkt-public)
                      'rkt-public
                      (native-ed25519-factories)))
     (and (= (bytes-length signature) 64)
          (pk-verify safe-key message signature))]))
