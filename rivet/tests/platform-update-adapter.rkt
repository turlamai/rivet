#lang racket/base

(require file/zip
         json
         rackunit
         racket/file
         racket/path
         racket/port
         "../../rivet/distribution.rkt"
         (submod "../../rivet/distribution/platform-adapter.rkt" test-support))

(define platform (current-update-platform))

;; This probe makes ownership deterministic on every CI host. Paths alone
;; cannot reveal whether dpkg or rpm actually owns an executable.
(define (ownership-in-fixture executable)
  (if (member (path->string executable)
              '("/opt/Example/RivetHost" "/usr/bin/example"))
      'owned
      'unowned))

(check-equal? (detect-install-kind 'linux "/tmp/App.AppImage"
                                   "/tmp/App.AppImage")
              'appimage)
(check-equal? (detect-install-kind 'linux "/opt/Example/RivetHost" #f
                                   ownership-in-fixture)
              'package-manager)
(check-equal? (detect-install-kind 'linux "/usr/bin/example" #f
                                   ownership-in-fixture)
              'package-manager)
;; Previously /opt and /usr were always assumed to be package-managed:
;; a manually placed portable app in either directory was misclassified.
(check-equal? (detect-install-kind 'linux "/opt/Portable/RivetHost" #f
                                   ownership-in-fixture)
              'portable)
(check-equal? (detect-install-kind 'linux "/usr/local/bin/RivetHost" #f
                                   ownership-in-fixture)
              'portable)
(check-equal? (detect-install-kind 'linux "/home/user/example" #f
                                   ownership-in-fixture)
              'portable)
;; An AppImage's runtime environment wins even if its extracted executable
;; happens to be at a package-owned path.
(check-equal? (detect-install-kind 'linux "/opt/Example/RivetHost"
                                   "/tmp/Demo.AppImage"
                                   ownership-in-fixture)
              'appimage)
(check-equal? (detect-install-kind 'windows "C:\\\\Example\\\\RivetHost.exe" #f
                                   ownership-in-fixture)
              'portable)

;; If no package database can be consulted, do not classify an executable
;; under the OS installation prefixes as safely self-updatable.
(check-equal? (detect-install-kind 'linux "/opt/MaybeOwned/RivetHost" #f
                                   (lambda (_) 'unknown))
              'package-manager)
(check-equal? (detect-install-kind 'linux "/home/user/RivetHost" #f
                                   (lambda (_) 'unknown))
              'portable)

;; Exercise the real host package database on Linux runners, in addition to
;; deterministic injected-ownership tests above. This catches CLI invocation
;; changes (including the argument separator) that a fake probe cannot.
;; Racket-core CI runs this file on Ubuntu; other platforms retain the
;; portable deterministic tests without requiring dpkg or rpm.
(when (and (eq? platform 'linux)
           (not (getenv "APPIMAGE"))
           (file-exists? "/usr/bin/dpkg-query")
           (find-executable-path "dpkg-query"))
  (check-equal? (current-install-kind "/usr/bin/dpkg-query")
                'package-manager
                "a real dpkg-owned executable must not use portable updates"))

(define (candidate installer [version "2.0.0"] #:archive [archive #f])
  (define artifact
    (update-artifact platform 'x64 "https://updates.example/application.zip"
                     (if archive (sha256-file/hex archive) (make-string 64 #\a))
                     (if archive (file-size archive) 1) installer '() #f))
  (update-candidate
   (update-manifest "dev.rivet.adapter-test" version 2 'stable
                    "2026-10-10T00:00:00Z" "1.0.0" "1.0.0"
                    #t 100 (list artifact))
   artifact))

(define (write-text path value)
  (make-parent-directory* path)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (display value out))))

(define (read-text path)
  (call-with-input-file path port->string))

(define (make-update-archive root value)
  (define payload (build-path root "payload"))
  (define archive (build-path root "update.zip"))
  (when (directory-exists? payload) (delete-directory/files payload))
  (when (file-exists? archive) (delete-file archive))
  (write-text (build-path payload "version.txt") value)
  (parameterize ([current-directory root])
    (zip archive "payload"))
  archive)

(define (test-verifier expected)
  (lambda (payload)
    (check-equal? (read-text (build-path payload "version.txt")) expected)))

(check-equal? (platform-installer-policy 'windows 'zip) 'portable)
(check-equal? (platform-installer-policy 'windows 'msi) 'package-manager)
(check-equal? (platform-installer-policy 'macos 'dmg) 'package-manager)
(check-equal? (platform-installer-policy 'linux 'appimage) 'portable)
(check-equal? (platform-installer-policy 'linux 'deb) 'package-manager)
(check-equal? (platform-installer-policy 'linux 'rpm) 'package-manager)
(check-equal? (platform-installer-policy 'linux 'unknown) 'unsupported)

(define root (make-temporary-file "rivet-platform-update-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    ;; Successful replacement is committed only after restart and health. Its
    ;; previous payload, staging directory, marker, and journal are removed.
    (define success-root (build-path root "success"))
    (make-directory success-root)
    (define success-target (build-path success-root "installed"))
    (write-text (build-path success-target "version.txt") "old")
    (define success-archive (make-update-archive success-root "new"))
    (define success-journal (build-path success-root "transaction.json"))
    (define restarted? #f)
    (define success
      (prepare-platform-installation
       (candidate 'zip #:archive success-archive) success-archive
       #:target success-target
       #:restart (lambda () (set! restarted? #t) 'restarted)
       #:health-check
       (lambda ()
         (string=? (read-text (build-path success-target "version.txt"))
                   "new"))
       #:verify-staged (test-verifier "new")))
    (define same-target-different-backup
      (prepare-platform-installation
       (candidate 'zip #:archive success-archive) success-archive
       #:target success-target
       #:backup-path (build-path success-root "alternate-backup")
       #:restart void
       #:health-check (lambda () #t)
       #:verify-staged (test-verifier "new")))

    ;; A second updater is rejected before it can touch the shared staging,
    ;; backup, marker, or journal paths. The first holder is a separate thread
    ;; so this proves the in-process layer instead of relying only on an OS
    ;; file lock.
    (define lock-entered (make-semaphore 0))
    (define release-lock (make-semaphore 0))
    (define lock-result (make-channel))
    (thread
     (lambda ()
       (with-handlers ([exn? (lambda (error) (channel-put lock-result error))])
         (call-with-platform-installation-lock
          'test-update-lock
          success
          (lambda ()
            (semaphore-post lock-entered)
            (semaphore-wait release-lock)))
         (channel-put lock-result 'released))))
    (check-not-false (sync/timeout 2 lock-entered))
    (check-exn #rx"another update transaction already owns"
               (lambda ()
                 (execute-platform-installation!
                  same-target-different-backup
                  #:journal-path success-journal)))
    (check-equal? (read-text (build-path success-target "version.txt")) "old")
    (check-false (file-exists? success-journal))
    (semaphore-post release-lock)
    (check-equal? (sync/timeout 2 lock-result) 'released)

    (check-equal?
     (execute-platform-installation! success #:journal-path success-journal)
     'restarted)
    (check-true restarted?)
    (check-equal? (read-text (build-path success-target "version.txt")) "new")
    (check-false (file-exists? success-journal))
    (check-false (directory-exists?
                  (string->path
                   (string-append (path->string success-target)
                                  ".rivet-backup"))))

    ;; A failed health check restores the previous application byte-for-byte.
    (define unhealthy-root (build-path root "unhealthy"))
    (make-directory unhealthy-root)
    (define unhealthy-target (build-path unhealthy-root "installed"))
    (write-text (build-path unhealthy-target "version.txt") "healthy-old")
    (define unhealthy-archive (make-update-archive unhealthy-root "bad-new"))
    (define unhealthy
      (prepare-platform-installation
       (candidate 'zip "2.0.1" #:archive unhealthy-archive) unhealthy-archive
       #:target unhealthy-target
       #:restart void
       #:health-check (lambda () #f)
       #:verify-staged (test-verifier "bad-new")))
    (check-exn #rx"failed its health check"
               (lambda () (execute-platform-installation! unhealthy)))
    (check-equal?
     (read-text (build-path unhealthy-target "version.txt")) "healthy-old")

    ;; Verification happens before the old target moves.
    (define rejected-root (build-path root "rejected"))
    (make-directory rejected-root)
    (define rejected-target (build-path rejected-root "installed"))
    (write-text (build-path rejected-target "version.txt") "trusted")
    (define rejected-archive (make-update-archive rejected-root "untrusted"))
    (define rejected
      (prepare-platform-installation
       (candidate 'zip "2.0.2" #:archive rejected-archive) rejected-archive
       #:target rejected-target
       #:restart void
       #:health-check (lambda () #t)
       #:verify-staged (lambda (_) (error 'signature "invalid"))))
    (check-exn #rx"invalid"
               (lambda () (execute-platform-installation! rejected)))
    (check-equal? (read-text (build-path rejected-target "version.txt"))
                  "trusted")

    ;; Recovery reconstructs the same plan in a new process and rolls back an
    ;; interruption after replacement but before restart completed.
    (define recovery-root (build-path root "recovery"))
    (make-directory recovery-root)
    (define recovery-target (build-path recovery-root "installed"))
    (write-text (build-path recovery-target "version.txt") "before-crash")
    (define recovery-archive (make-update-archive recovery-root "after-crash"))
    (define recovery-journal (build-path recovery-root "transaction.json"))
    (define escape #f)
    (define interrupted
      (prepare-platform-installation
       (candidate 'zip "2.0.3" #:archive recovery-archive) recovery-archive
       #:target recovery-target
       #:restart (lambda () (escape 'process-stopped))
       #:health-check (lambda () #t)
       #:verify-staged (test-verifier "after-crash")))
    (check-equal?
     (call-with-current-continuation
      (lambda (return)
        (set! escape return)
        (execute-platform-installation! interrupted
                                        #:journal-path recovery-journal)))
     'process-stopped)
    (check-equal? (read-text (build-path recovery-target "version.txt"))
                  "after-crash")
    (check-equal?
     (hash-ref (call-with-input-file recovery-journal read-json) 'phase)
     "restarting")
    (define reconstructed
      (prepare-platform-installation
       (candidate 'zip "2.0.3" #:archive recovery-archive) recovery-archive
       #:target recovery-target
       #:restart void
       #:health-check (lambda () #t)
       #:verify-staged (test-verifier "after-crash")))
    (check-equal?
     (recover-platform-installation! reconstructed recovery-journal)
     'rolled-back)
    (check-equal? (read-text (build-path recovery-target "version.txt"))
                  "before-crash")

    ;; First-install rollback uses a durable marker, so it removes the failed
    ;; replacement without inventing a nonexistent previous target.
    (define first-root (build-path root "first-install"))
    (make-directory first-root)
    (define first-target (build-path first-root "installed"))
    (define first-archive (make-update-archive first-root "first"))
    (define first-install
      (prepare-platform-installation
       (candidate 'zip "2.0.4" #:archive first-archive) first-archive
       #:target first-target
       #:restart (lambda () (error 'restart "failed"))
       #:health-check (lambda () #t)
       #:verify-staged (test-verifier "first")))
    (check-exn #rx"restart: failed"
               (lambda () (execute-platform-installation! first-install)))
    (check-false (directory-exists? first-target))

    ;; Managed installers cannot be smuggled through the portable path.
    (define managed-installer
      (case platform
        [(windows) 'msi]
        [(macos) 'dmg]
        [(linux) 'deb]))
    (check-exn
     #rx"owned by the operating-system package manager"
     (lambda ()
       (prepare-platform-installation
        (candidate managed-installer "2.0.5") success-archive
        #:target (build-path root "managed-target")
        #:restart void
        #:health-check (lambda () #t)))))
  (lambda () (delete-directory/files root)))
