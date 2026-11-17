#lang racket/base

(require rackunit
         racket/file
         racket/port
         racket/string
         "../../rivet/distribution/crypto.rkt"
         "../../rivet-cli/flatpak.rkt"
         "../../rivet-cli/project.rkt")

(define temp-root (make-temporary-file "rivet-flatpak-~a" 'directory))

(define (config #:identifier [identifier "dev.example.demo"]
                #:flatpak? [flatpak? #t]
                #:finish-args [finish-args '("--socket=x11" "--device=dri")]
                #:icon [icon "assets/icon.png"])
  (hasheq 'name "Demo"
          'version "2.3.4"
          'identifier identifier
          'linux-binary-name "demo"
          'linux-icon icon
          'linux-formats (if flatpak? '("flatpak") '())
          'flatpak-finish-args finish-args))

(define digests-available?
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (sha256-bytes #"")
    #t))

(dynamic-wind
 void
 (lambda ()
   ;; ------------------------------------------------ project validation

   (define config-path (build-path temp-root "rivet.rktd"))
   (call-with-output-file config-path #:exists 'truncate/replace
     (lambda (out)
       (write (hasheq 'name "demo"
                      'backend "app/backend.rkt"
                      'module "backend"
                      'entry "start"
                      'protocol 1
                      'linux-formats '("deb" "flatpak")
                      'flatpak-finish-args '("--socket=x11" "--device=dri")
                      'flatpak-manifest "packaging/demo.yml")
              out)))
   (define loaded (load-project temp-root))
   (check-equal? (project-linux-formats loaded) '("deb" "flatpak"))
   (check-equal? (project-flatpak-finish-args loaded)
                 '("--socket=x11" "--device=dri"))
   (check-equal? (project-flatpak-manifest loaded) "packaging/demo.yml")

   ;; ------------------------------------------------ identity and naming

   (define project (rivet-project temp-root (config)))
   (check-equal? (flatpak-app-id project) "dev.example.demo")
   (check-exn #rx"reverse-DNS"
              (lambda ()
                (flatpak-app-id (rivet-project temp-root
                                               (config #:identifier "demo")))))
   (check-regexp-match #rx"-linux-(x64|arm64)\\.flatpak$"
                       (path->string (flatpak-bundle-path project)))
   (check-true
    (string-prefix? (path->string (flatpak-bundle-path project))
                    (path->string (build-path temp-root "dist"))))

   ;; ------------------------------------------------ manifest rendering

   (when digests-available?
     (define tar-gz (build-path temp-root "Demo-2.3.4-linux-x86_64.tar.gz"))
     (call-with-output-file tar-gz #:exists 'truncate/replace #:mode 'binary
       (lambda (out) (write-bytes #"payload" out)))
     (define manifest
       (render-flatpak-manifest project tar-gz
                                #:finish-args '("--socket=x11"
                                                "--talk-name=org.gnome.Mutter.IdleMonitor")
                                #:icon "assets/icon.png"
                                #:desktop-name "dev.example.demo.desktop"))
     (define (has? pattern)
       (check-not-false (regexp-match? pattern manifest)))
     (has? #rx"app-id: 'dev\\.example\\.demo'")
     (has? #rx"runtime-version: '50'")
     (has? #rx"command: 'demo'")
     (has? #rx"separate-locales: false")
     (has? #rx"  - '--socket=x11'")
     (has? #rx"  - '--talk-name=org\\.gnome\\.Mutter\\.IdleMonitor'")
     (has? #rx"path: 'Demo-2\\.3\\.4-linux-x86_64\\.tar\\.gz'")
     (has? (regexp (string-append "sha256: '" (sha256-file/hex tar-gz) "'")))
     (has? #rx"cp -a \\. '/app/Demo/'")
     (has? #rx"ln -sf '/app/Demo/demo' '/app/bin/demo'")
     (has? #rx"install -Dm644 'icon[.]png' '/app/share/icons/hicolor/512x512/apps/dev[.]example[.]demo[.]png'")
     (has? #rx"install -Dm644 'dev[.]example[.]demo[.]desktop' '/app/share/applications/dev[.]example[.]demo[.]desktop'")
     (check-not-false (regexp-match? #rx"name: lz4" manifest))
     (check-not-false (regexp-match? #rx"name: ncurses" manifest))

     ;; YAML single-quoted scalars double an embedded quote.
     (define quoted
       (render-flatpak-manifest project tar-gz
                                #:finish-args '("--env=GREETING=it's here")
                                #:icon #f
                                #:desktop-name #f))
     (check-not-false
      (regexp-match? #rx"  - '--env=GREETING=it''s here'" quoted))

     ;; A generated manifest refuses to guess the sandbox.
     (check-exn
      #rx"flatpak-finish-args"
      (lambda ()
        (render-flatpak-manifest project tar-gz))))

   ;; ------------------------------------------------ desktop entry

   (define desktop (build-path temp-root "dev.example.demo.desktop"))
   (write-flatpak-desktop-entry! project desktop)
   (define desktop-lines (string-split (file->string desktop) "\n"))
   (check-not-false (member "Exec=demo" desktop-lines))
   (check-not-false (member "TryExec=demo" desktop-lines))
   (check-not-false (member "Icon=dev.example.demo" desktop-lines))

   ;; No icon means no Icon key, matching the deb/rpm warning path.
   (define no-icon
     (rivet-project temp-root (config #:icon #f)))
   (define no-icon-warning (open-output-string))
   (parameterize ([current-error-port no-icon-warning])
     (write-flatpak-desktop-entry! no-icon
                                   (build-path temp-root "no-icon.desktop")))
   (check-false
    (for/or ([line (in-list
                    (string-split
                     (file->string (build-path temp-root "no-icon.desktop"))
                     "\n"))])
      (string-prefix? line "Icon=")))
   (check-true
    (regexp-match? #rx"no `linux-icon`" (get-output-string no-icon-warning)))

   ;; A missing sandbox declaration fails before any tool probing.
   (check-exn
    #rx"flatpak-finish-args"
    (lambda ()
      (create-flatpak-bundle! (rivet-project temp-root
                                             (config #:finish-args #f))
                              (build-path temp-root "unused.tar.gz")))))
 (lambda ()
   (when (directory-exists? temp-root)
     (delete-directory/files temp-root))))
