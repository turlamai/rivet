#!/usr/bin/env python3
"""Fail closed on unexpected artifacts or drift in a Rivet source release."""
import argparse
import hashlib
import hmac
from pathlib import Path
import re


def verify_release_inventory(directory: Path, version: str) -> None:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("release version must be MAJOR.MINOR.PATCH")
    archive = f"rivet-{version}.zip"
    expected = {archive, "SHA256SUMS", "release-notes.md"}
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("staged release directory must be a real directory")
    actual = {entry.name for entry in directory.iterdir()}
    if actual != expected:
        raise ValueError(
            f"public source release inventory mismatch: "
            f"missing={sorted(expected - actual)} extra={sorted(actual - expected)}"
        )
    for name in sorted(expected):
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"release input is not a nonempty regular file: {name}")
    notes = (directory / "release-notes.md").read_text(encoding="utf-8")
    if not notes.strip():
        raise ValueError("release notes must be nonempty")
    manifest = (directory / "SHA256SUMS").read_text(encoding="ascii")
    match = re.fullmatch(r"([a-f0-9]{64})  " + re.escape(archive) + r"\n", manifest)
    if not match:
        raise ValueError("SHA256SUMS must contain exactly the versioned source ZIP")
    digest = hashlib.sha256()
    with (directory / archive).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if not hmac.compare_digest(match.group(1), digest.hexdigest()):
        raise ValueError("SHA256SUMS does not match the staged source ZIP")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("version")
    args = parser.parse_args()
    verify_release_inventory(args.directory, args.version)
    print(f"verified Rivet {args.version} source-release inventory and SHA-256")


if __name__ == "__main__":
    main()
