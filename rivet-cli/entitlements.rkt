#lang racket/base

;; Channel-scoped macOS hardened-runtime entitlement policy (issue #358).
;;
;; The policy table below is the single source of truth for which
;; executable-memory exception each distribution channel and architecture
;; receives. It exists because the packager historically emitted
;; `com.apple.security.cs.allow-unsigned-executable-memory` unconditionally,
;; a broader Hardened Runtime exception than the embedded Racket CS runtime
;; has been shown to need: on Apple Silicon a hardened, signed bundle runs
;; the full embedded runtime with only `com.apple.security.cs.allow-jit`
;; (qualified 2026-11-02, see docs/apple-release-readiness.md). Intel x64
;; keeps the broader exception until an equivalent dual-architecture probe
;; qualifies it.
;;
;; Channels are deliberately separate: `mac-app-store` has no qualified
;; policy yet, so requesting it fails closed instead of silently reusing the
;; Developer ID set under a different flag. `ios-app-store` is not a macOS
;; packaging channel at all (issue #357 tracks that work).
;;
;; `disable-library-validation` is NOT part of any distribution manifest.
;; It is a development-signing artifact: ad-hoc hardened signatures cannot
;; load the equally ad-hoc embedded Racket framework ("different Team IDs"
;; AMFI failure), so CI qualification runs sign with `--dev-overlay`, which
;; adds that exemption on top of the declared channel keys. With real
;; Developer ID credentials the framework and app share a team ID and the
;; exemption is neither needed nor emitted.

(require json
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system)

(provide entitlement-channel
         entitlement-arch
         entitlement-keys-for
         entitlement-manifest
         write-entitlement-manifest!
         entitlements-plist
         write-entitlements!
         entitlements-dev-overlay-plist
         effective-entitlement-keys
         entitlements-match-manifest?
         check-entitlements!
         run-entitlements-command)

(define qualified-channels '(developer-id))
(define unqualified-channels '(mac-app-store ios-app-store))

(define policy
  ;; arch symbol -> list of entitlement keys, for every qualified channel.
  ;; Keep lists sorted; the comparator is an exact set match.
  (hash 'developer-id
        (hash 'aarch64 '("com.apple.security.cs.allow-jit")
              'x86_64 '("com.apple.security.cs.allow-unsigned-executable-memory"))))

(define (entitlement-channel)
  (define raw (getenv "RIVET_MACOS_CHANNEL"))
  (cond
    [(not raw) 'developer-id]
    [(member raw '("developer-id")) 'developer-id]
    [(member raw '("mac-app-store")) 'mac-app-store]
    [(member raw '("ios-app-store")) 'ios-app-store]
    [else
     (raise-arguments-error 'entitlement-channel
                            "unknown RIVET_MACOS_CHANNEL value"
                            "value" raw
                            "known" "developer-id, mac-app-store, ios-app-store")]))

(define (entitlement-arch)
  (case (system-type 'arch)
    [(aarch64) 'aarch64]
    [(x86_64) 'x86_64]
    [else (raise-arguments-error 'entitlement-arch
                                 "unsupported macOS architecture"
                                 "arch" (format "~a" (system-type 'arch)))]))

(define (entitlement-keys-for channel arch)
  (unless (member channel qualified-channels)
    (raise-arguments-error 'entitlement-keys-for
                           "distribution channel has no qualified entitlement policy"
                           "channel" (format "~a" channel)
                           "qualified" (string-join (map ~a qualified-channels) ", ")
                           "unqualified" (string-join (map ~a unqualified-channels) ", ")
                           "remedy" "qualify the channel per docs/apple-release-readiness.md before packaging it"))
  (hash-ref (hash-ref policy channel) arch))

(define (entitlement-manifest #:channel [channel (entitlement-channel)]
                              #:arch [arch (entitlement-arch)])
  (hasheq 'schema "rivet.macos-entitlements.v1"
          'channel (name channel)
          'arch (arch-name arch)
          'keys (entitlement-keys-for channel arch)
          'qualified-channels (map name qualified-channels)
          'unqualified-channels (map name unqualified-channels)))

(define (write-entitlement-manifest! path
                                     #:channel [channel (entitlement-channel)]
                                     #:arch [arch (entitlement-arch)])
  (make-parent-directory* path)
  (with-output-to-file path
    #:exists 'truncate/replace
    (lambda () (write-json (entitlement-manifest #:channel channel #:arch arch)))))

(define (entitlements-plist channel arch)
  (plist-string (entitlement-keys-for channel arch)))

(define (write-entitlements! path
                             #:channel [channel (entitlement-channel)]
                             #:arch [arch (entitlement-arch)])
  (make-parent-directory* path)
  (display-to-file (entitlements-plist channel arch) path
                   #:exists 'truncate/replace))

;; Ad-hoc hardened CI qualification signs with this overlay: the declared
;; channel keys plus the library-validation exemption that ad-hoc signing
;; needs to load the ad-hoc embedded framework. Never distributed.
(define dev-overlay-extra-key "com.apple.security.cs.disable-library-validation")

(define (dev-overlay-keys channel arch)
  (sort (remove-duplicates
         (cons dev-overlay-extra-key (entitlement-keys-for channel arch)))
        string<?))

(define (entitlements-dev-overlay-plist channel arch)
  (plist-string (dev-overlay-keys channel arch)))

(define (plist-string keys)
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
   "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
   "<plist version=\"1.0\"><dict>\n"
   (string-append* (for/list ([key (in-list (sort keys string<?))])
                     (format "  <key>~a</key><true/>\n" key)))
   "</dict></plist>\n"))

;; `codesign -d --entitlements - --xml <path>` prints a flat property-list
;; XML document; entitlement dicts of interest are flat boolean dicts.
(define (effective-entitlement-keys path)
  (define codesign (or (find-executable-path "codesign")
                       (raise-arguments-error 'effective-entitlement-keys
                                              "codesign was not found")))
  (define xml
    (with-output-to-string
      (lambda ()
        (unless (system* codesign "-d" "--entitlements" "-" "--xml" (path->string path))
          (raise-arguments-error 'effective-entitlement-keys
                                 "codesign could not read effective entitlements"
                                 "path" (path->string path))))))
  (sort (regexp-match* #rx"<key>([^<]+)</key>" xml #:match-select cadr)
        string<?))

(define (entitlements-match-manifest? keys channel arch)
  (equal? keys (entitlement-keys-for channel arch)))

;; Fail-closed release gate: the effective entitlements of a packaged app
;; must equal the declared channel/arch key set exactly — extra or missing
;; keys are both violations.
(define (check-entitlements! who app
                             #:channel [channel (entitlement-channel)]
                             #:arch [arch (entitlement-arch)]
                             #:overlay? [overlay? #f])
  (define expected
    (if overlay?
        (dev-overlay-keys channel arch)
        (entitlement-keys-for channel arch)))
  (define effective (effective-entitlement-keys app))
  (unless (equal? effective expected)
    (raise-arguments-error who
                           (if overlay?
                               "ad-hoc hardened entitlements do not match the dev overlay manifest"
                               "packaged entitlements do not match the declared channel manifest")
                           "app" (path->string app)
                           "channel" (format "~a" channel)
                           "arch" (arch-name arch)
                           "declared" expected
                           "effective" effective))
  app)

(define (->symbol v) (if (symbol? v) v (string->symbol (format "~a" v))))

(define (name v) (if (symbol? v) (symbol->string v) (format "~a" v)))

(define (arch-name arch)
  (case arch [(aarch64) "arm64"] [(x86_64) "x64"] [else (format "~a" arch)]))

;; CLI entry for `raco rivet entitlements ...`:
;;   --json                 machine-readable channel manifest
;;   --plist                declared entitlements for the channel/arch
;;   --dev-overlay --plist  declared keys plus the ad-hoc-signing
;;                          library-validation exemption (never distributed)
;;   --check <app>          fail closed unless the app's effective
;;                          entitlements equal the declared manifest
;;   --check-overlay <app>  same, against the dev-overlay key set
;; Returns a process exit code.
(define (run-entitlements-command mode [app-path #f])
  (cond
    [(eq? mode 'json)
     (write-json (entitlement-manifest))
     (newline)
     0]
    [(eq? mode 'plist)
     (display (entitlements-plist (entitlement-channel) (entitlement-arch)))
     0]
    [(eq? mode 'dev-overlay)
     (display (entitlements-dev-overlay-plist (entitlement-channel) (entitlement-arch)))
     0]
    [(eq? mode 'check)
     (check-entitlements! 'entitlements (string->path app-path))
     0]
    [(eq? mode 'check-overlay)
     (check-entitlements! 'entitlements (string->path app-path) #:overlay? #t)
     0]
    [else
     (raise-arguments-error 'run-entitlements-command "unknown mode" "mode" mode)]))
