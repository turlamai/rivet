#lang racket/base

;; Regression guard: a Windows application build must not write MSBuild
;; intermediate state into the Rivet checkout.
;;
;; The downstream host references `platform/windows/rivet-host.vcxproj` (and,
;; for chart hosts, `rivet-chart.vcxproj`) as ProjectReferences. `OutDir` reaches
;; those libraries from the `raco rivet build` command line, but `IntDir` does
;; not, so before this contract every application build dropped several hundred
;; megabytes of objects and generated cppwinrt headers under
;; `platform/windows/<library>/x64/<configuration>/` inside the framework tree:
;; a permanently dirty linked checkout, and one object graph shared by every
;; application built against it. The real MSBuild round trip runs on the
;; Windows CI legs; this cross-platform test keeps the two halves of the
;; contract from drifting apart.

(require rackunit
         racket/file
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root "../..")

(define build-source
  (file->string (build-path repository-root "rivet-cli" "build.rkt")))

(check-true (regexp-match?
             #px"set-path! #\"RIVET_INTERMEDIATE_DIR\" intermediate-root"
             build-source)
            "the Windows build environment must export RIVET_INTERMEDIATE_DIR")
(check-true (regexp-match?
             #px"build-path \\(rivet-project-root project\\) \"[.]rivet\" \"obj\""
             build-source)
            "the intermediate root must live under the application's generated .rivet tree")

;; Exact literal: MSBuild requires the trailing separator, and the three
;; appended segments keep the libraries and their configurations apart.
(define expected-int-dir-element
  "<IntDir Condition=\"'$(RIVET_INTERMEDIATE_DIR)' != ''\">$(RIVET_INTERMEDIATE_DIR)$(ProjectName)\\$(Platform)\\$(Configuration)\\</IntDir>")

(for ([library (in-list '("rivet-host" "rivet-chart"))])
  (define project-source
    (file->string (build-path repository-root "platform" "windows"
                              (string-append library ".vcxproj"))))
  (check-true (string-contains? project-source expected-int-dir-element)
              (format (string-append "~a.vcxproj must keep its objects under the "
                                     "application's RIVET_INTERMEDIATE_DIR, "
                                     "separated by project, platform and "
                                     "configuration, with a trailing separator")
                      library)))
