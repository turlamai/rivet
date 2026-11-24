#lang racket/base

;; Pure-Racket Ed25519 key handling for environments where no native crypto
;; factory implements Ed25519. The official package builder compiles Rivet
;; against an OpenSSL that predates the algorithm and carries no libnettle,
;; and a shipped application that only verifies an update manifest must not
;; depend on a native provider at all. The arithmetic lives in the separately
;; packaged, RFC 8032-validated `ed25519` package; this module owns only the
;; wire formats Rivet's release tooling already produces: DER
;; SubjectPublicKeyInfo (the form release builds embed as hex), DER
;; OneAsymmetricKey / PrivateKeyInfo private keys, and the OpenSSH public-key
;; line. Key objects are opaque here: they flow between this module and
;; `rivet/distribution/crypto` only, and never cross a process boundary.

(require net/base64
         racket/bytes
         racket/list
         racket/random
         racket/string)

(provide pure-ed25519-key
         pure-ed25519-key?
         pure-ed25519-key-kind
         pure-ed25519-key-raw
         available?
         decode-private-bytes
         decode-public-bytes
         generate-private-key
         public-key
         private-key->der
         public-key->der
         sign
         verify)

(struct pure-ed25519-key (kind raw)
  #:transparent
  ;; kind is 'private or 'public; raw is the 32-byte seed or public key.
  #:guard (lambda (kind raw name)
            (unless (memq kind '(private public))
              (raise-argument-error name "'(private public)" kind))
            (unless (and (bytes? raw) (= 32 (bytes-length raw)))
              (raise-argument-error name "32-byte key bytes" raw))
            (values kind raw)))

;; Fixed DER prefixes for the Ed25519 key shapes. A prefix comparison plus a
;; total-length check is a complete parser for these single-algorithm
;; structures; anything else must fail closed rather than guess, because a
;; mis-parsed key materializes as a verification bypass. For Ed25519 the
;; OneAsymmetricKey and PrivateKeyInfo names are byte-identical (RFC 5958
;; v1/v2 of the same PKCS#8 structure): 48 bytes, nested OCTET STRINGs.
(define spki-prefix #"\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00")
(define private-key-prefix
  #"\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20")
(define openssh-algorithm #"ssh-ed25519")

(define (available?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (dynamic-require 'ed25519 #f)
    #t))

(define (decode-private-bytes who raw)
  (or (and (bytes? raw)
           (= 48 (bytes-length raw))
           (bytes=? (subbytes raw 0 16) private-key-prefix)
           (pure-ed25519-key 'private (subbytes raw 16)))
      (raise-arguments-error who
        "could not decode Ed25519 private key without a native provider"
        "accepted formats" '(OneAsymmetricKey PrivateKeyInfo)
        "bytes length" (if (bytes? raw) (bytes-length raw) raw))))

(define (decode-public-bytes who raw)
  (or (and (bytes? raw)
           (= 44 (bytes-length raw))
           (bytes=? (subbytes raw 0 12) spki-prefix)
           (pure-ed25519-key 'public (subbytes raw 12)))
      (and (or (bytes? raw) (string? raw))
           (or (and (bytes? raw)
                    (with-handlers ([exn:fail? (lambda (_) #f)])
                      (pure-key-from-openssh
                       who (bytes->string/utf-8 raw))))
               (and (string? raw)
                    (pure-key-from-openssh who raw))))
      (raise-arguments-error who
        "could not decode Ed25519 public key without a native provider"
        "accepted formats" '(SubjectPublicKeyInfo openssh-public)
        "bytes length" (if (bytes? raw) (bytes-length raw) raw))))

;; Key generation and the DER encoders inverse to the parsers above. The
;; private seed is 32 bytes of OS entropy and the wire shapes are exactly the
;; ones OpenSSL 3 writes for Ed25519 (48-byte PKCS#8, 44-byte SPKI), so a key
;; generated without a native provider is still read back by every tool in
;; the release flow.
(define (generate-private-key)
  (pure-ed25519-key 'private (crypto-random-bytes 32)))

(define (public-key private-key)
  (unless (and (pure-ed25519-key? private-key)
               (eq? (pure-ed25519-key-kind private-key) 'private))
    (raise-argument-error 'public-key "pure-ed25519 private key" private-key))
  (dynamic-require 'ed25519 #f)
  (pure-ed25519-key
   'public
   ((dynamic-require 'ed25519 'secret->public) (pure-ed25519-key-raw private-key))))

(define (private-key->der private-key)
  (unless (and (pure-ed25519-key? private-key)
               (eq? (pure-ed25519-key-kind private-key) 'private))
    (raise-argument-error 'private-key->der "pure-ed25519 private key" private-key))
  (bytes-append private-key-prefix (pure-ed25519-key-raw private-key)))

(define (public-key->der public-key)
  (unless (and (pure-ed25519-key? public-key)
               (eq? (pure-ed25519-key-kind public-key) 'public))
    (raise-argument-error 'public-key->der "pure-ed25519 public key" public-key))
  (bytes-append spki-prefix (pure-ed25519-key-raw public-key)))

;; The OpenSSH single-line form: "ssh-ed25519 <base64> [comment]", where the
;; decoded wire blob is the length-prefixed algorithm name followed by the
;; 32-byte key. Comments and trailing whitespace are part of the format and
;; ignored; a mismatched length or algorithm fails closed.
(define (pure-key-from-openssh who text)
  (define line (string-trim (first (string-split text "\n"))))
  (define parts (string-split line))
  (and (>= (length parts) 2)
       (string=? (first parts) (bytes->string/utf-8 openssh-algorithm))
       (let ([wire (with-handlers ([exn:fail? (lambda (_) #f)])
                     (base64-decode (string->bytes/utf-8 (second parts))))])
         (and wire
              (>= (bytes-length wire) 15)
              (let ([name-length (integer-bytes->integer wire #f #t 0 4)])
                (and (= name-length (bytes-length openssh-algorithm))
                     (bytes=? (subbytes wire 4 (+ 4 name-length))
                              openssh-algorithm)
                     (let ([key-length
                            (integer-bytes->integer
                             wire #f #t (+ 4 name-length)
                             (+ 8 name-length))])
                       (and (= key-length 32)
                            (= (bytes-length wire)
                               (+ 8 name-length key-length))
                            (pure-ed25519-key
                             'public
                             (subbytes wire (+ 8 name-length)
                                       (+ 8 name-length key-length)))))))))))

(define (sign key message)
  (unless (and (pure-ed25519-key? key)
               (eq? (pure-ed25519-key-kind key) 'private))
    (raise-argument-error 'sign "pure-ed25519 private key" key))
  (dynamic-require 'ed25519 #f)
  ((dynamic-require 'ed25519 'sign)
   message (pure-ed25519-key-raw key)))

(define (verify key message signature)
  (unless (and (pure-ed25519-key? key)
               (eq? (pure-ed25519-key-kind key) 'public))
    (raise-argument-error 'verify "pure-ed25519 public key" key))
  (dynamic-require 'ed25519 #f)
  (and (bytes? signature) (= 64 (bytes-length signature))
       ((dynamic-require 'ed25519 'verify)
        message signature (pure-ed25519-key-raw key))))
