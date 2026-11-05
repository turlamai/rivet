#lang racket/base

;; A support bundle is the one artifact a user can hand to a maintainer without
;; also handing over their home directory. It collects facts Rivet already
;; computes (doctor, inspect, version), plus explicitly named logs, and redacts
;; the local home path and user name recursively before writing a ZIP.

(require json
         racket/date
         racket/format
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         file/zip
         "doctor.rkt"
         "inspect.rkt"
         "project.rkt")

(provide parse-support-arguments
         (struct-out support-options)
         support-bundle!
         run-support-bundle)

(define bundle-schema "rivet.support-bundle.v1")
(define default-log-bytes (* 2 1024 1024))
(define maximum-total-log-bytes (* 8 1024 1024))

(struct support-options (output logs json?) #:transparent)

(define (default-support-name)
  (define now (seconds->date (current-seconds) #t))
  (format "rivet-support-~a~a~a-~a~a~a.zip"
          (date-year now)
          (~a (date-month now) #:min-width 2 #:pad-string "0")
          (~a (date-day now) #:min-width 2 #:pad-string "0")
          (~a (date-hour now) #:min-width 2 #:pad-string "0")
          (~a (date-minute now) #:min-width 2 #:pad-string "0")
          (~a (date-second now) #:min-width 2 #:pad-string "0")))

(define (parse-support-arguments arguments)
  (let loop ([remaining arguments] [output #f] [logs '()] [json? #f])
    (match remaining
      ['() (support-options (or output (build-path (current-directory)
                                                   (default-support-name)))
                            (reverse logs) json?)]
      [(list* "--output" value tail)
       (when output
         (raise-arguments-error 'support-bundle "--output may be given only once"))
       (loop tail (build-path value) logs json?)]
      [(list* "--log" value tail)
       (loop tail output (cons (build-path value) logs) json?)]
      [(list* "--json" tail) (loop tail output logs #t)]
      [(cons argument _)
       (raise-arguments-error 'support-bundle "unknown argument"
                              "argument" argument)])))

(define (redactor)
  (define home (path->string (find-system-path 'home-dir)))
  (define user (or (getenv "USER") (getenv "USERNAME") ""))
  (define count (box 0))
  (define (redact-string value)
    (define replaced
      (cond
        [(and (> (string-length home) 1) (string-contains? value home))
         (set-box! count (add1 (unbox count)))
         (string-replace value home "~")]
        [else value]))
    (if (and (>= (string-length user) 2)
             (string-contains? replaced user))
        (begin
          (set-box! count (add1 (unbox count)))
          (string-replace replaced user "<user>"))
        replaced))
  (define (walk value)
    (cond
      [(hash? value)
       (for/hash ([(key item) (in-hash value)])
         (values key (walk item)))]
      [(list? value) (map walk value)]
      [(string? value) (redact-string value)]
      [else value]))
  (values walk (lambda () (unbox count))))

(define (safe-report label thunk notes)
  (with-handlers ([exn:fail?
                   (lambda (error)
                     (set-box! notes
                               (cons (format "~a unavailable: ~a"
                                             label (exn-message error))
                                     (unbox notes)))
                     (hash 'available #f 'error (exn-message error)))])
    (hash 'available #t 'report (thunk))))

(define (support-bundle! #:output [output #f]
                         #:logs [logs '()]
                         #:max-log-bytes [max-log-bytes default-log-bytes])
  (unless (and (exact-positive-integer? max-log-bytes) (> max-log-bytes 0))
    (raise-argument-error 'support-bundle! "positive integer?" max-log-bytes))
  (define target (path->complete-path
                  (or output (build-path (current-directory) (default-support-name)))))
  (when (directory-exists? target)
    (raise-arguments-error 'support-bundle! "output path is a directory"
                           "path" target))
  (make-parent-directory* target)
  (define-values (redact redaction-count) (redactor))
  (define notes (box '()))
  (define workspace (make-temporary-file "rivet-support-~a" 'directory))
  (define (write-bundle-file name value)
    (define path (build-path workspace name))
    (make-parent-directory* path)
    (call-with-output-file path #:exists 'truncate/replace
      (lambda (out) (write-json value out) (newline out)))
    path)
  (dynamic-wind
    void
    (lambda ()
      (define doctor (safe-report "doctor" doctor-report notes))
      (define project
        (with-handlers ([exn:fail? (lambda (_) #f)]) (find-project)))
      (define inspect
        (if project
            (safe-report "inspect" (lambda () (project-report project)) notes)
            (begin
              (set-box! notes (cons "No rivet.rktd found; project inspection omitted." (unbox notes)))
              (hash 'available #f 'error "no project"))))
      (make-directory* (build-path workspace "logs"))
      (define doctor-path (write-bundle-file "doctor.json" (redact doctor)))
      (define inspect-path (write-bundle-file "inspect.json" (redact inspect)))
      (define log-entries '())
      (define total-bytes (box 0))
      (for ([source (in-list logs)])
        (define source-path (path->complete-path source))
        (cond
          [(not (file-exists? source-path))
           (set-box! notes (cons (format "Log not found: ~a" (file-name-from-path source-path))
                                (unbox notes)))]
          [(directory-exists? source-path)
           (set-box! notes (cons (format "Log is a directory: ~a"
                                        (file-name-from-path source-path))
                                (unbox notes)))]
          [(link-exists? source-path)
           (set-box! notes (cons (format "Log is a symbolic link: ~a"
                                        (file-name-from-path source-path))
                                (unbox notes)))]
          [else
           (define size (file-size source-path))
           (define budget
             (max 0 (min max-log-bytes
                         (- maximum-total-log-bytes (unbox total-bytes)))))
           (define take (min size budget))
           (define bytes
             (call-with-input-file source-path
               (lambda (in) (read-bytes take in))))
           (define name
             (let loop ([base (path->string (file-name-from-path source-path))]
                        [index 1])
               (define candidate
                 (if (= index 1) base (format "~a-~a" base index)))
               (if (file-exists? (build-path workspace "logs" candidate))
                   (loop base (add1 index))
                   candidate)))
           (define path (build-path workspace "logs" name))
           (make-parent-directory* path)
           (call-with-output-file path #:exists 'truncate/replace
             (lambda (out)
               (write-string (redact (bytes->string/utf-8 bytes #\uFFFD)) out)))
           (set-box! total-bytes (+ (unbox total-bytes) take))
           (set! log-entries
                 (cons (hash 'name (format "logs/~a" name)
                             'bytes take
                             'truncated (> size take))
                       log-entries))]))
      (define version (or (installed-rivet-release-version) "unreleased"))
      (define manifest
        (hash 'schema bundle-schema
              'created-at (date->string (current-date) #t)
              'rivet-version version
              'os (symbol->string (system-type 'os))
              'architecture (format "~a" (system-type 'arch))
              'entries
              (append
               (list (hash 'name "doctor.json" 'bytes (file-size doctor-path))
                     (hash 'name "inspect.json" 'bytes (file-size inspect-path)))
               (reverse log-entries))
              'redactions (redaction-count)
              'notes (reverse (unbox notes))))
      (define manifest-path (build-path workspace "manifest.json"))
      (call-with-output-file manifest-path #:exists 'truncate/replace
        (lambda (out) (write-json (redact manifest) out) (newline out)))
      (define partial (string->path (string-append (path->string target) ".partial")))
      (when (file-exists? partial) (delete-file partial))
      (parameterize ([current-directory workspace])
        (zip partial "doctor.json" "inspect.json" "manifest.json" "logs"))
      (when (file-exists? target) (delete-file target))
      (rename-file-or-directory partial target #t)
      (hash 'schema bundle-schema
            'path (path->string target)
            'rivet-version version
            'entries (hash-ref manifest 'entries)
            'redactions (redaction-count)
            'notes (hash-ref manifest 'notes)))
    (lambda () (delete-directory/files workspace #:must-exist? #f))))

(define (run-support-bundle arguments)
  (define options (parse-support-arguments arguments))
  (define summary
    (support-bundle! #:output (support-options-output options)
                     #:logs (support-options-logs options)))
  (if (support-options-json? options)
      (begin (write-json summary) (newline))
      (begin
        (printf "Rivet support bundle: ~a\n" (hash-ref summary 'path))
        (printf "  release: ~a\n" (hash-ref summary 'rivet-version))
        (printf "  entries: ~a\n" (length (hash-ref summary 'entries)))
        (printf "  redactions: ~a\n" (hash-ref summary 'redactions))
        (for ([note (in-list (hash-ref summary 'notes))])
          (printf "  note: ~a\n" note))
        (displayln "Review the ZIP before sharing it.")))
  0)
