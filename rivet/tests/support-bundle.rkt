#lang racket/base

;; The support bundle must be safe to share: local home paths and the user name
;; are redacted recursively, only explicitly named logs are included, log size
;; is bounded, and the ZIP carries a manifest the user can preview.

(require json
         racket/file
         racket/path
         racket/string
         rackunit
         file/unzip
         "../../rivet-cli/support.rkt")

(define root (make-temporary-file "rivet-support-test-~a" 'directory))
(define home (path->string (find-system-path 'home-dir)))
(define user (or (getenv "USER") (getenv "USERNAME") ""))

(dynamic-wind
  void
  (lambda ()
    (define log (build-path root "app.log"))
    (call-with-output-file log
      (lambda (out)
        (fprintf out "started in ~a\n" home)
        (fprintf out "user=~a\n" user)
        (display "line three\n" out)))
    (define output (build-path root "bundle.zip"))
    (define summary (support-bundle! #:output output #:logs (list log)))
    (check-true (file-exists? output))
    (check-equal? (hash-ref summary 'schema) "rivet.support-bundle.v1")
    (check-true (> (hash-ref summary 'redactions) 0))
    (check-not-false (member "logs/app.log"
                             (for/list ([entry (in-list (hash-ref summary 'entries))])
                               (hash-ref entry 'name))))

    (call-with-unzip
     output
     (lambda (extracted)
       (check-true (file-exists? (build-path extracted "doctor.json")))
       (check-true (file-exists? (build-path extracted "inspect.json")))
       (check-true (file-exists? (build-path extracted "manifest.json")))
       (define manifest
         (call-with-input-file (build-path extracted "manifest.json") read-json))
       (check-equal? (hash-ref manifest 'schema) "rivet.support-bundle.v1")
       (check-true (hash-has-key? manifest 'redactions))
       (define log-text
         (file->string (build-path extracted "logs" "app.log")))
       (check-false (string-contains? log-text home))
       (check-true (string-contains? log-text "~"))
       (when (>= (string-length user) 2)
         (check-false (string-contains? log-text user)))))

    ;; Missing and non-file logs are reported, not silently dropped.
    (define missing-summary
      (support-bundle! #:output (build-path root "missing.zip")
                       #:logs (list (build-path root "absent.log"))))
    (check-true (for/or ([note (in-list (hash-ref missing-summary 'notes))])
                  (string-contains? note "Log not found")))
    (check-true (for/or ([note (in-list (hash-ref missing-summary 'notes))])
                  (string-contains? note "No rivet.rktd")))

    ;; A bounded read marks the entry truncated.
    (define big-log (build-path root "big.log"))
    (call-with-output-file big-log
      (lambda (out) (display (make-string 500 #\z) out)))
    (define truncated-summary
      (support-bundle! #:output (build-path root "truncated.zip")
                       #:logs (list big-log)
                       #:max-log-bytes 100))
    (define entry
      (for/first ([item (in-list (hash-ref truncated-summary 'entries))]
                  #:when (equal? (hash-ref item 'name) "logs/big.log"))
        item))
    (check-true (hash-ref entry 'truncated))
    (check-equal? (hash-ref entry 'bytes) 100)

    ;; Output path validation and argument parsing.
    (define directory-target (build-path root "a-directory"))
    (make-directory* directory-target)
    (check-exn exn:fail:contract?
               (lambda () (support-bundle! #:output directory-target)))
    (define parsed (parse-support-arguments
                    (list "--output" (path->string output)
                          "--log" "a.log" "--log" "b.log" "--json")))
    (check-equal? (support-options-logs parsed)
                  (list (build-path "a.log") (build-path "b.log")))
    (check-true (support-options-json? parsed))
    (check-exn exn:fail:contract?
               (lambda () (parse-support-arguments (list "--bogus")))))
  (lambda () (delete-directory/files root)))
