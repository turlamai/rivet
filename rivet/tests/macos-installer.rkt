#lang racket/base

(require racket/file
         net/base64
         racket/path
         racket/system
         rackunit
         "../../rivet-cli/installer.rkt"
         "../../rivet-cli/project.rkt"
         (submod "../../rivet-cli/installer.rkt" test-support))

;; ---------------------------------------------------------------------------
;; Finder layout script

(define script (dmg-style-applescript "Smoke App" "Smoke.app"))
(check-regexp-match #rx"tell disk \"Smoke App\"" script
                    "the script must address the volume by name")
(check-regexp-match
 #rx"set background picture of theViewOptions to file \"[.]background:background[.]png\""
 script
 "the background must come from the hidden .background folder")
(check-regexp-match #rx"set position of item \"Smoke[.]app\" of container window" script
                    "the bundle icon must be positioned")
(check-regexp-match #rx"set position of item \"Applications\" of container window" script
                    "the Applications link must be positioned")
(check-regexp-match #rx"set bounds of container window to \\{200, 120, 860, 520\\}" script
                    "the window must match the branded background geometry")
(check-regexp-match #rx"set icon size of theViewOptions to 80" script)

;; AppleScript strings escape volume and bundle names.
(check-regexp-match #rx"tell disk \"Smoke \\\\\"App\\\\\"\""
                     (dmg-style-applescript "Smoke \"App\"" "Smoke.app")
                     "quotes in display names must be AppleScript-escaped")

;; ---------------------------------------------------------------------------
;; hdiutil mount identity and detach recovery

(define attach-output
  (string-append
   "/dev/disk7\tApple_partition_scheme\t\n"
   "/dev/disk7s1\tApple_partition_map\t\n"
   "/dev/disk7s2\tApple_HFS\t/Volumes/Smoke App\n"))
(define-values (attached-device attached-path)
  (attached-image-location attach-output))
(check-equal? attached-device "/dev/disk7s2")
(check-equal? attached-path "/Volumes/Smoke App")

(check-equal? (whole-image-device attached-device) "/dev/disk7")
(check-equal? (whole-image-device "/dev/disk7") "/dev/disk7")
(check-true
 (disk-image-device-listed?
  (string-append "/dev/disk7\tGUID_partition_scheme\t\n"
                 "/dev/disk7s2\tApple_HFS\t/Volumes/Smoke App\n"
                 "image-path      : /tmp/smoke.dmg\n")
  "/dev/disk7"))
(check-false
 (disk-image-device-listed? "/dev/disk70\tGUID_partition_scheme\t\n"
                            "/dev/disk7")
 "the whole-device identity must not match similarly numbered devices")

;; Regression: Finder removed the mountpoint, but the disk image device
;; remains attached. Do not falsely report a successful detach.
(let ([mounted? #f]
      [attached? #t]
      [calls '()])
  (define (fake-detach _who _hdiutil . args)
    (set! calls (cons args calls))
    (when (equal? args '("detach" "-force" "/dev/disk7"))
      (set! attached? #f)))
  (detach-mounted-image! "hdiutil" "/dev/disk7" attached-path
                         #:run! fake-detach
                         #:mounted? (lambda () mounted?)
                         #:attached? (lambda () attached?)
                         #:retries 1
                         #:pause (lambda (_) (void)))
  (check-equal? (reverse calls)
                '(("detach" "/dev/disk7")
                  ("detach" "-force" "/dev/disk7"))
                "an unmounted but attached image must be force-detached"))



(let ([calls '()]
      [mounted? #t])
  (define (fake-run _who _hdiutil . arguments)
    (set! calls (cons arguments calls))
    (cond
      [(equal? arguments '("detach" "/dev/disk7s2"))
       (error 'fake-hdiutil "resource busy")]
      [else (set! mounted? #f)]))
  (detach-mounted-image! "hdiutil" attached-device attached-path
                         #:run! fake-run
                         #:mounted? (lambda () mounted?)
                         #:retries 1
                         #:pause (lambda (_) (void)))
  (check-equal? (reverse calls)
                '(("detach" "/dev/disk7s2")
                  ("detach" "-force" "/dev/disk7s2"))
                "a busy volume must be force-detached by device node"))

(let ([calls 0]
      [mounted? #t])
  (define (already-detached _who _hdiutil . _arguments)
    (set! calls (add1 calls))
    (set! mounted? #f)
    (error 'fake-hdiutil "no such file or directory"))
  (check-not-exn
   (lambda ()
     (detach-mounted-image! "hdiutil" attached-device attached-path
                            #:run! already-detached
                            #:mounted? (lambda () mounted?))))
  (check-equal? calls 1
                "a failed detach is successful once its mount disappeared"))

;; ---------------------------------------------------------------------------
;; A detached image can remain briefly busy while Finder/Spotlight release it.
;; Retry conversion, not the entire build. A persistent failure must still fail.
(let ([calls 0]
      [pauses '()])
  (define (transient-convert _who _exe . args)
    (set! calls (add1 calls))
    (check-equal? args '("convert" "input.dmg" "-format" "UDZO"
                        "-ov" "-o" "output.dmg"))
    (when (< calls 3)
      (error 'hdiutil "Resource temporarily unavailable")))
  (convert-detached-dmg! "hdiutil" (string->path "input.dmg")
                         (string->path "output.dmg")
                         #:run! transient-convert
                         #:pause (lambda (seconds) (set! pauses (cons seconds pauses)))
                         #:attempts 4)
  (check-equal? calls 3 "two transient conversion failures must be retried")
  (check-equal? pauses '(2 2) "conversion retries must pause between attempts"))

(let ([calls 0])
  (define (permanent-convert _who _exe . _args)
    (set! calls (add1 calls))
    (error 'hdiutil "persistent conversion failure"))
  (check-exn #rx"persistent conversion failure"
             (lambda ()
               (convert-detached-dmg! "hdiutil" (string->path "input.dmg")
                                        (string->path "output.dmg")
                                        #:run! permanent-convert
                                        #:pause (lambda (_) (void))
                                        #:attempts 3)))
  (check-equal? calls 3 "permanent errors must fail after the bounded retries"))

;; A backing image lock may persist even after hdiutil reports the disk
;; detached. Conversion must recover with a private copy and clean that copy.
(let ([root (make-temporary-file "rivet-dmg-convert-~a" 'directory)])
  (dynamic-wind
    void
    (lambda ()
      (define source (build-path root "locked.dmg"))
      (define output (build-path root "finished.dmg"))
      (call-with-output-file source (lambda (out) (display "branded-image" out)))
      (define seen '())
      (define copied-path #f)
      (convert-released-dmg!
       "hdiutil" source output
       #:attempts 2
       #:pause (lambda (_) (void))
       #:run!
       (lambda (_who _exe . args)
         (define input (string->path (second args)))
         (set! seen (cons input seen))
         (when (equal? input source)
           (error 'hdiutil "original file still locked"))
         (set! copied-path input)
         (check-equal? (file->string input) "branded-image")
         (call-with-output-file output #:exists 'truncate/replace
           (lambda (out) (display "compressed" out)))))
      (check-equal? (length seen) 3)
      (check-equal? (file->string output) "compressed")
      (check-false (file-exists? copied-path)
                   "the private conversion copy must be cleaned on success")
      (delete-file output)
      (check-exn
       #rx"persistent conversion failure"
       (lambda ()
         (convert-released-dmg!
          "hdiutil" source output
          #:attempts 2
          #:pause (lambda (_) (void))
          #:run! (lambda (_who _exe . _args)
                   (error 'hdiutil "persistent conversion failure")))))
      (check-false (file-exists? output)
                   "a failed conversion cannot leave a distributable image")
      (check-equal? (length (directory-list root)) 1
                    "failed conversion must clean its temporary copy"))
    (lambda () (delete-directory/files root #:must-exist? #f))))

;; Staged background normalization (macOS: raster-pixel-size shells to sips)

(module+ test
  (when (equal? 'macosx (system-type 'os))
    (define sips (find-executable-path "sips"))
    (when sips
      (define one-by-one-png
        (base64-decode
         #"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
      (define probe (make-temporary-file "rivet-dmg-pixel-~a.png"))
      (call-with-output-file probe
        #:exists 'truncate/replace
        (lambda (out) (write-bytes one-by-one-png out)))
      (check-equal? (raster-pixel-size probe sips) '(1 1)
                    "the reader must report the PNG's own pixel size")
      (delete-file probe))))

;; ---------------------------------------------------------------------------
;; ---------------------------------------------------------------------------
;; Native default-DMG smoke: no custom background or Finder automation needed.
;; hdiutil must preserve the standard /Applications link and signed-bundle layout.

(module+ test
  (when (equal? 'macosx (system-type 'os))
    (define hdiutil (find-executable-path "hdiutil"))
    (when hdiutil
      (define root (make-temporary-file "rivet-plain-dmg-~a" 'directory))
      (define mount-path (build-path root "mounted"))
      (define attached? #f)
      (dynamic-wind
        void
        (lambda ()
          (define app (build-path root "Smoke.app"))
          (define framework (build-path app "Contents" "Frameworks" "Racket.framework"))
          (define project
            (rivet-project root
                           (hasheq 'name "Smoke"
                                   'display-name "Smoke App"
                                   'version "0.1.0")))
          (make-directory* (build-path framework "Versions" "9.3_CS"))
          (call-with-output-file (build-path app "Contents" "Info.plist")
            (lambda (out) (display "<plist/>" out)))
          (call-with-output-file (build-path framework "Versions" "9.3_CS" "Racket")
            (lambda (out) (display "fake-mach-o" out)))
          (make-file-or-directory-link "9.3_CS"
                                       (build-path framework "Versions" "Current"))
          (make-file-or-directory-link "Versions/Current/Racket"
                                       (build-path framework "Racket"))
          (let ([dmg (create-macos-installer! project app #f)])
            (check-true (file-exists? dmg) "plain DMG must be produced")
            (check-false
             (directory-exists?
              (build-path root ".rivet" "installer" "plain-dmg-staging"))
             "plain staging must be removed after image creation")
            (make-directory* mount-path)
            (let ([exit-code
                   (system*/exit-code hdiutil "attach" dmg
                                      "-mountpoint" (path->string mount-path)
                                      "-nobrowse" "-readonly")])
              (set! attached? (zero? exit-code))
              (check-equal? exit-code 0 "plain DMG must attach cleanly")
              (when attached?
                (check-true
                 (file-exists? (build-path mount-path "Smoke.app" "Contents" "Info.plist"))
                 "the app must be at the volume root")
                (check-equal?
                 (file-or-directory-type (build-path mount-path "Applications") #f)
                 'link "plain DMG must link to Applications")
                (check-equal?
                 (file-or-directory-type
                  (build-path mount-path "Smoke.app" "Contents" "Frameworks"
                              "Racket.framework" "Versions" "Current") #f)
                 'link "versioned framework symlink must survive")
                (check-equal?
                 (file-or-directory-type
                  (build-path mount-path "Smoke.app" "Contents" "Frameworks"
                              "Racket.framework" "Racket") #f)
                 'link "framework executable symlink must survive")))))
        (lambda ()
          (when attached?
            (unless (zero? (system*/exit-code hdiutil "detach"
                                             (path->string mount-path)))
              (system* hdiutil "detach" "-force" (path->string mount-path))))
          (delete-directory/files root #:must-exist? #f))))))

;; Live branded DMG build (macOS hosts with Finder automation)

(module+ test
  (define hdiutil (find-executable-path "hdiutil"))
  (define osascript (find-executable-path "osascript"))

  ;; osascript talking to Finder fails fast where automation is denied; a
  ;; stuck TCC permission prompt is cut off at the probe timeout so the suite
  ;; skips instead of hanging.
  (define finder-automation?
    (and hdiutil
         osascript
         (equal? 'macosx (system-type 'os))
         (let ([probe (make-semaphore)]
               [result-box (box #f)]
               [cust (make-custodian)])
           (parameterize ([current-custodian cust])
             (thread
              (lambda ()
                (define exit-code
                  (system*/exit-code osascript
                                     "-e" "tell application \"Finder\" to get name of startup disk"))
                (set-box! result-box (zero? exit-code))
                (semaphore-post probe))))
           (define completed (sync/timeout 20 probe))
           (custodian-shutdown-all cust)
           (and completed (unbox result-box)))))

  (unless finder-automation?
    (displayln
     "rivet-macos-installer-tests: skipping the live DMG; no Finder automation")
    (exit 0))

  (define root (make-temporary-file "rivet-macos-installer-~a" 'directory))
  (define app (build-path root "Smoke.app"))
  (make-directory* (build-path app "Contents" "MacOS"))
  (void
   (call-with-output-file (build-path app "Contents" "Info.plist")
     #:exists 'truncate/replace
     (lambda (out)
       (display
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>dev.rivet.smoke</string></dict></plist>"
        out)))
   (call-with-output-file (build-path app "Contents" "MacOS" "Smoke")
     #:exists 'truncate/replace
     (lambda (out) (display "#!/bin/sh\nexit 0\n" out))))

  ;; A versioned framework must retain symbolic links after DMG staging.
  ;; Converting them into copied directories breaks the original bundle's
  ;; nested code signature; previous branded DMGs did exactly that.
  (define fw (build-path app "Contents" "Frameworks" "Racket.framework"))
  (make-directory* (build-path fw "Versions" "9.3_CS"))
  (call-with-output-file (build-path fw "Versions" "9.3_CS" "Racket")
    #:exists 'truncate/replace
    (lambda (out) (display "fake-mach-o" out)))
  (make-file-or-directory-link "9.3_CS"
                               (build-path fw "Versions" "Current"))
  (make-file-or-directory-link "Versions/Current/Racket"
                               (build-path fw "Racket"))

  ;; A 1x1 PNG is enough for the live run: the packager resamples whatever
  ;; it is given to the window's point size before staging (Finder draws
  ;; the backdrop at native pixel size and never scales it — issue #322).
  (define tiny-png
    (base64-decode
     #"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
  (make-directory* (build-path root "assets"))
  (void
   (call-with-output-file (build-path root "assets" "background.png")
     #:exists 'truncate/replace
     (lambda (out) (write-bytes tiny-png out))))

  (define project
    (rivet-project root
                   (hasheq 'name "Smoke"
                           'display-name "Smoke App"
                           'version "0.1.0"
                           'dmg-background "assets/background.png")))
  (define dmg (create-macos-installer! project app #f))
  (check-true (file-exists? dmg) "the branded DMG must be produced")

  (define mnt (build-path root "inspect-mount"))
  (make-directory* mnt)
  (check-equal? (system*/exit-code hdiutil "attach" dmg
                                   "-mountpoint" (path->string mnt)
                                   "-nobrowse" "-readonly")
                0
                "the branded DMG must attach cleanly")
  (check-true (directory-exists? (build-path mnt "Smoke.app"))
              "the app bundle must sit at the volume root")
  (define mounted-fw
    (build-path mnt "Smoke.app" "Contents" "Frameworks" "Racket.framework"))
  (check-equal? (file-or-directory-type
                 (build-path mounted-fw "Versions" "Current") #f)
                'link
                "versioned framework Current must remain a symlink")
  (check-equal? (file-or-directory-type (build-path mounted-fw "Racket") #f)
                'link
                "top-level framework executable must remain a symlink")
  (check-equal? (file-or-directory-type (build-path mnt "Applications") #f)
                'link
                "the Applications shortcut must be a symlink")
  (check-true (file-exists? (build-path mnt ".background" "background.png"))
              "the background asset must ride in the hidden folder")
  ;; The staged backdrop must be exactly the window's point size: Finder
  ;; draws it 1:1 at native pixel size, so anything else crops the layout
  ;; (issue #322).
  (let ([staged (raster-pixel-size (build-path mnt ".background" "background.png")
                                   (find-executable-path "sips"))])
    (check-equal? staged '(660 400)
                  "the staged background must match the window point size"))
  (check-true (file-exists? (build-path mnt ".DS_Store"))
              "the Finder styling must have written the icon layout")

  (define detach-exit
    (system*/exit-code hdiutil "detach" (path->string mnt)))
  (unless (zero? detach-exit)
    (system* hdiutil "detach" "-force" (path->string mnt)))

  ;; The scratch tree must not leak into the project between runs.
  (define dmg-2 (create-macos-installer! project app #f))
  (check-true (file-exists? dmg-2) "a re-run must overwrite the previous image")

  (delete-directory/files root #:must-exist? #f))
