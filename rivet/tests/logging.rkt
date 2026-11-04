#lang racket/base

;; The optional rotating file sink: bounded size, bounded archives, one JSON
;; object per line, and thread-safe appends. It must never be the reason an
;; application loses its log or crashes while logging.

(require json
         racket/file
         racket/list
         racket/path
         rackunit
         "../../rivet/system/logging.rkt")

(define root (make-temporary-file "rivet-logging-~a" 'directory))
(define (read-records path)
  (for/list ([line (in-list (file->lines path))])
    (string->jsexpr line)))

(dynamic-wind
  void
  (lambda ()
    ;; --- size rotation and retention --------------------------------------
    (define path (build-path root "app.log"))
    (define sink (make-rotating-log-sink path #:max-bytes 250 #:max-files 2))
    (for ([index (in-range 8)])
      (sink (hasheq 'seq index 'padding (make-string 80 #\x))))
    (check-true (file-exists? path))
    (check-true (file-exists? (string->path (format "~a.1" path))))
    (check-true (file-exists? (string->path (format "~a.2" path))))
    (check-false (file-exists? (string->path (format "~a.3" path))))
    (for ([file (in-list (list path
                               (string->path (format "~a.1" path))
                               (string->path (format "~a.2" path))))])
      (define records (read-records file))
      (check-true (pair? records))
      (for ([record (in-list records)])
        (check-true (hash-has-key? record 'seq))
        (check-true (hash-has-key? record 'padding))))
    (check-equal? (hash-ref (last (read-records path)) 'seq) 7)
    (check-true (<= (file-size path) 250))

    ;; --- concurrent appends never interleave a line ----------------------
    (define concurrent (build-path root "concurrent.log"))
    (define concurrent-sink
      (make-rotating-log-sink concurrent #:max-bytes (* 1024 1024) #:max-files 1))
    (define threads
      (for/list ([worker (in-range 4)])
        (thread
         (lambda ()
           (for ([index (in-range 25)])
             (concurrent-sink (hasheq 'worker worker 'index index)))))))
    (for ([worker (in-list threads)]) (thread-wait worker))
    (define records (read-records concurrent))
    (check-equal? (length records) 100)
    (check-equal? (length (remove-duplicates records)) 100)

    ;; --- the active file is private on Unix ------------------------------
    (unless (eq? (system-type 'os) 'windows)
      (check-equal? (file-or-directory-permissions path 'bits) #o600))

    ;; --- validation fails closed -----------------------------------------
    (check-exn exn:fail:contract?
               (lambda () (make-rotating-log-sink (build-path root "x")
                                                  #:max-bytes 10)))
    (check-exn exn:fail:contract?
               (lambda () (make-rotating-log-sink (build-path root "x")
                                                  #:max-files 0)))
    (define directory-path (build-path root "a-directory"))
    (make-directory* directory-path)
    (check-exn exn:fail:contract?
               (lambda () (make-rotating-log-sink directory-path))))
  (lambda () (delete-directory/files root)))
