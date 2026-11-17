#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/string
         "../../rivet/share-watch.rkt"
         "../../rivet/private/share-state-table.rkt"
         "fixtures/hanging-place.rkt"
         (submod "../../rivet/share-watch.rkt" test-support))

;; --------------------------------------------- redirection state table

(define net-use-sample
  (string-join
   '("New connections will be remembered."
     ""
     "Status       Local     Remote                    Network"
     ""
     "-------------------------------------------------------------------------------"
     "OK           Z:        \\\\Server10\\Department     Microsoft Windows Network"
     "Reconnecting Y:        \\\\Server11\\Other          Microsoft Windows Network"
     "Unavailable  X:        \\\\Server12\\Archive        Microsoft Windows Network"
     "The command completed successfully.")
   "\n"))

(define table (parse-net-use net-use-sample))
(check-equal? (hash-ref table "Z:") 'ok)
(check-equal? (hash-ref table "Y:") 'reconnecting)
(check-equal? (hash-ref table "X:") 'unavailable)
(check-false (hash-has-key? table "Status"))
(check-false (hash-has-key? table "The"))

;; Only a case-insensitive OK is reachable; every other status backs off.
(check-equal? (parse-net-use "ok z: \\\\server\\share") (hash "Z:" 'ok))
(check-equal? (parse-net-use "Frozen Q: \\\\server\\share") (hash "Q:" 'other))

(check-equal? (drive-for-path (string->path "/tmp/example")) #f)
(when (eq? (system-type 'os) 'windows)
  (check-equal? (drive-for-path (string->path "Z:\\department")) "Z:"))
(check-equal? (status-for-path (string->path "/tmp/example") (hash)) 'not-mapped)

;; --------------------------------------------- directory snapshots

(define temp-root (make-temporary-file "rivet-share-watch-~a" 'directory))

(define (write-file path text)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display text out))))

(define (wait-until predicate)
  (let loop ([tries 0])
    (when (and (< tries 100) (not (predicate)))
      (sleep 0.05)
      (loop (add1 tries)))))

(dynamic-wind
 void
 (lambda ()
   (define events (box '()))
   (define watcher #f)

   (write-file (build-path temp-root "a.txt") "abc")
   (make-directory* (build-path temp-root "sub"))
   (define snapshot (share-directory-snapshot temp-root #:timeout 5))
   (check-equal? (share-state-status snapshot) 'ok)
   (check-true (share-state-ok? snapshot))
   (define entries (share-state-entries snapshot))
   (check-equal? (map share-entry-name (vector->list entries))
                 '("a.txt" "sub"))
   (check-equal? (map share-entry-directory? (vector->list entries))
                 '(#f #t))
   (check-equal? (share-entry-size (vector-ref entries 0)) 3)

   ;; A missing directory is a normal answer, not a scan failure.
   (check-equal?
    (share-state-status
     (share-directory-snapshot (build-path temp-root "absent")))
    'missing)

   ;; Local paths are not mapped drives and need no probe.
   (check-true (share-reachable? temp-root))

   ;; A worker that never replies must time out and be killed without
   ;; blocking the engine for the SMB timeout.
   (parameterize ([current-share-scan-worker 'rivet/tests/fixtures/hanging-place])
     (define started (current-inexact-milliseconds))
     (define timed-out (share-directory-snapshot temp-root #:timeout 0.3))
     (check-equal? (share-state-status timed-out) 'timeout)
     (check-true (< (- (current-inexact-milliseconds) started) 3000)))

   ;; The watcher reports the initial state and then a changed entry set.
   (set! watcher
         (start-share-watcher temp-root
                              #:interval 0.1
                              #:timeout 2
                              #:on-change
                              (lambda (state)
                                (set-box! events
                                          (cons (share-state-status state)
                                                (unbox events))))))
   (wait-until (lambda () (not (null? (unbox events)))))
   (check-not-false (memq 'ok (unbox events)))
   (write-file (build-path temp-root "b.txt") "d")
   (wait-until
    (lambda ()
      (= (vector-length
          (share-state-entries (share-watcher-state watcher)))
         3)))
   (check-equal? (vector-length
                  (share-state-entries (share-watcher-state watcher)))
                 3)
   (check-equal? (share-state-status (share-watcher-state watcher)) 'ok)
   (share-watcher-stop! watcher))
 (lambda ()
   (when (directory-exists? temp-root)
     (delete-directory/files temp-root))))
