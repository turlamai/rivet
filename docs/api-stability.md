# Rivet API stability

Rivet is pre-1.0, but its public surface is deliberate. Every phase-0 export
from `rivet`, `rivet/app-info`, `rivet/backend`, `rivet/keel`,
`rivet/protocol`, `rivet/resources`, `rivet/system`, `rivet/chart`,
`rivet/distribution`, and `rivet/testing` is covered by `rivet/tests/public-api.rkt`.

An API change must therefore be explicit:

1. change the implementation and documentation together;
2. update the public export snapshot intentionally;
3. record the migration in `CHANGELOG.md`; and
4. pass the full Racket suite on both the minimum supported Racket release and
   the current development baseline.

## Supported Racket versions

Rivet currently supports Racket CS 9.0 and newer; the `base` floor in
`info.rkt` is authoritative. A release is tested on that floor and on the
current development baseline. Platform support is the matrix in the README,
not an inference from the Racket version.

## Deprecation and removal

Before 1.0, an incompatible change is allowed when it removes a design trap or
creates a materially clearer long-term contract, but it still needs the
implementation, the documentation, the export snapshot and a `CHANGELOG.md`
migration note in one change.

After 1.0, removing or changing a public binding requires a major release.
A binding is deprecated before removal by marking it in the Scribble reference
and `CHANGELOG.md`, naming its replacement, and keeping the old behavior for at
least one minor release. Additions remain minor releases; compatible fixes
remain patch releases. A deprecation warning is not a substitute for the
replacement's documentation and test coverage.

Schema type identifiers such as `String`, `Int64`, `Bool`, and `(List T)` are
syntax accepted by Rivet declaration forms. They are not exported runtime
values. Tools inspect the canonical Keel `app-schema` instead.
