"""Executable positive and negative tests for Rivet's source release inventory."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from importlib.util import module_from_spec, spec_from_file_location


SCRIPT = Path(__file__).with_name("verify-release-source-inventory.py")
spec = spec_from_file_location("release_inventory", SCRIPT)
inventory = module_from_spec(spec)
spec.loader.exec_module(inventory)


class InventoryTests(unittest.TestCase):
    VERSION = "0.14.0"

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.archive = self.root / "rivet-0.14.0.zip"
        self.archive.write_bytes(b"PK\x03\x04fixture")
        self.notes = self.root / "release-notes.md"
        self.notes.write_text("Release changes and limitations.\n", encoding="utf-8")
        self.sums = self.root / "SHA256SUMS"
        self.recalculate()

    def recalculate(self):
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.sums.write_text(f"{digest}  {self.archive.name}\n", encoding="ascii")

    def verify(self):
        inventory.verify_release_inventory(self.root, self.VERSION)

    def test_exact_inventory(self):
        self.verify()

    def test_reject_tampered_archive(self):
        self.archive.write_bytes(b"PK\x03\x04different")
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.verify()

    def test_reject_missing_archive(self):
        self.archive.unlink()
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            self.verify()

    def test_reject_debug_file(self):
        (self.root / "rivet-0.14.0.wixpdb").write_bytes(b"private")
        with self.assertRaisesRegex(ValueError, "extra="):
            self.verify()

    def test_reject_duplicate_sidecar(self):
        (self.root / "rivet-0.14.0.zip.sha256").write_text("old")
        with self.assertRaisesRegex(ValueError, "extra="):
            self.verify()

    def test_reject_wrong_checksum_filename(self):
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.sums.write_text(f"{digest}  wrong.zip\n", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "exactly"):
            self.verify()

    def test_reject_extra_checksum_entry(self):
        with self.sums.open("a", encoding="ascii") as handle:
            handle.write("0" * 64 + "  hidden.zip\n")
        with self.assertRaisesRegex(ValueError, "exactly"):
            self.verify()

    def test_reject_blank_release_notes(self):
        self.notes.write_text("  \n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "nonempty"):
            self.verify()

    def test_reject_invalid_version(self):
        with self.assertRaisesRegex(ValueError, "MAJOR.MINOR.PATCH"):
            inventory.verify_release_inventory(self.root, "0.14")

    def test_reject_empty_archive(self):
        self.archive.write_bytes(b"")
        self.recalculate()
        with self.assertRaisesRegex(ValueError, "nonempty regular"):
            self.verify()

    def test_reject_symlink_archive(self):
        with tempfile.TemporaryDirectory() as other_directory:
            other = Path(other_directory) / "archive-copy"
            other.write_bytes(self.archive.read_bytes())
            self.archive.unlink()
            self.archive.symlink_to(other)
            with self.assertRaisesRegex(ValueError, "nonempty regular"):
                self.verify()


if __name__ == "__main__":
    unittest.main()
