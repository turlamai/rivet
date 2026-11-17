#!/usr/bin/env bash
set -euo pipefail

# Fail when a legacy owner spelling reaches a tracked, user-visible file.
#
# The family display name is TurLamAI. The retired spellings are forbidden in
# code, UI strings, generated headers, site copy, and fixtures. Two historical
# surfaces are deliberately allowed:
#
#   LICENSE*    the "(formerly turinglambdaai)" provenance note;
#   CHANGELOG.md historical release entries;
#   this script and its self-test, which must name the forbidden strings.
#
# Usage: check-owner-hygiene.sh [repository-root]
# Exit:  0 clean, 1 offenders found, 2 usage error.

if (( $# > 1 )); then
  echo "usage: check-owner-hygiene.sh [repository-root]" >&2
  exit 2
fi

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if [[ ! -d "$repo_root/.git" ]]; then
  echo "owner-hygiene: not a git repository: $repo_root" >&2
  exit 2
fi

# Keep the three patterns separate so the failure message can name the form.
legacy_pattern='TuringLambda AI|TuringLambdaAI|turinglambdaai'

offenders="$(git -C "$repo_root" grep --line-number --no-color --full-name -I \
  -E "$legacy_pattern" -- . \
  ':(exclude,glob)LICENSE*' \
  ':(exclude)CHANGELOG.md' \
  ':(exclude)docs/ci.md' \
  ':(exclude)docs/ci.zh-CN.md' \
  ':(exclude).github/scripts/check-owner-hygiene.sh' \
  ':(exclude).github/scripts/test-check-owner-hygiene.sh' || true)"

if [[ -n "$offenders" ]]; then
  echo "owner-hygiene: legacy owner spelling found outside the allowlist:" >&2
  echo "$offenders" >&2
  echo >&2
  echo "Use TurLamAI. Only LICENSE (provenance), CHANGELOG.md (history) and" >&2
  echo "the hygiene scripts may mention the retired names." >&2
  exit 1
fi

echo "owner-hygiene: no legacy owner spellings found"
