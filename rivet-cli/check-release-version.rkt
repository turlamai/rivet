#lang racket/base

;; Release version preflight shared by every product. Products used to carry
;; a per-repo `check-release-version.sh`; the copies diverged on whether a
;; release candidate tag is allowed and which extra files must carry the
;; version. This command owns the common contract and lets a product list
;; extra carrier files declaratively.

(require json
         racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "project.rkt")

(provide parse-check-release-version-arguments
         run-check-release-version-command)

(define (parse-check-release-version-arguments arguments)
  (let loop ([remaining arguments]
             [options (hasheq)]
             [tag #f])
    (define (with key tail value)
      (if (hash-has-key? options key)
          (raise-arguments-error 'check-release-version
                                 (format "~a may be specified only once" key))
          (loop tail (hash-set options key value) tag)))
    (match remaining
      ['() (values tag options)]
      [(list* "--version-file" value tail)
       (with 'version-file tail value)]
      [(list* "--carrier" value tail)
       (loop tail
             (hash-update options 'carriers
                          (lambda (values) (cons value values))
                          '())
             tag)]
      [(list* "--allow-rc" tail) (loop tail
                                   (hash-set options 'allow-rc? #t) tag)]
      [(list* "--json" tail) (loop tail
                               (hash-set options 'json? #t) tag)]
      [(cons argument tail)
       (cond
         [(string-prefix? argument "--")
          (raise-arguments-error 'check-release-version
                                 "unknown argument" "argument" argument)]
         [tag
          (raise-arguments-error 'check-release-version
                                 "only one release tag may be given"
                                 "values" (list tag argument))]
         [else (loop tail options argument)])])))

(define (release-candidate-version? version candidate)
  (regexp-match?
   (pregexp (format "^~a-rc\\.[1-9][0-9]*$"
                    (regexp-quote version)))
   candidate))

(define (tag-version tag)
  (if (string-prefix? tag "v")
      (substring tag 1)
      tag))

(define (project-file project path)
  (define value (string->path path))
  (if (absolute-path? value)
      value
      (project-path project path)))

(define (run-check-release-version-command arguments)
  (define-values (tag options)
    (parse-check-release-version-arguments arguments))
  (define project
    (or (find-project)
        (raise-arguments-error
         'check-release-version
         "run inside a Rivet project (rivet.rktd was not found)")))
  (define version (project-version project))
  (define version-file
    (cond
      [(hash-ref options 'version-file #f)
       (project-file project (hash-ref options 'version-file))]
      [(file-exists? (project-path project "VERSION"))
       (project-path project "VERSION")]
      [else #f]))
  (define version-file-value
    (and version-file
         (string-trim (file->string version-file))))
  (when (and version-file-value (not (string=? version-file-value version)))
    (raise-arguments-error
     'check-release-version
     "the VERSION file does not match rivet.rktd"
     "version-file" version-file
     "file-value" version-file-value
     "project-version" version))
  (define tag-value (and tag (tag-version tag)))
  (when tag-value
    (define acceptable?
      (or (string=? tag-value version)
          (and (hash-ref options 'allow-rc? #f)
               (release-candidate-version? version tag-value))))
    (unless acceptable?
      (raise-arguments-error
       'check-release-version
       (if (hash-ref options 'allow-rc? #f)
           "the tag must be v<version> or v<version>-rc.N"
           "the tag must be v<version> (pass --allow-rc for release candidates)")
       "tag" tag
       "project-version" version)))
  (define carriers
    (for/list ([declared (in-list (reverse (hash-ref options 'carriers '())))])
      (define path (project-file project declared))
      (unless (file-exists? path)
        (raise-arguments-error
         'check-release-version
         "a declared carrier file does not exist"
         "carrier" path))
      (define text (file->string path))
      (unless (string-contains? text version)
        (raise-arguments-error
         'check-release-version
         "a declared carrier file does not contain the project version"
         "carrier" path
         "version" version))
      (hash 'path (path->string path) 'contains-version #t)))
  (define coverage
    (append (if version-file-value (list "VERSION") '())
            (if tag-value (list "tag") '())
            (if (pair? carriers)
                (list (format "~a carrier~a"
                              (length carriers)
                              (if (= (length carriers) 1) "" "s")))
                '())))
  (if (hash-ref options 'json? #f)
      (begin
        (write-json
         (hasheq 'version version
                 'tag (and tag tag-value)
                 'version-file
                 (and version-file (path->string version-file))
                 'carriers carriers)
         (current-output-port))
        (newline (current-output-port)))
      (printf "release preflight: version ~a is aligned~a\n"
              version
              (if (null? coverage)
                  ""
                  (format " (~a)" (string-join coverage " == ")))))
  version)
