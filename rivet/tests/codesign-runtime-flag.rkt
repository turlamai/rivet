#lang racket/base

;; The production gate reads the hardened-runtime CodeDirectory flag from
;; `codesign -dv` output. Exact `(runtime)` matching fails every signature
;; whose flags word shares the parentheses with other flags, which first
;; broke a production release (PodLens v0.8.0). These cases pin the shapes
;; codesign actually emits across ad-hoc, linker-signed and production
;; signatures, plus the negatives that must keep failing the gate.
(require rackunit)

(define runtime-flagged?
  (dynamic-require 'rivet-cli/verify 'codesign-description-runtime-flagged?))

(define production-description
  (string-append
  "Executable=/Applications/PodLens.app/Contents/MacOS/PodLens\n"
  "Identifier=com.turlamai.podlens\n"
  "Format=app bundle with Mach-O universal (x86_64 arm64)\n"
  "CodeDirectory v=20500 size=197455 flags=0x10000(runtime) hashes=6+7\n"
  "Signature size=9045\n"
  "Timestamp=18 Nov 2026 at 09:00:00\n"))

(define adhoc-description
  (string-append
   "Executable=/tmp/CI-out/RivetHost.app/Contents/MacOS/RivetHost\n"
   "CodeDirectory v=20400 size=833 flags=0x10002(adhoc,runtime) hashes=5\n"
   "Signature=adhoc\n"))

(define linker-signed-description
  (string-append
   "Executable=/opt/homebrew/bin/tool\n"
   "CodeDirectory v=20400 size=620 flags=0x2002(runtime,linker-signed) hashes=3\n"))

(define plain-codesign-d-description
  (string-append
   "Executable=/Applications/App.app/Contents/MacOS/App\n"
   "Identifier=com.example.app\n"))

(check-true (runtime-flagged? production-description)
            "production signing keeps the exact (runtime) spelling")
(check-true (runtime-flagged? adhoc-description)
            "runtime sharing the parentheses with adhoc stays detected")
(check-true (runtime-flagged? linker-signed-description)
            "runtime sharing the parentheses with linker-signed stays detected")
(check-false (runtime-flagged? "CodeDirectory v=20500 size=197455 flags=0x0(none) hashes=6\n")
             "a flags word without runtime fails the gate")
(check-false (runtime-flagged? plain-codesign-d-description)
             "plain codesign -d output without any flags line fails the gate")
(check-false (runtime-flagged? "")
             "empty description fails the gate")
