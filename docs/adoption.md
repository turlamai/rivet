# Cross-product adoption inventory (issue #370)

Rivet is the shared packaging foundation; the family's updater and
release contracts only count as "supported" where a product actually
exercises them on installed packages. This inventory tracks which
application repositories adopt which part of the contract. It records
verified facts from each repository's own workflows (audited 2026-11-02,
local checkouts); re-audit before relying on a row, and update it with
the adopting PR link when a product migrates.

Release-mode names refer to the [release modes standard](release-and-updates.md).

## Desktop products

| Product | Release workflow | Mode observed | Updater integration |
| --- | --- | --- | --- |
| Fulcrum | yes (2 workflows) | production (`raco rivet release` with credentials) | `rivet/distribution` + RivetUpdate references (9 files) |
| Taskly | yes | `--development --without-updates` | `rivet/distribution` + RivetUpdate references (7 files) |
| PodLens | yes | `--development` | references (4 files) |
| Threadly | yes | `--development --without-updates` | references (4 files) |
| Payback | yes | `--development` | references (3 files) |
| MoveBit | yes | `--development` | references (3 files) |
| RegexMate | yes | `--development --without-updates` | references (3 files) |
| SyncPilot | yes | `--development --without-updates` (Linux/Xvfb leg) | references (2 files) |
| Keyward | yes | `--development --without-updates` | references (1 file) |
| Booklight | reported in issue #371 (`--development`); not present in the audited local checkout | unverified | unverified |
| Autarx | reported in issue #371 (ad-hoc macOS + MSI routes); not present in the audited local checkout | unverified | unverified |
| HackDigest | no release workflow | n/a | isolated `rivet/distribution` references (1 file) |

## Non-desktop repositories

FlashPilot (CLI-only), Permit, Commerce, Publy, Sonar, Graft, Foreman,
Keel, Switchboard, and Pitboard expose no `raco rivet release` workflow
and no updater references; as CLI/library/server-shaped repositories they
are out of scope for desktop packaging modes (issue #371 classifies them
instead of imposing desktop packaging).

## Adoption rules

- A product "supports updates" only after its own CI or acceptance suite
  installs the produced package and completes the N→N+1 upgrade plus
  data-preservation checks on a real host; portable packaging alone does
  not count.
- Mode migrations land as PRs in the product repository, linked back
  here; the framework repository does not edit product workflows.
- Products promising a signed mode must run the production release path
  so credential fail-closed gates actually gate.
