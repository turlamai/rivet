#lang racket/base

(require json
         rackunit
         racket/file
         racket/port
         "../../rivet-cli/check-release-version.rkt")

(define temp-root (make-temporary-file "rivet-check-version-~a" 'directory))

(define (write-file path text)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display text out))))

(define (run-json . arguments)
  (parameterize ([current-directory temp-root])
    (string->jsexpr
     (with-output-to-string
       (lambda ()
         (run-check-release-version-command
          (append arguments (list "--json"))))))))

(define (run-raises? pattern . arguments)
  (check-exn
   pattern
   (lambda ()
     (parameterize ([current-directory temp-root])
       (parameterize ([current-output-port (open-output-nowhere)])
         (run-check-release-version-command arguments))))))

(dynamic-wind
 void
 (lambda ()
   (write-file
    (build-path temp-root "rivet.rktd")
    (format "~s"
            (hasheq 'name "Demo"
                    'version "1.2.3"
                    'build 7
                    'backend "app/backend.rkt"
                    'module "backend"
                    'entry "start"
                    'protocol 1)))
   (write-file (build-path temp-root "VERSION") "1.2.3\n")
   (write-file (build-path temp-root "app-version.rkt")
               "#lang racket/base\n(define version \"1.2.3\")\n")

   (define report (run-json))
   (check-equal? (hash-ref report 'version) "1.2.3")
   (check-equal? (hash-ref report 'tag) #f)
   (check-equal? (hash-ref report 'version-file)
                 (path->string (build-path temp-root "VERSION")))
   (check-equal? (hash-ref report 'carriers) '())

   (check-equal? (hash-ref (run-json "v1.2.3") 'tag) "1.2.3")
   (check-equal? (hash-ref (run-json "1.2.3") 'tag) "1.2.3")
   (run-raises? #rx"tag must be v<version>" "v1.2.4")

   ;; Release candidates are a product policy, not a default.
   (run-raises? #rx"tag must be v<version>" "v1.2.3-rc.1")
   (check-equal?
    (hash-ref (run-json "v1.2.3-rc.2" "--allow-rc") 'tag)
    "1.2.3-rc.2")
   (run-raises? #rx"tag must be v<version> or v<version>-rc.N"
                "v1.2.3-rc.0" "--allow-rc")

   ;; Extra carrier files are declared, not hard-coded per product.
   (define carrier-report
     (run-json "--carrier" "app-version.rkt"))
   (check-equal? (length (hash-ref carrier-report 'carriers)) 1)
   (check-true
    (hash-ref (car (hash-ref carrier-report 'carriers)) 'contains-version))
   (run-raises? #rx"does not exist"
                "--carrier" "VERSION.missing")
   (write-file (build-path temp-root "stale.rkt") "(define version \"0.9.0\")\n")
   (run-raises? #rx"does not contain the project version"
                "--carrier" "stale.rkt")

   ;; VERSION drift fails closed.
   (write-file (build-path temp-root "VERSION") "1.2.2\n")
   (run-raises? #rx"VERSION file does not match" )
   (write-file (build-path temp-root "VERSION") "1.2.3\n")
   (parameterize ([current-directory temp-root]
                  [current-output-port (open-output-nowhere)])
     (check-equal? (run-check-release-version-command '()) "1.2.3")))
 (lambda ()
   (when (directory-exists? temp-root)
     (delete-directory/files temp-root))))
