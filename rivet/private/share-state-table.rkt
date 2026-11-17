#lang racket/base

;; Redirection state-table parsing for Windows mapped drives.
;;
;; `net use` with no arguments enumerates the session's mappings from local
;; state and answers in a few hundred milliseconds even while a share is stuck
;; in "Reconnecting". `net use <drive>` talks to the server and hangs exactly
;; like any other SMB call, so the probe must stay parameterless.
;;
;; Kept in a private module because the scan place runs the probe in its own
;; OS thread and must share this parser with the engine-side helper.

(require racket/match
         racket/path
         racket/string
         racket/system)

(provide net-use-executable
         net-use-table
         parse-net-use
         drive-for-path
         status-for-path)

;; The status column is the first token before the drive letter. Treating
;; anything other than a case-insensitive "OK" as not reachable is deliberate:
;; it keeps working when a localized Windows translates the other status words,
;; and a false negative only makes the caller back off (the scan place remains
;; the authority on reachability).
(define (status-token->symbol token)
  (case (string-downcase token)
    [("ok") 'ok]
    [("reconnecting") 'reconnecting]
    [("unavailable") 'unavailable]
    [("disconnected") 'disconnected]
    [("connecting") 'connecting]
    [else 'other]))

(define drive-line-rx
  #px"^\\s*(\\S+)\\s+([A-Za-z]):(?:\\s+\\\\\\S+)?")

;; Returns a hash mapping "Z:"-style drive names to status symbols. Header
;; lines and the trailing "The command completed successfully." line do not
;; match because they carry no drive letter.
(define (parse-net-use text)
  (for/fold ([statuses (hash)]) ([line (in-list (string-split text "\n"))])
    (match (regexp-match drive-line-rx line)
      [(list _ token drive)
       (hash-set statuses
                 (string-append (string-upcase drive) ":")
                 (status-token->symbol token))]
      [#f statuses])))

(define (net-use-executable)
  (and (eq? (system-type 'os) 'windows)
       (let* ([root (getenv "SystemRoot")]
              [path (and root (build-path root "System32" "net.exe"))])
         (and path
              (file-exists? path)
              path))))

;; Runs the parameterless enumeration. Callers on hot paths should use the
;; scan place instead: even this bounded call parks the engine's single OS
;; thread until `net.exe` returns.
(define (net-use-table)
  (define executable (net-use-executable))
  (cond
    [(not executable) #f]
    [else
     (define out (open-output-string))
     (define err (open-output-string))
     (define status
       (parameterize ([current-output-port out]
                      [current-error-port err])
         (system*/exit-code executable "use")))
     ;; #f distinguishes "the probe itself failed" from a healthy empty
     ;; table, so a drive is not mistaken for a local path.
     (and (zero? status) (parse-net-use (get-output-string out)))]))

(define (drive-for-path path)
  (match (path->string (path->complete-path path))
    [(regexp #px"^([A-Za-z]):[\\\\/]" (list _ drive))
     (string-append (string-upcase drive) ":")]
    [else #f]))

(define (status-for-path path [table #f])
  (cond
    [(not (eq? (system-type 'os) 'windows)) 'not-mapped]
    [else
     (define absolute (path->string (path->complete-path path)))
     (cond
       ;; A UNC path is reached without a drive mapping, so the state table
       ;; has no entry for it. The scan place still decides reachability; a
       ;; dead UNC share parks only that place until the timeout.
       [(regexp-match? #px"^\\\\\\\\" absolute) 'unknown]
       [else
        (define drive (drive-for-path path))
        (cond
          [(not drive) 'not-mapped]
          [else
           (define statuses (or table (net-use-table)))
           (if statuses
               (hash-ref statuses drive 'not-mapped)
               ;; The state table was unreachable; the scan-place timeout is
               ;; the remaining guard rather than a false "local path".
               'unknown)])])]))
