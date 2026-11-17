#lang info

;; The package name is declared here; `raco-commands` stays at the
;; collection level in rivet-cli/info.rkt (the collection that owns it).
(define name "rivet")
(define collection 'multi)
;; Racket package versions reject a trailing ".0" component. Release tags and
;; native artifacts remain three-component SemVer via `release-version`; keep
;; this field synced to the release-version major.minor so the catalog
;; advertises what the tags actually ship.
(define version "0.16")
(define release-version "0.16.0")
(define pkg-desc "Native application foundation for Racket")
(define pkg-authors '(turlamai))
(define license 'MIT)

(define deps
  '(["base" #:version "9.0"]
    "cext-lib"
    "crypto-lib"
    ;; Pure-Racket Ed25519 fallback (RFC 8032): update-manifest verification
    ;; and the release gate keep working where no native provider implements
    ;; Ed25519 — the package builder's OpenSSL and verify-only embedded
    ;; processes both qualify. Floor is the lowest version this suite covers.
    ["ed25519" #:version "0.1"]
    ["keel" #:version "0.3.1"]
    "net-lib"))

(define build-deps
  '("racket-doc"
    "rackunit-lib"
    "scribble-lib"))

;; `raco pkg create` does not consult .gitignore. Keep local native build and
;; application-output trees out of source releases even when maintainers run
;; the release smoke immediately after compiling every platform adapter.
(define source-omit-files
  '(".rivet"
    ".build"
    "build"
    "dist"
    "examples/taskboard/.rivet"
    "examples/taskboard/macos-host/.build"
    "platform/macos/.build"
    "platform/macos/host/.build"
    "platform/macos/Integration/.build"))
