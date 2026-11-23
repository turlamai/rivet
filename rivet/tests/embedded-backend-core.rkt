#lang racket/base

;; The embedded Racket CS core has exactly one implementation.
;;
;; platform/windows/runtime/backend.cpp and platform/linux/runtime/backend.cpp
;; used to carry byte-identical copies of everything below the native channel
;; (Racket boot, reader/writer threads, request/cancel/completion bookkeeping).
;; That is the copy class behind #238/#280: a fix landed in one host and
;; silently missed the other. The shared unit lives in runtime/src, includes
;; the Racket CS C API, and is therefore compiled by the platform builds, not
;; by the portable rivet_protocol library. Guards:
;;
;;   1. every platform source list that compiles the platform backend also
;;      compiles the shared core;
;;   2. the platform files never grow the core back (Racket boot, frame loop
;;      and completion handling stay in the shared unit).

(require rackunit
         racket/file
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root "../..")

(define (source . parts)
  (file->string (apply build-path repository-root parts)))

(define shared-core
  (source "runtime" "src" "embedded_backend.cpp"))
(define shared-header
  (source "runtime" "include" "rivet" "detail" "embedded_backend.hpp"))

(define windows-backend
  (source "platform" "windows" "runtime" "backend.cpp"))
(define linux-backend
  (source "platform" "linux" "runtime" "backend.cpp"))

;; Markers that only the core may contain.
(define core-markers
  '("racket_boot(&boot)"
    "racket_dynamic_require("
    "completions_.reject_all("
    "void EmbeddedBackendCore::reader_main()"))

(for ([marker (in-list core-markers)])
  (check-true (string-contains? shared-core marker)
              (format "the shared core must own ~s" marker))
  (for ([backend (in-list (list windows-backend linux-backend))]
        [platform (in-list '(windows linux))]
        #:when #t)
    (check-false (string-contains? backend marker)
                 (format (string-append "the ~a backend must not duplicate ~s; "
                                        "it belongs to "
                                        "runtime/src/embedded_backend.cpp")
                         platform marker))))

;; Both platform files forward to the core and open their own channel.
(for ([backend (in-list (list windows-backend linux-backend))]
      [platform (in-list '(windows linux))]
      #:when #t)
  (check-true (string-contains? backend "detail::EmbeddedBackendCore")
              (format "the ~a Backend must delegate to the shared core"
                      platform))
  (check-true (string-contains? backend "detail::ServerEndpoints")
              (format (string-append "the ~a Backend must hand serve-fds "
                                     "endpoints to the core through "
                                     "detail::ServerEndpoints")
                      platform)))

(check-true (string-contains? shared-header "class EmbeddedBackendCore")
            "the shared header must declare the core")

;; Every list that compiles a platform backend must also compile the core.
(define windows-props
  (source "platform" "windows" "rivet-runtime-sources.props"))
(check-true (string-contains? windows-props "runtime\\src\\embedded_backend.cpp")
            "rivet-runtime-sources.props must compile the shared core")
(define windows-integration
  (source "platform" "windows" "Integration" "CMakeLists.txt"))
(check-true (string-contains? windows-integration
                             "runtime/src/embedded_backend.cpp")
            "the Windows integration sample must link the shared core")
(define linux-fragment
  (source "platform" "linux" "rivet_linux_sources.cmake"))
(check-true (string-contains? linux-fragment "runtime/src/embedded_backend.cpp")
            "the Linux rivet::platform library must compile the shared core")

;; The portable library stays Racket-agnostic.
(define portable-cmake (source "runtime" "CMakeLists.txt"))
(check-false (string-contains? portable-cmake "embedded_backend")
             (string-append "the portable rivet_protocol library must not "
                            "compile the Racket-dependent embedded core"))
