#lang racket/base

;; First-party last-mile policy and atomic replacement for signed Rivet
;; updates. This module deliberately stays outside RVT1 and the embedded
;; runtime: an update is a distribution transaction, not an application RPC.

(require file/gunzip
         file/untar
         file/unzip
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system
         "identity.rkt"
         "manifest.rkt"
         "updater.rkt")

(provide platform-installation?
         current-update-platform
         current-install-kind
         platform-installer-policy
         verify-platform-payload!
         prepare-platform-installation
         execute-platform-installation!
         recover-platform-installation!)

(struct platform-installation (plan health-check commit transaction-lock preflight))

(define (current-update-platform)
  (platform-symbol))

;; Query actual package ownership rather than guessing from /opt or /usr.
;; Exit status 1 means "not owned"; absence of a package database, a failed
;; query, or an inaccessible executable is an unknown result. Keep that third
;; state so an unavailable database cannot authorize an unsafe self-update.
(define (linux-package-ownership executable)
  (if (not (file-exists? executable))
      'unknown
      (let ([results
             (for/list ([query (in-list '(("dpkg-query" "-S") ("rpm" "-qf")))]
                        #:when (find-executable-path (first query)))
               (define program (find-executable-path (first query)))
               (with-handlers ([exn:fail? (lambda (_) 'unknown)])
                 (define exit-status
                   (parameterize ([current-output-port (open-output-nowhere)]
                                  [current-error-port (open-output-nowhere)])
                     (system*/exit-code program (second query) "--"
                                        (path->string executable))))
                 (cond
                   [(zero? exit-status) 'owned]
                   [(= exit-status 1) 'unowned]
                   [else 'unknown])))])
        (cond
          [(memq 'owned results) 'owned]
          [(or (null? results) (memq 'unknown results)) 'unknown]
          [else 'unowned]))))

(define (system-install-prefix? executable)
  (define value (bytes->string/locale (path->bytes executable)))
  (or (string-prefix? value "/opt/")
      (string-prefix? value "/usr/")))

;; The optional ownership probe is private (test-support only); production
;; callers still use current-install-kind with the same public signature.
(define (detect-install-kind platform executable appimage
                             [ownership linux-package-ownership])
  (cond
    [(not (eq? platform 'linux)) 'portable]
    [(and appimage (not (string=? (string-trim appimage) ""))) 'appimage]
    [else
     ;; Interpret Linux paths with Linux semantics even when the private
     ;; policy probe runs on a Windows CI host. In particular, /opt must not
     ;; acquire the host's drive letter before ownership/prefix checks.
     (define linux-path
       (bytes->path (if (path-for-some-system? executable)
                        (path->bytes executable)
                        (string->bytes/locale executable))
                    'unix))
     (define normalized
       (simplify-path (if (complete-path? linux-path)
                          linux-path
                          (path->complete-path linux-path))
                      #f))
     (case (ownership normalized)
       [(owned) 'package-manager]
       [(unowned) 'portable]
       [(unknown)
        ;; Fail closed for system prefixes when the package database cannot
        ;; prove ownership. This retains the previous conservative behavior
        ;; instead of bypassing package-manager elevation or transactions.
        (if (system-install-prefix? normalized) 'package-manager 'portable)]
       [else
        (raise-arguments-error 'detect-install-kind
                               "unrecognized Linux package ownership result")])]))

(define (current-install-kind [executable (find-system-path 'run-file)])
  (detect-install-kind (current-update-platform) executable (getenv "APPIMAGE")))

;; `portable` means Rivet can replace the application payload itself.
;; `package-manager` means installation must remain under the OS transaction
;; owner; silently unpacking one of these artifacts would bypass elevation,
;; receipts, repository trust, and rollback policy.
(define (platform-installer-policy platform installer)
  (case platform
    [(windows)
     (case installer
       [(zip) 'portable]
       [(msi msix exe) 'package-manager]
       [else 'unsupported])]
    [(macos)
     (case installer
       [(zip) 'portable]
       [(dmg pkg) 'package-manager]
       [else 'unsupported])]
    [(linux)
     (case installer
       [(zip targz appimage) 'portable]
       [(deb rpm) 'package-manager]
       [else 'unsupported])]
    [else 'unsupported]))

(define (run-verifier! who executable . arguments)
  (unless executable
    (raise-arguments-error who "required platform verifier was not found"))
  (unless (apply system* executable arguments)
    (raise-arguments-error who
                           "platform signature verification failed"
                           "payload" (last arguments))))

(define (verify-platform-payload! platform payload)
  (case platform
    [(windows)
     (define executable (build-path payload "RivetHost.exe"))
     (unless (file-exists? executable)
       (raise-arguments-error 'verify-platform-payload!
                              "portable Windows payload has no RivetHost.exe"
                              "payload" payload))
     (define powershell
       (or (find-executable-path "pwsh.exe")
           (find-executable-path "powershell.exe")))
     (run-verifier!
      'verify-platform-payload! powershell
      "-NoLogo" "-NoProfile" "-NonInteractive" "-Command"
      (string-append
       "$signature = Get-AuthenticodeSignature -LiteralPath $args[0]; "
       "if ($signature.Status -ne 'Valid') { "
       "Write-Error ('RivetHost.exe Authenticode status: ' + $signature.Status); "
       "exit 1 }")
      (path->string executable))]
    [(macos)
     (run-verifier! 'verify-platform-payload!
                    (find-executable-path "codesign")
                    "--verify" "--deep" "--strict" (path->string payload))]
    [(linux)
     ;; Linux portable updates are authorized by the signed manifest and its
     ;; exact size/SHA-256. deb/rpm are never routed here.
     (void)]
    [else
     (raise-arguments-error 'verify-platform-payload!
                            "unsupported update platform"
                            "platform" platform)]))

(define (path-present? path)
  (or (file-exists? path)
      (directory-exists? path)
      (link-exists? path)))

(define (remove-path! path)
  (cond
    [(link-exists? path) (delete-file path)]
    [(directory-exists? path) (delete-directory/files path)]
    [(file-exists? path) (delete-file path)]))

(define (sibling-path target suffix)
  (string->path (string-append (path->string target) suffix)))

;; OS file locks serialize separate application processes. Keep a matching
;; in-process semaphore because some file-lock implementations are scoped to a
;; process and would otherwise allow two threads to enter the same transaction.
(define transaction-locks (make-hash))
(define transaction-locks-guard (make-semaphore 1))

(define (transaction-semaphore lock-path)
  (define key (path->string (normal-case-path lock-path)))
  (call-with-semaphore
   transaction-locks-guard
   (lambda ()
     (hash-ref transaction-locks key
               (lambda ()
                 (define lock (make-semaphore 1))
                 (hash-set! transaction-locks key lock)
                 lock)))))

(define (call-with-platform-installation-lock who installation thunk)
  (define lock-path (platform-installation-transaction-lock installation))
  (unless (complete-path? lock-path)
    (raise-arguments-error who
                           "platform installation has no absolute target identity"))
  (make-parent-directory* lock-path)
  (define local-lock (transaction-semaphore lock-path))
  (dynamic-wind
    (lambda ()
      ;; Do not allow an asynchronous break between acquiring the semaphore
      ;; and installing the dynamic-wind cleanup that releases it.
      (parameterize-break
       #f
       (unless (semaphore-try-wait? local-lock)
         (raise-arguments-error
          who
          "another update transaction already owns this installation"
          "lock" lock-path))))
    (lambda ()
      (call-with-file-lock/timeout
       #f
       'exclusive
       thunk
       (lambda ()
         (raise-arguments-error
          who
          "another process already owns this update transaction"
          "lock" lock-path))
       #:lock-file lock-path))
    (lambda () (semaphore-post local-lock))))

(define (normalize-target who path)
  (unless (complete-path? path)
    (raise-argument-error who "complete-path?" path))
  (simplify-path path #f))

;; Never unpack a mutable download path after an earlier verification. Copy
;; at most the signed size plus one detection byte into an owner-created,
;; same-filesystem snapshot, verify that exact snapshot, then consume it.
(define (call-with-verified-artifact-snapshot candidate downloaded target consume)
  (define snapshot
    (make-temporary-file ".rivet-artifact-~a" #f (path-only target)))
  (dynamic-wind
    void
    (lambda ()
      (call-with-input-file downloaded
        (lambda (in)
          (call-with-output-file snapshot #:exists 'truncate/replace
            (lambda (out)
              (copy-port
               (make-limited-input-port
                in (add1 (update-artifact-size (update-candidate-artifact candidate))) #f)
               out)))))
      (verify-update-artifact! candidate snapshot)
      (consume snapshot))
    (lambda () (when (file-exists? snapshot) (delete-file snapshot)))))

(define (stage-zip! downloaded staging-root)
  (make-directory staging-root)
  (unzip downloaded
         (make-filesystem-entry-reader #:dest staging-root #:exists 'error)
         #:preserve-attributes? #t)
  (define entries (directory-list staging-root #:build? #t))
  ;; A signed archive is not necessarily a valid app. In particular, do
  ;; not rename a single top-level *file* over the existing app directory.
  ;; Also reject a symbolic-link root rather than trusting its target.
  (unless (and (= (length entries) 1)
               (directory-exists? (car entries))
               (not (link-exists? (car entries))))
    (raise-arguments-error 'prepare-platform-installation
                           "portable ZIP must contain exactly one real payload directory"
                           "entry-count" (length entries)))
  (car entries))

(define (stage-appimage! downloaded staging-root)
  (make-directory staging-root)
  (define staged (build-path staging-root "application.AppImage"))
  (copy-file downloaded staged)
  (file-or-directory-permissions staged #o755)
  staged)

;; Linux products ship tar.gz portable payloads as well as ZIP/AppImage.
;; Decompress synchronously so gzip failures propagate to the transaction;
;; extraction uses Racket's non-permissive path and link checks, never a shell.
;; Keep the temporary tar outside the extracted entries, on the target volume.
(define (stage-targz! downloaded staging-root)
  (make-directory staging-root)
  (define tar-path (build-path staging-root "archive.tar"))
  (define contents (build-path staging-root "contents"))
  (with-handlers ([exn?
                   (lambda (error)
                     (with-handlers ([exn:fail? void])
                       (delete-directory/files staging-root))
                     (raise error))])
    (make-directory contents)
    (dynamic-wind
      void
      (lambda ()
        (call-with-input-file downloaded
          (lambda (in)
            (call-with-output-file tar-path
              #:exists 'error
              (lambda (out) (gunzip-through-ports in out)))))
        (untar tar-path #:dest contents #:permissive? #f
               #:filter
               (lambda (_entry _destination type _size _link _time _mode)
                 (unless (memq type '(file dir link extended-header
                                          extended-header-for-next
                                          gnu-long-name gnu-long-link))
                   (raise-arguments-error 'prepare-platform-installation
                                          "unsupported portable tar entry"
                                          "type" type))
                 #t))
        (define entries (directory-list contents #:build? #t))
        (unless (and (= (length entries) 1)
                     (directory-exists? (car entries))
                     (not (link-exists? (car entries))))
          (raise-arguments-error 'prepare-platform-installation
                                 "portable tar archive must contain exactly one payload directory"))
        (car entries))
      (lambda () (when (file-exists? tar-path) (delete-file tar-path))))))

(define (prepare-platform-installation
         candidate downloaded-path
         #:target target-path
         #:restart restart
         #:health-check health-check
         #:verify-staged [verify-staged #f]
         #:backup-path [configured-backup-path #f])
  (unless (update-candidate? candidate)
    (raise-argument-error 'prepare-platform-installation
                          "update-candidate?" candidate))
  (unless (procedure? restart)
    (raise-argument-error 'prepare-platform-installation "procedure?" restart))
  (unless (procedure? health-check)
    (raise-argument-error 'prepare-platform-installation
                          "procedure?" health-check))
  (define artifact (update-candidate-artifact candidate))
  (define platform (update-artifact-platform artifact))
  (define installer (update-artifact-installer artifact))
  (define running-platform (current-update-platform))
  (unless (eq? platform running-platform)
    (raise-arguments-error 'prepare-platform-installation
                           "candidate targets a different operating system"
                           "candidate-platform" platform
                           "running-platform" running-platform))
  (case (platform-installer-policy platform installer)
    [(package-manager)
     (raise-arguments-error
      'prepare-platform-installation
      "installer is owned by the operating-system package manager"
      "platform" platform
      "installer" installer
      "policy" "invoke the native installer/package manager with elevation outside the portable adapter")]
    [(unsupported)
     (raise-arguments-error 'prepare-platform-installation
                            "unsupported installer for platform"
                            "platform" platform
                            "installer" installer)])

  (define downloaded (normalize-target 'prepare-platform-installation
                                       downloaded-path))
  (define target (normalize-target 'prepare-platform-installation target-path))
  (define backup
    (normalize-target
     'prepare-platform-installation
     (or configured-backup-path (sibling-path target ".rivet-backup"))))
  (define staging-root (sibling-path target ".rivet-staging"))
  (define no-previous-marker (sibling-path backup ".empty"))
  (when (or (equal? downloaded target)
            (equal? downloaded backup)
            (equal? target backup))
    (raise-arguments-error 'prepare-platform-installation
                           "download, target, and backup paths must be distinct"))
  (when (or (link-exists? target) (link-exists? backup))
    (raise-arguments-error 'prepare-platform-installation
                           "target and backup must not be symbolic links"
                           "target" target
                           "backup" backup))

  (define verifier
    (or verify-staged
        (lambda (payload) (verify-platform-payload! platform payload))))

  (define (preflight)
    (when (or (path-present? backup) (path-present? no-previous-marker))
      (raise-arguments-error
       'platform-update-install
       "an unfinished installation must be recovered before starting another"
       "backup" backup)))

  (define (install downloaded-input)
    (unless (equal? (normalize-target 'platform-update-install downloaded-input)
                    downloaded)
      (raise-arguments-error 'platform-update-install
                             "install plan received an unexpected artifact path"
                             "expected" downloaded
                             "actual" downloaded-input))
    (unless (file-exists? downloaded)
      (raise-arguments-error 'platform-update-install
                             "verified update artifact does not exist"
                             "artifact" downloaded))
    (preflight)
    (when (path-present? staging-root) (remove-path! staging-root))
    (make-parent-directory* target)
    (define staged-payload
      (call-with-verified-artifact-snapshot
       candidate downloaded target
       (lambda (snapshot)
         (case installer
           [(zip) (stage-zip! snapshot staging-root)]
           [(targz) (stage-targz! snapshot staging-root)]
           [(appimage) (stage-appimage! snapshot staging-root)]))))
    (verifier staged-payload)
    (if (path-present? target)
        (rename-file-or-directory target backup)
        (call-with-output-file no-previous-marker
          #:exists 'error
          (lambda (out) (display "no previous installation\n" out))))
    (rename-file-or-directory staged-payload target)
    (when (directory-exists? staging-root)
      (delete-directory/files staging-root)))

  (define (rollback)
    ;; Idempotent in every interruption window. Neither marker existing means
    ;; installation had not yet moved or created the target.
    (cond
      [(path-present? backup)
       (when (path-present? target) (remove-path! target))
       (rename-file-or-directory backup target)]
      [(file-exists? no-previous-marker)
       (when (path-present? target) (remove-path! target))
       (delete-file no-previous-marker)])
    (when (path-present? staging-root) (remove-path! staging-root)))

  (define (commit)
    ;; Cleanup is deliberately idempotent: recovery may repeat it after the
    ;; filesystem side effect and before the committed phase is durable.
    (when (path-present? backup) (remove-path! backup))
    (when (file-exists? no-previous-marker) (delete-file no-previous-marker))
    (when (path-present? staging-root) (remove-path! staging-root)))

  (platform-installation
   (make-install-plan candidate downloaded
                      #:backup-path backup
                      #:install install
                      #:restart restart
                      #:rollback rollback)
   health-check
   commit
   (sibling-path target ".rivet-update.lock")
   preflight))

(define (execute-platform-installation! installation
                                        #:journal-path [journal-path #f])
  (unless (platform-installation? installation)
    (raise-argument-error 'execute-platform-installation!
                          "platform-installation?" installation))
  (call-with-platform-installation-lock
   'execute-platform-installation!
   installation
   (lambda ()
     ;; Refuse an existing transaction before the new plan can write its
     ;; journal or invoke rollback against somebody else's preserved backup.
     ((platform-installation-preflight installation))
     (when (and journal-path (path-present? journal-path))
       (raise-arguments-error
        'execute-platform-installation!
        "an unfinished installation journal must be recovered before starting another"
        "journal" journal-path))
     (execute-install-plan!
      (platform-installation-plan installation)
      #:health-check (platform-installation-health-check installation)
      #:commit (platform-installation-commit installation)
      #:journal-path journal-path))))

(define (recover-platform-installation! installation journal-path)
  (unless (platform-installation? installation)
    (raise-argument-error 'recover-platform-installation!
                          "platform-installation?" installation))
  (call-with-platform-installation-lock
   'recover-platform-installation!
   installation
   (lambda ()
     (recover-install-plan!
      (platform-installation-plan installation)
      journal-path
      #:commit (platform-installation-commit installation)))))

(module+ test-support
  (provide detect-install-kind
           stage-targz!
           call-with-platform-installation-lock))
