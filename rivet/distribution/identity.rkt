#lang racket/base

;; Release-target vocabulary shared by the publisher and update clients. Keep
;; this module leaf-loadable: callers that only report platform identity must
;; not initialize crypto factories or native update adapters.

(require racket/date
         racket/format)

(provide platform-symbol
         architecture-symbol
         installer-extension
         installer-symbol?
         feed-installer-symbol?
         rfc3339-now)

;; What a release pipeline may put in a signed update feed.
(define feed-installer-symbols '(zip targz msi deb rpm appimage))
;; What a release asset may be, including formats Rivet does not self-update.
(define all-installer-symbols
  '(zip targz msi msix exe dmg pkg deb rpm appimage))

(define (installer-symbol? value)
  (and (memq value all-installer-symbols) #t))

(define (feed-installer-symbol? value)
  (and (memq value feed-installer-symbols) #t))

(define (platform-symbol [os (system-type 'os)])
  (case os
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]
    [else
     (raise-arguments-error 'platform-symbol
                            "unsupported operating system"
                            "system-type" os)]))

(define (architecture-symbol [machine (system-type 'arch)])
  (case machine
    [(x86_64 amd64) 'x64]
    [(aarch64 arm64) 'arm64]
    [else
     (raise-arguments-error 'architecture-symbol
                            "unsupported architecture"
                            "system-type" machine)]))

(define (installer-extension installer)
  (case installer
    [(zip) ".zip"]
    [(targz) ".tar.gz"]
    [(msi) ".msi"]
    [(msix) ".msix"]
    [(exe) ".exe"]
    [(dmg) ".dmg"]
    [(pkg) ".pkg"]
    [(deb) ".deb"]
    [(rpm) ".rpm"]
    [(appimage) ".AppImage"]
    [else
     (raise-arguments-error 'installer-extension
                            "unsupported installer kind"
                            "installer" installer)]))

(define (rfc3339-now [seconds (current-seconds)])
  (define d (seconds->date seconds #f))
  (format "~a-~a-~aT~a:~a:~aZ"
          (~r (date-year d) #:min-width 4 #:pad-string "0")
          (~r (date-month d) #:min-width 2 #:pad-string "0")
          (~r (date-day d) #:min-width 2 #:pad-string "0")
          (~r (date-hour d) #:min-width 2 #:pad-string "0")
          (~r (date-minute d) #:min-width 2 #:pad-string "0")
          (~r (date-second d) #:min-width 2 #:pad-string "0")))
