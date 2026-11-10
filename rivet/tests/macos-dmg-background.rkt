#lang racket/base

;; Staging for the branded DMG backdrop (#322, #444): the staged PNG must
;; draw at one pixel per point — window pixel size AND 72dpi — regardless
;; of the source asset's DPI metadata. Only macOS has sips; the file exits
;; elsewhere, mirroring the installer's own platform gate.

(require racket/file
         racket/format
         racket/port
         racket/system
         rackunit
         "../../rivet-cli/installer.rkt"
         (submod "../../rivet-cli/installer.rkt" test-support))

(define sips (find-executable-path "sips"))
(unless (and (equal? (system-type 'os) 'macosx) sips)
  (displayln "rivet-dmg-background-tests: skipping; sips staging is macOS-only")
  (exit 0))

(define (sips-run! . arguments)
  (define exit-code
    (parameterize ([current-error-port (open-output-nowhere)])
      (apply system*/exit-code sips (map ~a arguments))))
  (check-equal? exit-code 0 "sips must accept the fixture arguments"))

(define work-root (make-temporary-file "rivet-dmg-background-~a" 'directory))

;; A minimal, structurally valid 24bpp BMP that sips accepts and converts.
(define (minimal-bmp width height)
  (define row-size (* 4 (ceiling (/ (* width 24) 32))))
  (define pixel-size (* row-size height))
  (define (u16-le n)
    (bytes (bitwise-and n #xFF) (bitwise-and (arithmetic-shift n -8) #xFF)))
  (define (u32-le n)
    (bytes-append (u16-le n) (u16-le (arithmetic-shift n -16))))
  (bytes-append #"BM"
                (u32-le (+ 14 40 pixel-size)) (u16-le 0) (u16-le 0) (u32-le 54)
                (u32-le 40) (u32-le width) (u32-le height)
                (u16-le 1) (u16-le 24) (u32-le 0) (u32-le pixel-size)
                (u32-le 2835) (u32-le 2835) (u32-le 0) (u32-le 0)
                (make-bytes pixel-size #xC8)))

;; Author a PNG fixture at an exact pixel size and DPI stamp, the way a
;; product's 2x artwork pipeline would.
(define (fixture-png name width height dpi)
  (define bmp (build-path work-root (string-append name ".bmp")))
  (define png (build-path work-root (string-append name ".png")))
  (call-with-output-file bmp #:exists 'truncate/replace
    (lambda (out) (write-bytes (minimal-bmp width height) out)))
  (sips-run! "-s" "format" "png"
             "-s" "dpiWidth" (number->string dpi)
             "-s" "dpiHeight" (number->string dpi)
             (path->string bmp) "--out" (path->string png))
  (delete-file bmp)
  png)

(define (check-staged! name source-png)
  (define staged (build-path work-root (string-append name "-staged.png")))
  (stage-dmg-background! source-png staged sips)
  (check-equal? (raster-pixel-size staged sips) (list 660 400)
                (string-append name ": staged pixels must equal the window point size"))
  (check-equal? (raster-dpi-size staged sips) '(72.0 72.0)
                (string-append name ": staged DPI must be 72 so Finder draws one pixel per point")))

;; The movebit failure shape (#444): a 2x artwork stamped at 144dpi —
;; resampling alone kept the DPI and Finder drew a quarter-window backdrop.
(check-staged! "two-x-144dpi" (fixture-png "two-x-144dpi" 1320 800 144))
;; Pixel size already correct but stamped 144dpi — no resample runs, so the
;; DPI normalize is the only defense.
(check-staged! "one-x-144dpi" (fixture-png "one-x-144dpi" 660 400 144))
;; The already-correct shape must pass through unchanged in effect.
(check-staged! "one-x-72dpi" (fixture-png "one-x-72dpi" 660 400 72))

(delete-directory/files work-root)
