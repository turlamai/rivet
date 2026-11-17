#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${repo_root}/.github/scripts/check-owner-hygiene.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect_success() {
  if ! "$@" >/dev/null 2>&1; then
    echo "expected command to succeed: $*" >&2
    exit 1
  fi
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

git init -q -b main "$tmp"
git -C "$tmp" config user.name "Rivet Hygiene Test"
git -C "$tmp" config user.email "hygiene-test@example.invalid"

mkdir -p "$tmp/docs" "$tmp/linux"
printf 'Apache License\n\nCopyright (c) 2026 TurLamAI (formerly turinglambdaai)\n' \
  > "$tmp/LICENSE"
printf '# Changelog\n\n## 0.1.0\n\n- Initial release by TuringLambda AI.\n' \
  > "$tmp/CHANGELOG.md"
printf '# Docs\n\nTurLamAI ships Rivet.\n' > "$tmp/docs/readme.md"
git -C "$tmp" add .
git -C "$tmp" commit -q -m "clean tree with the documented allowlist"

expect_success bash "$checker" "$tmp"

# A spaced display form in user-visible copy is forbidden.
printf '# About\n\nTuringLambda AI builds this app.\n' > "$tmp/docs/about.md"
git -C "$tmp" add docs/about.md
git -C "$tmp" commit -q -m "spaced display form"
expect_failure bash "$checker" "$tmp"

git -C "$tmp" rm -q docs/about.md
git -C "$tmp" commit -q -m "drop spaced display form"

# The joined display form is forbidden too.
printf '// (c) TuringLambdaAI\n' > "$tmp/linux/header.cpp"
git -C "$tmp" add linux/header.cpp
git -C "$tmp" commit -q -m "joined display form"
expect_failure bash "$checker" "$tmp"

git -C "$tmp" rm -q linux/header.cpp
git -C "$tmp" commit -q -m "drop joined display form"

# The bare old owner leaks through generated strings and URLs.
mkdir -p "$tmp/linux"
printf 'let issuer = "turinglambdaai"\n' > "$tmp/linux/strings.txt"
git -C "$tmp" add linux/strings.txt
git -C "$tmp" commit -q -m "bare owner"
expect_failure bash "$checker" "$tmp"

git -C "$tmp" rm -q linux/strings.txt
git -C "$tmp" commit -q -m "drop bare owner"
expect_success bash "$checker" "$tmp"

# The shipped repository must be clean under the same gate.
expect_success bash "$checker" "$repo_root"

echo "owner-hygiene gate tests passed"
