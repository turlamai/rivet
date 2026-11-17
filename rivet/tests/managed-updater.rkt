#lang racket/base

(require rackunit
         racket/file
         "../../rivet/distribution.rkt"
         (submod "../../rivet/distribution/managed-updater.rkt" test-support))

(define artifact
  (update-artifact 'windows 'x64 "https://updates.example/app.zip"
                   (make-string 64 #\a) 100 'zip '() #f))
(define manifest
  (update-manifest "dev.rivet.managed-test" "2.0.0" 2 'stable
                   "2026-10-13T00:00:00Z" "0.0.0" "1.0.0"
                   #t 100 (list artifact)))

;; A feed may carry one component per platform; the updater selects the
;; component the product declares.
(define app-artifact
  (update-artifact 'windows 'x64 "https://updates.example/app-2.zip"
                   (make-string 64 #\b) 120 'zip '() 'app))
(define app-manifest
  (update-manifest "dev.rivet.managed-test" "2.0.0" 2 'stable
                   "2026-10-13T00:00:00Z" "0.0.0" "1.0.0"
                   #t 100 (list app-artifact)))
(define (app-fetch _url _key
                   #:key-id [_key-id #f]
                   #:trusted-keys [_trusted-keys #f]
                   #:maximum-bytes [_maximum-bytes (* 1024 1024)])
  app-manifest)

(check-eq? (update-architecture-for 'x86_64) 'x64)
(check-eq? (update-architecture-for 'amd64) 'x64)
(check-eq? (update-architecture-for 'aarch64) 'arm64)
(check-exn #rx"unsupported update architecture"
           (lambda () (update-architecture-for 'riscv64)))

(define (fake-fetch _url _key
                    #:key-id [_key-id #f]
                    #:trusted-keys [_trusted-keys #f]
                    #:maximum-bytes [_maximum-bytes (* 1024 1024)])
  manifest)

(define (make-test-updater root download
                           #:current-version [current-version "1.0.0"]
                           #:check-timeout [check-timeout 1.0]
                           #:stall-timeout [stall-timeout 1.0]
                           #:total-timeout [total-timeout 2.0]
                           #:component [component #f]
                           #:destination [destination #f]
                           #:after-download [after-download #f]
                           #:fetch [fetch fake-fetch])
  (parameterize ([current-managed-fetch-manifest fetch]
                 [current-managed-download download])
    (make-updater
     #:application-id "dev.rivet.managed-test"
     #:current-version current-version
     #:platform 'windows
     #:architecture 'x64
     #:install-kind 'portable
     #:component component
     #:public-key 'test-key
     #:key-id "test-2026"
     #:manifest-url "https://updates.example/update-stable.json"
     #:data-directory root
     #:destination destination
     #:after-download after-download
     #:rollout-bucket 17
     #:check-timeout check-timeout
     #:stall-timeout stall-timeout
     #:total-timeout total-timeout)))

(define root (make-temporary-file "rivet-managed-updater-~a" 'directory))

;; The managed surface accepts the explicit Linux tar.gz install kind that
;; the platform adapter can stage, so a tar.gz product never falls back to
;; the ZIP-only `portable` policy.
(check-true
 (updater?
  (make-updater
   #:application-id "dev.rivet.managed-test"
   #:current-version "1.0.0"
   #:platform 'linux
   #:architecture 'x64
   #:install-kind 'targz
   #:public-key 'test-key
   #:key-id "test-2026"
   #:manifest-url "https://updates.example/update-stable.json"
   #:data-directory root
   #:rollout-bucket 17)))
(check-exn exn:fail:contract?
           (lambda ()
             (make-updater
              #:application-id "dev.rivet.managed-test"
              #:current-version "1.0.0"
              #:platform 'linux
              #:architecture 'x64
              #:install-kind 'tarball
              #:public-key 'test-key
              #:key-id "test-2026"
              #:manifest-url "https://updates.example/update-stable.json"
              #:data-directory root
              #:rollout-bucket 17)))

(dynamic-wind
  void
  (lambda ()
    (define (successful-download _config _candidate destination
                                 #:on-progress on-progress
                                 #:progress-every progress-every)
      (check-equal? progress-every 1)
      (for ([downloaded (in-list '(0 50 100))])
        (on-progress downloaded))
      (make-parent-directory* destination)
      (call-with-output-file destination
        #:exists 'truncate/replace
        (lambda (out) (display "verified" out)))
      destination)
    (define successful (make-test-updater root successful-download))
    (check-false (updater-candidate successful))
    (define mutable-version (string-copy "1.0.0"))
    (define copied-input
      (make-test-updater root successful-download
                         #:current-version mutable-version))
    (string-set! mutable-version 0 #\9)
    (check-equal? (hash-ref (updater-state copied-input) 'currentVersion)
                  "1.0.0")
    (check-exn exn:fail:contract?
               (lambda ()
                 (make-updater
                  #:application-id "dev.rivet.invalid"
                  #:current-version "1.0.0"
                  #:platform 'freebsd
                  #:architecture 'x64
                  #:public-key 'test-key
                  #:key-id "test-2026"
                  #:manifest-url "https://updates.example/update.json"
                  #:data-directory root
                  #:rollout-bucket 1)))
    (check-exn exn:fail:contract?
               (lambda ()
                 (make-updater
                  #:application-id "dev.rivet.invalid"
                  #:current-version "1.0.0"
                  #:platform 'windows
                  #:architecture 'riscv64
                  #:public-key 'test-key
                  #:key-id "test-2026"
                  #:manifest-url "https://updates.example/update.json"
                  #:data-directory root
                  #:rollout-bucket 1)))
    (check-true (immutable? (updater-state successful)))
    (check-true
     (immutable? (hash-ref (updater-state successful) 'currentVersion)))
    (define available (updater-check! successful))
    (check-true (immutable? (hash-ref available 'availableVersion)))
    (check-true (immutable? (hash-ref available 'publishedAt)))
    (check-equal? (hash-ref available 'status) "available")
    (check-equal? (hash-ref available 'url)
                  "https://updates.example/app.zip")
    ;; The candidate accessor exposes the authenticated artifact for
    ;; products that own the native install handoff.
    (define selected (updater-candidate successful))
    (check-true (update-candidate? selected))
    (check-equal? (update-artifact-installer
                   (update-candidate-artifact selected))
                  'zip)
    (check-equal? (hash-ref (updater-state successful) 'phase) "available")
    (check-equal? (hash-ref (updater-state successful) 'availableVersion)
                  "2.0.0")
    (updater-download! successful)
    (define completed (updater-wait successful 2.0))
    (check-not-false completed)
    (check-equal? (hash-ref completed 'phase) "downloaded")
    (check-equal? (hash-ref completed 'percent) 100)
    (check-true (file-exists? (hash-ref completed 'downloadedPath)))
    (check-false (updater-cancel! successful))

    ;; Component selection and a product-controlled destination: payback's
    ;; feed carries the 'app component and names its own staging path.
    (define custom-destination
      (build-path root "custom" "component.zip"))
    (define component-updater
      (make-test-updater root successful-download #:fetch app-fetch
                         #:component 'app
                         #:destination (lambda (_candidate)
                                         custom-destination)))
    (define component-available (updater-check! component-updater))
    (check-equal? (hash-ref component-available 'status) "available")
    (check-equal? (hash-ref component-available 'url)
                  "https://updates.example/app-2.zip")
    (updater-download! component-updater)
    (define component-done (updater-wait component-updater 2.0))
    (check-not-false component-done)
    (check-equal? (hash-ref component-done 'phase) "downloaded")
    (check-equal? (hash-ref component-done 'downloadedPath)
                  (path->string custom-destination))
    (check-true (file-exists? custom-destination))
    (define wrong-component
      (make-test-updater root successful-download #:fetch app-fetch
                         #:component 'cli))
    (check-equal? (hash-ref (updater-check! wrong-component) 'status)
                  "up-to-date")

    ;; The after-download hook runs on the verified artifact before the
    ;; terminal phase and the path it returns is what the product observes
    ;; (the AppImage in-place swap contract).
    (define swap-staged (build-path root "swap-staged.bin"))
    (define swap-final (build-path root "swap-final.bin"))
    (define hook-arguments (box #f))
    (define hook-updater
      (make-test-updater root successful-download
                         #:destination (lambda (_candidate) swap-staged)
                         #:after-download
                         (lambda (path candidate)
                           (set-box! hook-arguments (cons path candidate))
                           (rename-file-or-directory path swap-final #t)
                           swap-final)))
    (check-equal? (hash-ref (updater-check! hook-updater) 'status) "available")
    (updater-download! hook-updater)
    (define hook-done (updater-wait hook-updater 2.0))
    (check-not-false hook-done)
    (check-equal? (hash-ref hook-done 'phase) "downloaded")
    (check-equal? (hash-ref hook-done 'downloadedPath)
                  (path->string swap-final))
    (check-true (file-exists? swap-final))
    (check-false (file-exists? swap-staged))
    (check-true (update-candidate? (cdr (unbox hook-arguments))))
    (check-equal? (path->string (car (unbox hook-arguments)))
                  (path->string swap-staged))

    ;; A failing install step must surface as the terminal error phase, not
    ;; a stuck download.
    (define failing-hook
      (make-test-updater root successful-download
                         #:after-download
                         (lambda (_path _candidate)
                           (error 'install "swap failed"))))
    (check-equal? (hash-ref (updater-check! failing-hook) 'status) "available")
    (updater-download! failing-hook)
    (define hook-failed (updater-wait failing-hook 2.0))
    (check-not-false hook-failed)
    (check-equal? (hash-ref hook-failed 'phase) "error")
    (check-regexp-match #rx"swap failed"
                        (hash-ref hook-failed 'message))

    ;; Only one operation owns an updater. Cancellation interrupts the worker
    ;; and produces a stable terminal state instead of leaking exn:break.
    (define cancel-started (make-semaphore 0))
    (define (blocking-download _config _candidate _destination
                               #:on-progress on-progress
                               #:progress-every _progress-every)
      (on-progress 0)
      (semaphore-post cancel-started)
      (sync never-evt))
    (define cancellable (make-test-updater root blocking-download))
    (check-equal? (hash-ref (updater-check! cancellable) 'status) "available")
    (updater-download! cancellable)
    (check-not-false (sync/timeout 2 cancel-started))
    (check-exn #rx"another updater operation"
               (lambda () (updater-download! cancellable)))
    (check-true (updater-cancel! cancellable))
    (define cancelled (updater-wait cancellable 2.0))
    (check-not-false cancelled)
    (check-equal? (hash-ref cancelled 'phase) "cancelled")
    (check-equal? (hash-ref cancelled 'message)
                  "update download cancelled")

    ;; A server that neither produces bytes nor closes cannot leave the state
    ;; machine permanently in "downloading".
    (define stalled
      (make-test-updater root blocking-download
                         #:stall-timeout 0.05
                         #:total-timeout 1.0))
    (check-equal? (hash-ref (updater-check! stalled) 'status) "available")
    (updater-download! stalled)
    (define timed-out (updater-wait stalled 2.0))
    (check-not-false timed-out)
    (check-equal? (hash-ref timed-out 'phase) "error")
    (check-equal? (hash-ref timed-out 'message) "update download stalled")

    ;; Manifest acquisition has its own deadline; download watchdogs do not
    ;; help when a server stalls before selection begins.
    (define (blocking-fetch _url _key
                            #:key-id [_key-id #f]
                    #:trusted-keys [_trusted-keys #f]
                            #:maximum-bytes [_maximum-bytes (* 1024 1024)])
      (sync never-evt))
    (define check-bounded
      (make-test-updater root successful-download
                         #:check-timeout 0.05
                         #:fetch blocking-fetch))
    (define check-error (updater-check! check-bounded))
    (check-equal? (hash-ref check-error 'status) "error")
    (check-regexp-match #rx"deadline" (hash-ref check-error 'message))
    (check-equal? (hash-ref (updater-state check-bounded) 'phase) "error")

    ;; Breaking a synchronous check must also terminate its owned fetch
    ;; thread; otherwise an abandoned network request survives the caller.
    (define fetch-started (make-semaphore 0))
    (define fetch-stopped (make-semaphore 0))
    (define (interruptible-fetch _url _key
                                 #:key-id [_key-id #f]
                    #:trusted-keys [_trusted-keys #f]
                                 #:maximum-bytes [_maximum-bytes (* 1024 1024)])
      (dynamic-wind
        (lambda () (semaphore-post fetch-started))
        (lambda () (sync never-evt))
        (lambda () (semaphore-post fetch-stopped))))
    (define interrupted
      (make-test-updater root successful-download
                         #:check-timeout 10.0
                         #:fetch interruptible-fetch))
    (define checking-thread
      (thread
       (lambda ()
         (with-handlers ([exn:break? void])
           (updater-check! interrupted)))))
    (check-not-false (sync/timeout 2 fetch-started))
    (break-thread checking-thread)
    (check-not-false (sync/timeout 2 (thread-dead-evt checking-thread)))
    (check-not-false (sync/timeout 2 fetch-stopped))
    (check-equal? (hash-ref (updater-state interrupted) 'phase) "error"))
  (lambda () (delete-directory/files root)))
