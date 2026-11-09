#lang racket/base

(require json
         net/http-client
         net/url
         racket/file
         racket/match
         racket/path
         racket/port
         racket/string
         "crypto.rkt"
         "manifest.rkt"
         "version.rkt")

(provide (struct-out updater-config)
         (struct-out update-candidate)
         (struct-out install-plan)
         fetch-update-manifest
         fetch-sibling-asset
         select-update
         download-update
         verify-update-artifact!
         make-install-plan
         execute-install-plan!
         recover-install-plan!)

(struct updater-config
  (application-id current-version channel platform architecture
                  public-key expected-key-id rollout-bucket maximum-download-bytes
                  component)
  #:transparent)

(struct update-candidate (manifest artifact) #:transparent)
(struct install-plan (candidate downloaded-path backup-path install restart rollback) #:transparent)

(define install-journal-schema 1)
(define install-journal-phases
  '(prepared installing installed restarting restarted checking healthy
             committing committed rollback-started rolled-back rollback-failed))

(define (wait-for-download-bytes! in buffer
                                  #:stall-seconds stall-seconds
                                  #:total-deadline total-deadline)
  ;; Blocks until at least one byte is available, the peer reaches EOF, the
  ;; stall deadline passes, or the total deadline fires. Returns the byte
  ;; count, eof, 'stall, or 'total respectively.
  ;; handle-evt normalizes the peek completion to a single value regardless
  ;; of how many values the underlying event produces.
  (define ready
    (sync/timeout stall-seconds
                  (handle-evt
                   (peek-bytes-avail!-evt (make-bytes 4) 0 #f in)
                   (lambda (_peeked) 'ready))
                  total-deadline))
  (cond
    [(not ready) 'stall]
    [(eq? ready total-deadline) 'total]
    [else
     (define count (read-bytes-avail! buffer in))
     count]))

(define (copy-limited! in out limit
                       #:who [who 'copy-limited!]
                       #:on-progress [on-progress void]
                       #:progress-every [progress-every 1]
                       #:stall-seconds [stall-seconds 60]
                       #:total-seconds [total-seconds #f])
  ;; Report the initial zero and the final byte count. Intermediate reports are
  ;; separated by at least progress-every bytes so fast links do not flood UI
  ;; pollers. This helper stays private; download-update is the public contract.
  ;; A stalled peer (no bytes for stall-seconds) and an optional total deadline
  ;; raise instead of parking the backend serve thread forever.
  (unless (and (real? stall-seconds) (> stall-seconds 0))
    (raise-argument-error who "positive real?" stall-seconds))
  (unless (or (not total-seconds) (and (real? total-seconds) (> total-seconds 0)))
    (raise-argument-error who "(or/c #f positive real?)" total-seconds))
  (define buffer (make-bytes 65536))
  (define total-deadline
    (and total-seconds
         (alarm-evt (+ (current-inexact-milliseconds) (* total-seconds 1000)))))
  (on-progress 0)
  (let loop ([total 0] [last-reported 0])
    (define count
      (wait-for-download-bytes! in buffer
                                #:stall-seconds stall-seconds
                                #:total-deadline
                                (or total-deadline never-evt)))
    (cond
      [(eq? count 'stall)
       (error who "download stalled: no bytes for ~a seconds" stall-seconds)]
      [(eq? count 'total)
       (error who "download exceeded its ~a second total deadline" total-seconds)]
      [(eof-object? count)
       (unless (= last-reported total) (on-progress total))
       total]
      [else
       (define next (+ total count))
       (when (> next limit)
         (error who "response exceeds permitted byte limit"))
       (write-bytes buffer out 0 count)
       (when (>= (- next last-reported) progress-every)
         (on-progress next)
         (set! last-reported next))
       (loop next last-reported)])))

(define (call-with-partial-cleanup temporary thunk)
  (with-handlers ([exn?
                   (lambda (error)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise error))])
    (thunk)))

(module+ test
  (provide copy-limited!
           call-with-partial-cleanup
           call-with-fetch-deadline
           call-with-update-response
           html-error-response?
           header-content-length
           header-field
           require-successful-response!
           status-of))

;; GitHub release assets — the dominant update origin — answer with a 302
;; to their CDN, so every fetch must follow redirections or the updater
;; verifies an empty body and fails.
(define update-fetch-redirections 10)

(define update-fetch-connect-timeout-seconds 30)
(define update-fetch-idle-timeout-seconds 60)

;; Header predicates work on the flat header block the transport yields
;; (fields joined with CRLF). An HTML error page (the shape GitHub's CDN
;; returns on 502/504) must never reach the JSON/signature parser, and its
;; `Content-Length` is still useful for bounded reads.
(define (html-error-response? headers)
  (and (string? headers)
       (regexp-match? #rx"(?i:content-type:[ \t]*text/html)" headers)))

(define (header-content-length headers)
  (define match
    (and (string? headers)
         (regexp-match #rx"(?im:^content-length:[ \t]*([0-9]+)[ \t]*\r?$)"
                       headers)))
  (and match (string->number (list-ref match 1))))

;; `get-pure-port/headers` hides the response's status line — the
;; http-client consumes it — which is why a gateway error body could pass
;; the HTML sniff above and only fail later as a misleading size/SHA
;; mismatch (#435: GitHub's release CDN answered a 504 with a 92-byte HTML
;; page while the asset itself was intact). The transport below speaks to
;; `net/http-client` directly, where every hop's numeric status is
;; visible, and follows redirects by hand with the same hop budget
;; net/url's `#:redirections` used to provide. The keyword itself stays
;; off the public contracts; doctor's negative test relies on that.
(define (status-of status-line)
  ;; Three literal digit classes: Racket's regexp language rejects the
  ;; counted-repetition spellings ({3} is literal, **{3} is a reader
  ;; error), so explicitness beats cleverness here.
  (define match
    (regexp-match #rx"^HTTP/[0-9.]+[ \t]+([0-9][0-9][0-9])"
                  (bytes->string/latin-1 status-line)))
  (and match (string->number (list-ref match 1))))

(define (headers-string fields)
  (string-join
   (for/list ([field (in-list fields)]) (bytes->string/latin-1 field))
   "\r\n"))

(define (header-field headers name)
  (define match
    (regexp-match
     (pregexp (string-append "(?im:^" (regexp-quote name)
                             ":[ \t]*(.*?)[ \t]*\r?$)"))
     headers))
  (and match (list-ref match 1)))

;; 2xx is the only answer whose body may be trusted. Everything else —
;; gateway HTML, a proxy's plain-text error, an unparseable status — is
;; refused before the body is handed to any caller, so callers retry a
;; transient 5xx instead of diagnosing a "corrupted" artifact.
(define (require-successful-response! who status headers url)
  (unless (and (exact-nonnegative-integer? status)
               (<= 200 status 299))
    (error who "request for ~a failed: HTTP ~a" url (or status "unknown")))
  (when (html-error-response? headers)
    (error who "request for ~a returned an HTML error page" url)))

;; path?query exactly as written: clearing the authority fields from the
;; url struct keeps the original percent-encoding intact.
(define (request-target u)
  (url->string (struct-copy url u
                            [scheme #f] [host #f]
                            [port #f] [user #f])))

;; A Location header may be protocol-relative or path-only; scheme, host
;; and port default to the hop that produced it.
(define (resolved-redirect base-u location)
  (define loc (string->url location))
  (struct-copy url loc
               [scheme (or (url-scheme loc) (url-scheme base-u))]
               [host (or (url-host loc) (url-host base-u))]
               [port (or (url-port loc) (url-port base-u))]))

;; GETs url-string and hands the final response to receive as
;; (values status headers body-in). Each hop opens its own connection;
;; redirect responses are closed before the next hop, and the final body
;; and connection close after receive returns or raises.
(define (call-with-update-response who url-string receive
                                   #:redirections
                                   [redirections update-fetch-redirections])
  (let follow ([u (string->url url-string)] [hops-left redirections])
    (define scheme-name (url-scheme u))
    (unless (member scheme-name '("http" "https"))
      (error who "update fetch refuses the ~a scheme: ~a"
             (or scheme-name "schemeless") (url->string u)))
    (define conn
      (http-conn-open (url-host u)
                      #:port (or (url-port u)
                                 (if (string=? scheme-name "https")
                                     443
                                     80))
                      #:ssl? (string=? scheme-name "https")))
    (define-values (status-line fields body-in)
      (http-conn-sendrecv! conn (request-target u)
                           #:headers '("User-Agent: Rivet-Updater/1")))
    (define status (status-of status-line))
    (define headers (headers-string fields))
    (cond
      [(and (memv status '(301 302 303 307 308)) (positive? hops-left))
       (define location (header-field headers "Location"))
       (close-input-port body-in)
       (http-conn-close! conn)
       (unless (string? location)
         (error who
                "redirect without a Location header: HTTP ~a for ~a"
                (or status "unknown") (url->string u)))
       (follow (resolved-redirect u location) (sub1 hops-left))]
      [(memv status '(301 302 303 307 308))
       (close-input-port body-in)
       (http-conn-close! conn)
       (error who
              "update fetch exceeded its ~a hop redirect limit following ~a"
              redirections url-string)]
      [else
       (dynamic-wind
         void
         (lambda ()
           (require-successful-response!
            who status headers (url->string u))
           (receive status headers body-in))
         (lambda ()
           (close-input-port body-in)
           (http-conn-close! conn)))])))

;; get-pure-port blocks on the TCP connect with no interruptible event, so
;; the whole fetch runs in a custodian-owned worker and a deadline past
;; connect + idle shutdowns the worker and its socket instead of parking the
;; backend serve thread on a black-holed peer.
(define (call-with-fetch-deadline who connect-seconds idle-seconds thunk)
  (define custodian (make-custodian))
  (define result-channel (make-channel))
  (define worker
    (parameterize ([current-custodian custodian])
      (thread
       (lambda ()
         (with-handlers ([exn? (lambda (error) (channel-put result-channel error))])
           (channel-put result-channel (thunk)))))))
  (define outcome
    (sync/timeout (+ connect-seconds idle-seconds) result-channel))
  (cond
    [(not outcome)
     (custodian-shutdown-all custodian)
     (error who
            "update fetch exceeded its ~a second deadline"
            (+ connect-seconds idle-seconds))]
    [else
     (custodian-shutdown-all custodian)
     (if (exn? outcome) (raise outcome) outcome)]))

(define (fetch-update-manifest manifest-url public-key
                               #:key-id [key-id #f]
                               #:trusted-keys [trusted-keys #f]
                               #:maximum-bytes [maximum-bytes (* 1024 1024)]
                               #:connect-timeout-seconds
                               [connect-timeout-seconds
                                update-fetch-connect-timeout-seconds]
                               #:idle-timeout-seconds
                               [idle-timeout-seconds
                                update-fetch-idle-timeout-seconds])
  (unless (and (string? manifest-url)
               (regexp-match? #px"^https://" manifest-url))
    (raise-argument-error 'fetch-update-manifest "HTTPS URL string" manifest-url))
  (unless (and (real? connect-timeout-seconds) (> connect-timeout-seconds 0))
    (raise-argument-error 'fetch-update-manifest "positive real?" connect-timeout-seconds))
  (unless (and (real? idle-timeout-seconds) (> idle-timeout-seconds 0))
    (raise-argument-error 'fetch-update-manifest "positive real?" idle-timeout-seconds))
  (define (fetch-once)
    (call-with-fetch-deadline
     'fetch-update-manifest connect-timeout-seconds idle-timeout-seconds
     (lambda ()
       (call-with-update-response
        'fetch-update-manifest manifest-url
        (lambda (status headers body-in)
          (define out (open-output-bytes))
          (copy-limited! body-in out maximum-bytes
                         #:who 'fetch-update-manifest
                         #:stall-seconds idle-timeout-seconds)
          (get-output-bytes out))))))
  ;; Transient CDN failures (502/504 HTML, dropped connections) are the
  ;; common case for release assets; retry the transport a few times before
  ;; failing. Signature and manifest validation stay outside the retry loop
  ;; so a verification failure is never masked by a retry.
  (define payload
    (let loop ([attempt 1])
      (with-handlers
          ([exn:fail?
            (lambda (error)
              (if (< attempt 3)
                  (begin (sleep (* 0.5 attempt)) (loop (add1 attempt)))
                  (raise error)))])
        (fetch-once))))
  (verify-signed-manifest (open-input-bytes payload)
                          public-key
                          #:key-id key-id
                          #:trusted-keys trusted-keys))

;; Release sidecars and sibling artifacts (sha256 files, extra installers)
;; live next to the update feed on the same host. Every private copy of
;; this helper skipped the HTTP status check, so a 404 page was saved as
;; the payload and only failed later with a misleading checksum error.
;; This shared helper fails fast instead: non-2xx statuses name the URL and
;; status, Content-Length mismatches are rejected, and the download runs
;; under the same deadlines as the manifest fetch.
(define (fetch-sibling-asset url destination
                             #:sha256 [expected-sha256 #f]
                             #:maximum-bytes [maximum-bytes (* 1024 1024 1024)]
                             #:on-progress [on-progress void]
                             #:connect-timeout-seconds
                             [connect-timeout-seconds
                              update-fetch-connect-timeout-seconds]
                             #:idle-timeout-seconds
                             [idle-timeout-seconds
                              update-fetch-idle-timeout-seconds])
  (unless (and (string? url) (regexp-match? #px"^https://" url))
    (raise-argument-error 'fetch-sibling-asset "HTTPS URL string" url))
  (unless (real? maximum-bytes)
    (raise-argument-error 'fetch-sibling-asset "real?" maximum-bytes))
  (call-with-fetch-deadline
   'fetch-sibling-asset connect-timeout-seconds idle-timeout-seconds
   (lambda ()
     (call-with-update-response
      'fetch-sibling-asset url
      (lambda (status headers body-in)
        (define content-length (header-content-length headers))
        (when (exact-positive-integer? content-length)
          (when (> content-length maximum-bytes)
            (error 'fetch-sibling-asset
                   "sibling asset declares ~a bytes beyond the ~a byte limit"
                   content-length maximum-bytes)))
        (make-parent-directory* destination)
        (define temporary (path-add-extension destination #".partial"))
        (when (file-exists? temporary) (delete-file temporary))
        (call-with-partial-cleanup
         temporary
         (lambda ()
           (call-with-output-file temporary
             #:exists 'truncate/replace
             #:mode 'binary
             (lambda (out)
               (copy-limited! body-in out maximum-bytes
                              #:who 'fetch-sibling-asset
                              #:on-progress on-progress
                              #:stall-seconds idle-timeout-seconds)))
           (when expected-sha256
             (define actual (sha256-file/hex temporary))
             (unless (string=? actual expected-sha256)
               (error 'fetch-sibling-asset
                      "sibling asset SHA-256 does not match the expected value"
                      "expected" expected-sha256
                      "actual" actual)))
           (rename-file-or-directory temporary destination #t)
           destination)))))))

;; `portable` is the policy class for any self-replacing tree, so it covers
;; both the portable ZIP and the Linux tar.gz feed shape a product may ship.
;; `targz` names that archive shape explicitly: an unpacked zip and an
;; unpacked tar.gz are the same directory tree to `current-install-kind`, so
;; only the product can say which payload its feed should prefer/force.
(define install-kinds '(portable targz msi appimage package-manager))

(define (artifact-matches-install-kind? artifact install-kind)
  (or (not install-kind)
      (case install-kind
        [(portable) (memq (update-artifact-installer artifact) '(zip targz))]
        [(targz) (eq? (update-artifact-installer artifact) 'targz)]
        [(msi) (eq? (update-artifact-installer artifact) 'msi)]
        [(appimage) (eq? (update-artifact-installer artifact) 'appimage)]
        [(package-manager)
         (and (memq (update-artifact-installer artifact) '(deb rpm)) #t)])))

(define (select-update config manifest #:install-kind [install-kind #f])
  (unless (or (not install-kind) (memq install-kind install-kinds))
    (raise-argument-error 'select-update
                          "(or/c #f 'portable 'targz 'msi 'appimage 'package-manager)"
                          install-kind))
  (cond
    [(not (string=? (updater-config-application-id config)
                    (update-manifest-application-id manifest)))
     (error 'select-update "update manifest application identity mismatch")]
    [(not (eq? (updater-config-channel config)
               (update-manifest-channel manifest))) #f]
    [(not (version>? (update-manifest-version manifest)
                     (updater-config-current-version config))) #f]
    [(version<? (updater-config-current-version config)
                (update-manifest-minimum-version manifest)) #f]
    [(>= (updater-config-rollout-bucket config)
         (update-manifest-rollout manifest)) #f]
    [else
     (define component (updater-config-component config))
     (define artifact
       (for/first ([item (in-list (update-manifest-artifacts manifest))]
                   #:when (and (eq? (update-artifact-platform item)
                                    (updater-config-platform config))
                               (eq? (update-artifact-architecture item)
                                    (updater-config-architecture config))
                               (eq? (update-artifact-component item) component)
                               (artifact-matches-install-kind? item install-kind)))
         item))
     (and artifact (update-candidate manifest artifact))]))

(define (verify-update-artifact! candidate path)
  (define artifact (update-candidate-artifact candidate))
  (unless (= (file-size path) (update-artifact-size artifact))
    (raise-arguments-error 'verify-update-artifact!
                           "download size does not match signed manifest"
                           "expected" (update-artifact-size artifact)
                           "actual" (file-size path)))
  (define actual (string-downcase (sha256-file/hex path)))
  (unless (string=? actual (update-artifact-sha256 artifact))
    (raise-arguments-error 'verify-update-artifact!
                           "download SHA-256 does not match signed manifest"
                           "expected" (update-artifact-sha256 artifact)
                           "actual" actual))
  path)

(define (download-update config candidate destination
                         #:on-progress [on-progress void]
                         #:progress-every [configured-progress-every #f]
                         #:stall-timeout-seconds [stall-timeout-seconds 60]
                         #:total-timeout-seconds [total-timeout-seconds #f])
  (unless (and (procedure? on-progress)
               (procedure-arity-includes? on-progress 1))
    (raise-argument-error 'download-update
                          "procedure accepting one argument"
                          on-progress))
  (unless (and (real? stall-timeout-seconds) (> stall-timeout-seconds 0))
    (raise-argument-error 'download-update
                          "positive real?"
                          stall-timeout-seconds))
  (unless (or (not total-timeout-seconds)
              (and (real? total-timeout-seconds) (> total-timeout-seconds 0)))
    (raise-argument-error 'download-update
                          "(or/c #f positive real?)"
                          total-timeout-seconds))
  (unless (or (not configured-progress-every)
              (exact-positive-integer? configured-progress-every))
    (raise-argument-error 'download-update
                          "(or/c #f exact-positive-integer?)"
                          configured-progress-every))
  (define artifact (update-candidate-artifact candidate))
  (define maximum (updater-config-maximum-download-bytes config))
  (when (> (update-artifact-size artifact) maximum)
    (error 'download-update "signed artifact size exceeds configured download limit"))
  (make-parent-directory* destination)
  (define temporary (path-add-extension destination #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (call-with-partial-cleanup
   temporary
   (lambda ()
     (call-with-update-response
      'download-update (update-artifact-url artifact)
      (lambda (status headers body-in)
        (call-with-output-file temporary
          #:exists 'truncate/replace
          #:mode 'binary
          (lambda (out)
            ;; Bound the stream to the signed size, not merely the looser
            ;; configured ceiling, so progress never exceeds 100% before a
            ;; malformed response is rejected.
            (copy-limited! body-in out (update-artifact-size artifact)
                           #:who 'download-update
                           #:on-progress on-progress
                           #:progress-every
                           (or configured-progress-every
                               (max 1
                                    (quotient
                                     (update-artifact-size artifact)
                                     100)))
                           #:stall-seconds stall-timeout-seconds
                           #:total-seconds total-timeout-seconds)))))
     (verify-update-artifact! candidate temporary)
     (rename-file-or-directory temporary destination #t)
     destination)))

(define (make-install-plan candidate downloaded-path
                           #:backup-path [backup-path #f]
                           #:install install
                           #:restart [restart void]
                           #:rollback [rollback void])
  (install-plan candidate downloaded-path backup-path install restart rollback))

(define (normalized-path-string path)
  (path->string (simplify-path (path->complete-path path) #f)))

(define (install-journal-record plan phase)
  (define candidate (install-plan-candidate plan))
  (define manifest (update-candidate-manifest candidate))
  (define artifact (update-candidate-artifact candidate))
  (hasheq 'schema install-journal-schema
          'application_id (update-manifest-application-id manifest)
          'version (update-manifest-version manifest)
          'artifact_sha256 (update-artifact-sha256 artifact)
          'downloaded_path
          (normalized-path-string (install-plan-downloaded-path plan))
          'backup_path
          (and (install-plan-backup-path plan)
               (normalized-path-string (install-plan-backup-path plan)))
          'phase (symbol->string phase)))

(define (write-install-journal! path record)
  (make-parent-directory* path)
  (define temporary (path-add-extension path #".partial"))
  (when (file-exists? temporary) (delete-file temporary))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise e))])
    (call-with-output-file temporary
      #:exists 'truncate/replace
      (lambda (out)
        (write-json record out)
        (newline out)
        (flush-output out)))
    (rename-file-or-directory temporary path #t)))

(define (read-install-journal path)
  (unless (file-exists? path)
    (raise-arguments-error 'recover-install-plan!
                           "install transaction journal does not exist"
                           "journal" path))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (raise-arguments-error
                      'recover-install-plan!
                      "install transaction journal is malformed"
                      "journal" path
                      "detail" (exn-message e)))])
    (call-with-input-file path read-json)))

(define (journal-phase record)
  (define value (and (hash? record) (hash-ref record 'phase #f)))
  (define phase (and (string? value) (string->symbol value)))
  (and (memq phase install-journal-phases) phase))

(define (journal-matches-plan? record plan)
  (and (hash? record)
       (equal? (hash-ref record 'schema #f) install-journal-schema)
       (equal? record
               (install-journal-record plan (journal-phase record)))))

(define (delete-install-journal! path)
  (when (file-exists? path) (delete-file path)))

(define (record-install-phase! plan journal-path phase)
  (when journal-path
    (write-install-journal! journal-path
                            (install-journal-record plan phase))))

(define (rollback-allowed? plan)
  (update-manifest-rollback-allowed?
   (update-candidate-manifest (install-plan-candidate plan))))

(define (rollback-after-failure! plan journal-path original-error)
  (when (rollback-allowed? plan)
    (record-install-phase! plan journal-path 'rollback-started)
    (with-handlers
        ([exn:fail?
          (lambda (rollback-error)
            (record-install-phase! plan journal-path 'rollback-failed)
            (raise
             (exn:fail
              (format "~a; rollback also failed: ~a"
                      (exn-message original-error)
                      (exn-message rollback-error))
              (exn-continuation-marks original-error))))])
      ((install-plan-rollback plan)))
    (record-install-phase! plan journal-path 'rolled-back)
    (when journal-path (delete-install-journal! journal-path)))
  (raise original-error))

(define (execute-install-plan! plan
                               #:health-check [health-check (lambda () #t)]
                               #:commit [commit void]
                               #:journal-path [journal-path #f])
  ;; Platform adapters own elevation and process replacement. Rivet controls
  ;; the verified input, durable phase journal, health gate, and failure path,
  ;; keeping this state machine out of RVT1 and away from the embedded runtime
  ;; transport. A restart callback must return after starting the replacement;
  ;; the health check decides when that replacement is ready to commit.
  (record-install-phase! plan journal-path 'prepared)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (rollback-after-failure! plan journal-path e))])
    (record-install-phase! plan journal-path 'installing)
    ((install-plan-install plan) (install-plan-downloaded-path plan))
    (record-install-phase! plan journal-path 'installed)
    (record-install-phase! plan journal-path 'restarting)
    (define restart-result ((install-plan-restart plan)))
    (record-install-phase! plan journal-path 'restarted)
    (record-install-phase! plan journal-path 'checking)
    (unless (health-check)
      (error 'execute-install-plan! "installed update failed its health check"))
    (record-install-phase! plan journal-path 'healthy)
    (record-install-phase! plan journal-path 'committing)
    (commit)
    (record-install-phase! plan journal-path 'committed)
    (when journal-path (delete-install-journal! journal-path))
    restart-result))

(define (recover-install-plan! plan journal-path #:commit [commit void])
  ;; Recovery is deliberately conservative: a journal describes one exact
  ;; signed candidate and its paths. A different plan cannot consume it.
  ;; Rollback callbacks must be idempotent because a process may stop after the
  ;; rollback side effect but before the final phase is durably recorded.
  (define record (read-install-journal journal-path))
  (define phase (journal-phase record))
  (unless (and phase (journal-matches-plan? record plan))
    (raise-arguments-error 'recover-install-plan!
                           "install transaction journal does not match the plan"
                           "journal" journal-path))
  (case phase
    [(healthy committing)
     ;; The health gate passed before either phase was written. Commit must be
     ;; idempotent because recovery may repeat it after the side effect but
     ;; before the final phase reaches disk.
     (record-install-phase! plan journal-path 'committing)
     (commit)
     (record-install-phase! plan journal-path 'committed)
     (delete-install-journal! journal-path)
     'committed]
    [(committed)
     (delete-install-journal! journal-path)
     'committed]
    [(rolled-back)
     (delete-install-journal! journal-path)
     'rolled-back]
    [else
     (unless (rollback-allowed? plan)
       (raise-arguments-error
        'recover-install-plan!
        "interrupted install cannot be rolled back by signed policy"
        "phase" phase
        "journal" journal-path))
     (record-install-phase! plan journal-path 'rollback-started)
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (record-install-phase! plan journal-path 'rollback-failed)
                        (raise e))])
       ((install-plan-rollback plan)))
     (record-install-phase! plan journal-path 'rolled-back)
     (delete-install-journal! journal-path)
     'rolled-back]))
