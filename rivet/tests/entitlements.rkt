#lang racket/base

(require json
         racket/file
         racket/port
         racket/string
         racket/system
         rackunit
         "../../rivet-cli/entitlements.rkt")

;; Apple Silicon is qualified for the narrow JIT exception (2026-11-02,
;; docs/apple-release-readiness.md); Intel keeps the broader exception until
;; a dual-architecture probe qualifies it.
(check-equal? (entitlement-keys-for 'developer-id 'aarch64)
              '("com.apple.security.cs.allow-jit"))
(check-equal? (entitlement-keys-for 'developer-id 'x86_64)
              '("com.apple.security.cs.allow-unsigned-executable-memory"))

;; Unqualified channels must fail closed instead of reusing the Developer ID
;; policy under another flag.
(check-exn exn:fail? (lambda () (entitlement-keys-for 'mac-app-store 'aarch64)))
(check-exn exn:fail? (lambda () (entitlement-keys-for 'ios-app-store 'x86_64)))

;; Unknown channel names fail closed too.
(check-exn exn:fail?
           (lambda ()
             (parameterize ([current-environment-variables
                             (environment-variables-copy
                              (current-environment-variables))])
               (environment-variables-set! (current-environment-variables)
                                           #"RIVET_MACOS_CHANNEL"
                                           #"bogus")
               (entitlement-channel))))

;; The manifest is machine-readable and reports which channels exist but
;; have no qualified policy.
(define manifest (entitlement-manifest #:channel 'developer-id #:arch 'aarch64))
(check-equal? (hash-ref manifest 'schema) "rivet.macos-entitlements.v1")
(check-equal? (hash-ref manifest 'channel) "developer-id")
(check-equal? (hash-ref manifest 'arch) "arm64")
(check-equal? (hash-ref manifest 'keys) '("com.apple.security.cs.allow-jit"))
(check-not-false (member "mac-app-store" (hash-ref manifest 'unqualified-channels)))
(check-not-false (member "ios-app-store" (hash-ref manifest 'unqualified-channels)))

;; The emitted plist matches the declared keys, sorted and stable.
(define plist (entitlements-plist 'developer-id 'aarch64))
(check-regexp-match #rx"<key>com[.]apple[.]security[.]cs[.]allow-jit</key><true/>" plist)
(check-false (string-contains? plist "disable-library-validation"))

;; The dev overlay adds exactly the ad-hoc-signing library-validation
;; exemption on top of the declared keys; it is never distributed.
(define overlay (entitlements-dev-overlay-plist 'developer-id 'aarch64))
(check-regexp-match #rx"<key>com[.]apple[.]security[.]cs[.]disable-library-validation</key><true/>" overlay)
(check-regexp-match #rx"<key>com[.]apple[.]security[.]cs[.]allow-jit</key><true/>" overlay)

;; The comparator is an exact set match: missing and extra keys both fail.
(check-true (entitlements-match-manifest?
             '("com.apple.security.cs.allow-jit") 'developer-id 'aarch64))
(check-false (entitlements-match-manifest?
              '("com.apple.security.cs.allow-unsigned-executable-memory")
              'developer-id 'aarch64))
(check-false (entitlements-match-manifest?
              '("com.apple.security.cs.allow-jit"
                "com.apple.security.cs.disable-library-validation")
              'developer-id 'aarch64))

;; Reading effective entitlements back through codesign returns the sorted
;; key set the Mach-O was signed with, and the comparator accepts it.
;; codesign drops entitlements on non-Mach-O fixtures, so the fixture is a
;; copy of a system binary. Skipped where codesign is unavailable.
(define workdir (make-temporary-file "rivet-entitlements-~a" 'directory))
(define codesign (find-executable-path "codesign"))
(define mach-o-source
  (and codesign
       (for/first ([candidate (in-list '("/bin/echo" "/bin/ls"))]
                   #:when (file-exists? candidate))
         candidate)))
(when (and codesign mach-o-source)
  (dynamic-wind
   void
   (lambda ()
     (define target (build-path workdir "signed-object"))
     (copy-file mach-o-source target)
     (define ent (build-path workdir "signing.plist"))
     (display-to-file (entitlements-plist 'developer-id 'aarch64) ent
                      #:exists 'truncate/replace)
     (unless (system* codesign
                      "--force" "--sign" "-"
                      "--entitlements" (path->string ent)
                      (path->string target))
       (error 'entitlements-test "codesign could not sign the test fixture"))
     (check-equal? (effective-entitlement-keys target)
                   (entitlement-keys-for 'developer-id 'aarch64))
     (check-true (entitlements-match-manifest?
                  (effective-entitlement-keys target) 'developer-id 'aarch64)))
   (lambda () (delete-directory/files workdir))))
