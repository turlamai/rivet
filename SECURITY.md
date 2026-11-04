# Security Policy

Rivet is pre-1.0 and has not undergone an independent security audit. This
policy describes how to report a problem and what the project can honestly
promise today.

## Supported versions

Rivet does not maintain long-term-support branches before 1.0. Security fixes
land on `main` and are published in the next release. Only the latest published
release and current `main` are supported; an older tag is not patched in place.
Applications that pin a Rivet commit own the decision to move forward.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private vulnerability reporting
for this repository:

<https://github.com/turlamai/rivet/security/advisories/new>

If that form is unavailable, contact the repository owner privately through
their GitHub profile. Include:

- the affected Rivet version (`raco rivet --version`) or commit SHA;
- operating system, architecture, and Racket version;
- a minimal reproduction or the exact malformed input;
- the impact you believe is reachable, and any suggested mitigation.

Never include credentials, signing keys, customer data, or another person's
private information.

## What to expect

This is a single-maintainer project, so response is best effort:

- acknowledgement of a complete report, normally within seven days;
- an assessment and a remediation plan, or a clear explanation that the report
  is out of scope;
- coordinated disclosure after a fix is available, with credit unless you ask
  otherwise.

There is no bug bounty, paid program, or guaranteed response SLA. A report that
only reproduces with a modified framework, a disabled security check, or a
product's own application code is not automatically a Rivet vulnerability.

## Security-sensitive areas

- RVT1 framing, value decoding, resource limits, and cancellation;
- native/Racket lifetime and threading boundaries;
- runtime and package artifact selection, including update manifests;
- generated Swift, C++, and Kotlin code escaping;
- installer path handling, staging, atomic replacement, rollback, and recovery;
- DLL/framework loading and embedded runtime discovery;
- untrusted input handled by application RPCs.

## Trust model and boundaries

- The Racket backend is **trusted application code**. It runs in the same process
  as the native UI and is not a sandbox boundary. Do not execute untrusted code
  in the backend.
- Publisher signing keys, update-signing keys, entitlement keys, and payment
  credentials are separate trust domains. Keep them outside repositories,
  ordinary CI, and diagnostics.
- A checksum or a manifest alone is not publisher trust. Rivet verifies the
  signed manifest, exact size, SHA-256, and platform code signature, but the
  application still owns its consent, channel, and data-migration policy.
- Product business logic, remote services, accounts, entitlements, and payment
  flows are outside this repository. Report those to the product owner.

## Privacy

Rivet itself collects no telemetry and performs no background upload. The
framework writes diagnostics only to the sink the application installs; updates
and device channels contact the network only when the application enables and
invokes them. Applications remain responsible for their own privacy policy,
redaction, retention, and user consent.
