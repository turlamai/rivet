#lang racket/base

(require json
         racket/date
         racket/file
         racket/path
         racket/port)

(provide current-rivet-log-sink
         current-rivet-crash-reporter
         rivet-log
         call-with-crash-reporting
         make-rotating-log-sink)

(define current-rivet-log-sink
  (make-parameter
   (lambda (record)
     (write-json record (current-error-port))
     (newline (current-error-port)))))

(define current-rivet-crash-reporter
  (make-parameter (lambda (record exception) (void record exception))))

(define (rivet-log level event #:fields [fields (hasheq)])
  (unless (memq level '(debug info warning error critical))
    (raise-argument-error 'rivet-log
                          "'debug, 'info, 'warning, 'error, or 'critical"
                          level))
  (unless (hash? fields)
    (raise-argument-error 'rivet-log "hash?" fields))
  (define record
    (hash-set*
     fields
     'timestamp (date->string (seconds->date (current-seconds) #t) #t)
     'level (symbol->string level)
     'event event))
  ((current-rivet-log-sink) record)
  record)

(define (call-with-crash-reporting thunk #:context [context (hasheq)])
  (with-handlers ([exn:fail?
                   (lambda (exception)
                     (define record
                       (rivet-log 'critical
                                  "unhandled-exception"
                                  #:fields
                                  (hash-set context 'message
                                            (exn-message exception))))
                     ((current-rivet-crash-reporter) record exception)
                     (raise exception))])
    (thunk)))

;; A commercial desktop app cannot ask a user to launch it from a terminal to
;; find a log. This sink is optional and explicit: the application chooses the
;; path (normally its platform Application Support directory), the byte budget
;; and how many archives to keep. Every record is one JSON object per line, so
;; the same records can be shipped to a support bundle or a crash reporter.
(define (make-rotating-log-sink path
                                #:max-bytes [max-bytes (* 5 1024 1024)]
                                #:max-files [max-files 3]
                                #:permissions [permissions #o600]
                                #:on-error [on-error void])
  (unless (path-string? path)
    (raise-argument-error 'make-rotating-log-sink "path-string?" path))
  (unless (and (exact-positive-integer? max-bytes)
               (>= max-bytes 64))
    (raise-arguments-error 'make-rotating-log-sink
                           "#:max-bytes must be an integer of at least 64"
                           "max-bytes" max-bytes))
  (unless (and (exact-positive-integer? max-files) (<= max-files 100))
    (raise-arguments-error 'make-rotating-log-sink
                           "#:max-files must be an integer from 1 through 100"
                           "max-files" max-files))
  (unless (and (exact-positive-integer? permissions)
               (<= permissions #o777))
    (raise-arguments-error 'make-rotating-log-sink
                           "#:permissions must be a Unix permission mask"
                           "permissions" permissions))
  (unless (procedure? on-error)
    (raise-argument-error 'make-rotating-log-sink "procedure?" on-error))
  (define complete (path->complete-path path))
  (when (directory-exists? complete)
    (raise-arguments-error 'make-rotating-log-sink
                           "log path is a directory"
                           "path" complete))
  (make-parent-directory* complete)
  (define lock (make-semaphore 1))
  (define (archive-path index)
    (string->path (format "~a.~a" (path->string complete) index)))
  (define (rotate!)
    ;; `.1` is the most recent archive; the oldest is deleted first.
    (for ([index (in-range (sub1 max-files) 0 -1)])
      (define from (archive-path index))
      (define to (archive-path (add1 index)))
      (when (file-exists? from)
        (rename-file-or-directory from to #t)))
    (when (file-exists? complete)
      (rename-file-or-directory complete (archive-path 1) #t)))
  (define (encoded-record record)
    (define out (open-output-bytes))
    (write-json record out)
    (newline out)
    (get-output-bytes out))
  (lambda (record)
    (unless (hash? record)
      (raise-argument-error 'rotating-log-sink "hash?" record))
    (define bytes (encoded-record record))
    (call-with-semaphore
     lock
     (lambda ()
       (with-handlers ([exn:fail? (lambda (error) (on-error error))])
         (define current-size
           (if (file-exists? complete) (file-size complete) 0))
         (when (and (> current-size 0)
                    (> (+ current-size (bytes-length bytes)) max-bytes))
           (rotate!))
         (call-with-output-file complete
           #:exists 'append
           (lambda (out)
             (write-bytes bytes out)
             (flush-output out)))
         (unless (eq? (system-type 'os) 'windows)
           (file-or-directory-permissions complete permissions)))))))
