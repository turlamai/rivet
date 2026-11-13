#lang racket/base

;; Scan worker for rivet/share-watch.
;;
;; A place has its own OS thread and Racket engine. A filesystem call that
;; parks on a dead SMB share therefore stalls only this worker; the engine
;; waits with a timeout and kills the place. The reply is plain data so it
;; crosses the place channel without serializable structs.

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/place
         "share-state-table.rkt")

(provide main)

(define directory-mode-mask #o170000)
(define directory-mode #o040000)

(define (stat-entry path name)
  (define stat (file-or-directory-stat path))
  (vector name
          (= directory-mode
             (bitwise-and (hash-ref stat 'mode) directory-mode-mask))
          (hash-ref stat 'size 0)
          (hash-ref stat 'modify-time-seconds 0)))

(define (scan path)
  (define status (status-for-path path))
  (cond
    [(not (memq status '(ok not-mapped unknown)))
     (vector 'unreachable status)]
    [(not (directory-exists? path))
     (vector 'missing)]
    [else
     ;; `directory-list` returns paths when it is given a path and strings
     ;; when it is given a string; normalize so the channel payload and the
     ;; sort are stable either way.
     (define names
       (sort (map path->string (directory-list path)) string<?))
     (vector 'ok
             (list->vector
              (for/list ([name (in-list names)])
                (stat-entry (build-path path name) name))))]))

(define (main channel)
  (match (place-channel-get channel)
    [(vector 'scan path)
     (place-channel-put
      channel
      (with-handlers ([exn:fail?
                       (lambda (error)
                         (vector 'error (exn-message error)))])
        (scan path)))]))
