#lang racket/base

;; A generated project must carry a runnable three-platform CI contract, not
;; require the user to discover and copy docs/ci.md.

(require rackunit
         racket/file
         racket/path
         racket/string
         "../../rivet-cli/doctor.rkt"
         "../../rivet-cli/scaffold.rkt")

(define root (make-temporary-file "rivet-scaffold-ci-~a" 'directory))

(dynamic-wind
  void
  (lambda ()
    (define project (create-project! "CiDemo" root))
    (define workflow (build-path project ".github" "workflows" "native.yml"))
    (check-true (file-exists? workflow))
    (define text (file->string workflow))
    (for ([needle (in-list '("windows-latest"
                             "macos-latest"
                             "macos-15"
                             "ubuntu-24.04"
                             "raco rivet doctor"
                             "raco rivet schema check rivet-schema.json"
                             "raco rivet acceptance --json"
                             "setup-embed-racket"
                             "libgtk-4-dev"
                             "upload-artifact"))])
      (check-true (string-contains? text needle) needle))
    ;; The pin is the installed release tag, or the explicit `main` fallback.
    (check-regexp-match #px"rivet\\.git#(?:v[0-9]+\\.[0-9]+\\.[0-9]+|main)"
                        text)
    (define installed (installed-rivet-release-version))
    (when installed
      (check-true (string-contains? text (string-append "rivet.git#v" installed))))
    (define readme (file->string (build-path project "README.md")))
    (check-true (string-contains? readme ".github/workflows/native.yml"))
    (check-true (string-contains? readme "linux-icon"))

    ;; Every generated GTK4 app must use the product's own identity. A
    ;; hard-coded default GApplication ID allows one Rivet app to steal
    ;; another app's forwarded URL/file activations on the same session bus.
    (define linux-host
      (file->string (build-path project "linux" "src" "main.cpp")))
    (check-true
     (string-contains? linux-host
                       "gtk_application_new(rivet_app::kIdentifier")
     "generated Linux host must register its own product identity")
    (check-false
     (string-contains? linux-host "dev.rivet.host")
     "generated Linux host must not share a fixed default application ID")
    (for ([part (in-list '("G_APPLICATION_HANDLES_COMMAND_LINE"
                           "G_CALLBACK(on_command_line)"
                           "g_application_command_line_get_arguments"
                           "g_state.activations.push"))])
      (check-true (string-contains? linux-host part)
                  (format "generated Linux host must retain activation path: ~a"
                          part)))

    ;; A generated project must prove behavior, not only compile.
    (define smoke (build-path project "tests" "smoke.rkt"))
    (check-true (file-exists? smoke))
    (dynamic-require smoke #f)
    (define acceptance (file->string (build-path project "rivet-acceptance.rktd")))
    (check-true (string-contains? acceptance "(kind . unit)"))
    (check-true (string-contains? acceptance "\"raco\" \"test\" \"tests/\""))
    (check-true (string-contains? acceptance "starter-smoke")))
  (lambda () (delete-directory/files root)))
