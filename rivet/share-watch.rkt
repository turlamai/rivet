#lang racket/base

;; Network-share reachability and scanning for Windows products.
;;
;; Racket CS runs every Racket thread on one OS thread, so one blocking SMB
;; call on a mapped share stuck in "Reconnecting" freezes the whole engine:
;; every RPC stops answering and a hard timeout cannot rescue a thread parked
;; inside a win32 syscall. Two rules keep share-backed work safe:
;;
;;   * Reachability comes from the redirector's state table. Parameterless
;;     `net use` answers from local state in a few hundred milliseconds even
;;     while the share is dead; `net use Z:` talks to the server and hangs.
;;   * Directory scans run in a `place` (its own OS thread and engine). The
;;     engine waits on the place channel with a timeout and kills the worker;
;;     a stalled share can stall only the worker.
;;
;; A product gates share work on `share-reachable?`, reads directories with
;; `share-directory-snapshot` instead of `directory-list`, and can poll
;; changes with `start-share-watcher`. Local paths and UNC paths without a
;; mapped drive keep their ordinary filesystem behavior; the place timeout is
;; the only reachability signal for a dead UNC share.

(require racket/async-channel
         racket/list
         racket/match
         racket/path
         racket/place
         "private/share-scan-place.rkt"
         "private/share-state-table.rkt")

(provide (struct-out share-entry)
         (struct-out share-state)
         share-state-ok?
         mapped-drive-status
         share-reachable?
         share-directory-snapshot
         start-share-watcher
         share-watcher?
         share-watcher-state
         share-watcher-stop!)

(struct share-entry (name path directory? size modify-seconds) #:transparent)
(struct share-state (status entries) #:transparent)

;; Test seam: the timeout test substitutes a worker that never replies.
(define current-share-scan-worker
  (make-parameter 'rivet/private/share-scan-place))

(define (share-state-ok? state)
  (eq? (share-state-status state) 'ok))

;; Synchronous convenience for startup checks and `raco rivet doctor`. It runs
;; the parameterless enumeration on the engine thread, which is bounded but
;; still a park of a few hundred milliseconds: hot paths belong in
;; `share-directory-snapshot`, whose probe runs inside the place.
(define (mapped-drive-status path)
  (status-for-path path))

(define (share-reachable? path)
  (and (memq (mapped-drive-status path) '(ok not-mapped unknown)) #t))

(define (reply->state root reply)
  (match reply
    [(vector 'ok entries)
     (share-state
      'ok
      (for/vector ([entry (in-vector entries)])
        (match-define (vector name directory? size modify-seconds) entry)
        (share-entry name (build-path root name) directory? size modify-seconds)))]
    [(vector 'unreachable _status)
     (share-state 'unreachable (vector))]
    [(vector 'missing)
     (share-state 'missing (vector))]
    [(vector 'error _message)
     (share-state 'error (vector))]
    [_ (share-state 'error (vector))]))

(define (share-directory-snapshot path #:timeout [timeout 5.0])
  (define root (path->complete-path path))
  (cond
    [(not (place-enabled?))
     (share-state 'unsupported (vector))]
    [else
     (define worker (dynamic-place (current-share-scan-worker) 'main))
     (place-channel-put worker (vector 'scan (path->string root)))
     (define reply (sync/timeout timeout worker))
     (cond
       [(not reply)
        (place-kill worker)
        (share-state 'timeout (vector))]
       [else
        ;; The worker sends one reply and returns; waiting here only joins
        ;; the place's cleanup, it does not wait on the share.
        (place-wait worker)
        (reply->state root reply)])]))

(struct share-watcher (path interval timeout on-change thread stop-channel state)
  #:transparent
  #:mutable)

;; Polls the share and calls `on-change` with the new state whenever the
;; status or the entry set changes. The initial scan always reports, so a
;; consumer can render its first health state from the callback.
(define (start-share-watcher path
                             #:interval [interval 5.0]
                             #:timeout [timeout 5.0]
                             #:on-change [on-change void])
  (define stop-channel (make-async-channel))
  (define watcher
    (share-watcher path interval timeout on-change #f stop-channel
                   (share-state 'unknown (vector))))
  (define (loop previous)
    (define state (share-directory-snapshot path #:timeout timeout))
    (define changed?
      (or (not previous)
          (not (eq? (share-state-status state) (share-state-status previous)))
          (not (equal? (share-state-entries state) (share-state-entries previous)))))
    (set-share-watcher-state! watcher state)
    (when changed?
      (with-handlers ([exn:fail?
                       (lambda (error)
                         (eprintf "rivet/share-watch: change callback failed: ~a\n"
                                  (exn-message error)))])
        (on-change state)))
    (unless (sync/timeout interval stop-channel)
      (loop state)))
  (set-share-watcher-thread! watcher (thread (lambda () (loop #f))))
  watcher)

(define (share-watcher-stop! watcher)
  (define worker-thread (share-watcher-thread watcher))
  (when worker-thread
    (async-channel-put (share-watcher-stop-channel watcher) 'stop)
    ;; A callback that stops its own watcher must not wait on itself.
    (unless (eq? (current-thread) worker-thread)
      (unless (sync/timeout 1 worker-thread)
        (kill-thread worker-thread)))
    (set-share-watcher-thread! watcher #f))
  (void))

(module+ test-support
  (provide current-share-scan-worker))
