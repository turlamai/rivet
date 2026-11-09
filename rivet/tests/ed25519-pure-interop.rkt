#lang racket/base

;; Cross-backend Ed25519 interop. The pure fallback must parse the exact DER
;; and OpenSSH shapes the release tooling produces, and signatures must
;; verify across backends: a pure-produced signature under the native
;; provider and a native-produced signature under the pure backend. On a
;; host with no native Ed25519 provider (the package builder) the native
;; half records its absence explicitly and the pure half stays fully green —
;; a shipped verify-only process runs entirely on the pure backend.

(require crypto
         crypto/libcrypto
         net/base64
         racket/bytes
         racket/file
         rackunit
         (prefix-in pure: "../distribution/crypto-pure.rkt")
         "../distribution/crypto.rkt")

(crypto-factories (list libcrypto-factory))

;; DER prefixes pinned here byte for byte: the test, not the implementation,
;; owns the statement of what wire format the release tooling may write.
;; OneAsymmetricKey and PrivateKeyInfo are byte-identical for Ed25519
;; (RFC 5958 v1/v2 of the same PKCS#8 structure), so one 48-byte fixture
;; covers both names.
(define spki-prefix #"\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00")
(define private-key-prefix
  #"\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20")

(define keypair ((dynamic-require 'ed25519 'generate-keypair)))
(define seed ((dynamic-require 'ed25519 'keypair-secret) keypair))
(define public ((dynamic-require 'ed25519 'keypair-public) keypair))
(define message #"the update manifest payload boundary")

(define spki-bytes (bytes-append spki-prefix public))
(define private-key-bytes (bytes-append private-key-prefix seed))

(define (openssh-line pub)
  (define wire
    (bytes-append #"\x00\x00\x00\x0bssh-ed25519"
                  (integer->integer-bytes (bytes-length pub) 4 #f #t)
                  pub))
  (string-append "ssh-ed25519 "
                 (bytes->string/utf-8 (base64-encode wire #""))
                 " release@example.invalid"))

;; The native pk-key for the same seed, when a native provider exists. The
;; provider is probed by generating a key, the only use a host makes of it;
;; the rkt-private datum layout is (eddsa private ed25519 <public> <seed>):
;; public first, seed second — the ordering the native parser validates.
(define (native-ed25519-available?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and (generate-private-key 'eddsa '((curve ed25519))) #t)))

(define native-available? (native-ed25519-available?))
(define native-private
  (and native-available?
       (datum->pk-key (list 'eddsa 'private 'ed25519 public seed)
                      'rkt-private)))
(define native-public
  (and native-available?
       (datum->pk-key (list 'eddsa 'public 'ed25519 public)
                      'rkt-public)))

;; --- pure backend parses every released shape ------------------------------

(define from-pkcs8 (pure:decode-private-bytes 'test private-key-bytes))
(check-eq? (pure:pure-ed25519-key-kind from-pkcs8) 'private)
(check-equal? (pure:pure-ed25519-key-raw from-pkcs8) seed)

(define from-spki (pure:decode-public-bytes 'test spki-bytes))
(check-eq? (pure:pure-ed25519-key-kind from-spki) 'public)
(check-equal? (pure:pure-ed25519-key-raw from-spki) public)

(check-equal?
 (pure:pure-ed25519-key-raw
  (pure:decode-public-bytes 'test (openssh-line public)))
 public)

;; Fail closed on anything that is not one of the release shapes: a
;; mis-parse here would materialize as a verification bypass.
(check-exn exn:fail? (lambda () (pure:decode-private-bytes 'test seed)))
(check-exn exn:fail?
           (lambda ()
             (pure:decode-private-bytes 'test spki-bytes)))
(check-exn exn:fail?
           (lambda ()
             (pure:decode-public-bytes 'test private-key-bytes)))
(check-exn exn:fail?
           (lambda ()
             (pure:decode-public-bytes
              'test (openssh-line (subbytes public 1)))))

;; --- pure backend signs and verifies through the shared API ----------------

(define (write-key-file bytes)
  (define path (make-temporary-file "rivet-ed25519-key-~a"))
  (display-to-file bytes path #:exists 'truncate)
  path)

;; Decode through the pure backend explicitly so the shared API's pure
;; branch is exercised on every host — including one where the native
;; provider would otherwise win the decode. The file-read path below
;; proves the shared decode accepts the written key file on either
;; backend, whichever its host selects.
(define pure-private (pure:decode-private-bytes 'test private-key-bytes))
(define pure-public (pure:decode-public-bytes 'test spki-bytes))

;; The file path through the shared API: green on both backend choices.
(check-true
 (ed25519-verify (bytes->ed25519-public-key spki-bytes)
                 message
                 (ed25519-sign
                  (read-ed25519-private-key
                   (write-key-file private-key-bytes))
                  message)))

(define pure-signature (ed25519-sign pure-private message))
(check-equal? (bytes-length pure-signature) 64)
(check-true (ed25519-verify pure-public message pure-signature))
(check-false (ed25519-verify pure-public
                             (bytes-append message #"x")
                             pure-signature))
(define tampered-signature (bytes-copy pure-signature))
(bytes-set! tampered-signature 0
            (bitwise-xor (bytes-ref tampered-signature 0) #x01))
(check-false (ed25519-verify pure-public message tampered-signature)
             "a flipped signature bit must not verify")

;; --- cross-backend signatures verify under the other backend ---------------

(unless native-private
  (displayln
   "ed25519-pure-interop: no native Ed25519 provider on this host; \
native cross-verification halves skipped, pure halves remain green"))
(when native-public
  (check-true (ed25519-verify native-public message pure-signature)
              "a pure signature verifies under the native provider")
  (check-false (ed25519-verify native-public
                               (bytes-append message #"x")
                               pure-signature)))
(when native-private
  (define native-signature (ed25519-sign native-private message))
  (check-true (ed25519-verify pure-public message native-signature)
              "a native signature verifies under the pure backend")
  (check-false (ed25519-verify pure-public
                               (bytes-append message #"x")
                               native-signature))
  ;; Both backends accept the same DER private key shape.
  (check-true
   (ed25519-verify
    pure-public message
    (ed25519-sign
     (read-ed25519-private-key (write-key-file private-key-bytes))
     message))))
