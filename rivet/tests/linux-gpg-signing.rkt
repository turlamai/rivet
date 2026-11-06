#lang racket/base

;; Exercises the optional detached GPG sidecar used by Linux production
;; artifacts. Skipped when gpg is unavailable; CI Linux and the maintainer
;; macOS image provide it.

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         (submod "../../rivet-cli/installer.rkt" test-support)
         "../../rivet-cli/signing-options.rkt")

(define gpg (find-executable-path "gpg"))

(define (run! . args)
  (unless (apply system* args)
    (error 'linux-gpg-signing-test "command failed: ~a" args)))

(define (capture . args)
  (with-output-to-string (lambda () (apply system* args))))

(when (and gpg (directory-exists? "/tmp"))
  ;; gpg-agent's socket path fails under the long macOS temporary directory;
  ;; /tmp is short enough and present on the Linux CI image.
  (define home (build-path "/tmp" (format "rivet-gpg-home-~a" (random))))
  (make-directory home)
  (define artifact (make-temporary-file "rivet-gpg-artifact-~a"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file artifact
        #:exists 'truncate/replace
        (lambda (out) (display "rivet-gpg-artifact" out)))
      (run! gpg "--homedir" (path->string home)
            "--batch" "--pinentry-mode" "loopback" "--passphrase" ""
            "--quick-generate-key" "Rivet Test <rivet@example.invalid>"
            "ed25519" "sign" "0")
      (define fingerprint
        (for/first ([line (in-list (string-split
                                    (capture gpg "--homedir" (path->string home)
                                             "--batch" "--with-colons" "--list-keys")
                                    "\n"))]
                    #:when (string-prefix? line "fpr:"))
          (list-ref (string-split line ":") 9)))
      (check-true (string? fingerprint))
      (define settings (linux-gpg-signing fingerprint #f (path->string home)))
      (define signature (gpg-detach-sign! artifact settings))
      (check-true (file-exists? signature))
      (check-true (string-prefix?
                   (file->string signature)
                   "-----BEGIN PGP SIGNATURE-----"))
      (run! gpg "--homedir" (path->string home)
            "--batch" "--verify" (path->string signature) (path->string artifact)))
    (lambda ()
      (when (directory-exists? home) (delete-directory/files home))
      (when (file-exists? artifact) (delete-file artifact)))))
