#!/usr/bin/env python3
"""Characterization tests for transient GTK4/AT-SPI accessibility nodes."""

import importlib.util
import sys
import types
import unittest
from pathlib import Path

# The traversal helpers require no running AT-SPI bus. A module stub keeps
# this unit gate executable without GTK installed, on any Python 3 host.
sys.modules.setdefault("pyatspi", types.ModuleType("pyatspi"))
module_path = Path(__file__).with_name("linux-atspi.py")
spec = importlib.util.spec_from_file_location("rivet_linux_atspi", module_path)
atspi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(atspi)


class FakeNode:
    def __init__(self, children=(), failed_indices=()):
        self._children = list(children)
        self._failed_indices = set(failed_indices)

    @property
    def childCount(self):
        return len(self._children)

    def getChildAtIndex(self, index):
        if index in self._failed_indices:
            raise RuntimeError("AT-SPI accessible was disposed")
        return self._children[index]


class DisposedNode:
    @property
    def childCount(self):
        raise RuntimeError("AT-SPI node disappeared")


class AccessibilityTraversalTests(unittest.TestCase):
    def test_none_child_is_not_recursed(self):
        surviving = FakeNode()
        root = FakeNode([None, surviving])
        self.assertEqual(list(atspi.children(root)), [surviving])
        self.assertEqual(list(atspi.walk(root)), [root, surviving])

    def test_removed_child_index_is_skipped(self):
        surviving = FakeNode()
        root = FakeNode([surviving, None], failed_indices={0})
        self.assertEqual(list(atspi.children(root)), [])

    def test_disposed_parent_does_not_crash_retry(self):
        detached = DisposedNode()
        self.assertEqual(list(atspi.children(detached)), [])
        self.assertEqual(list(atspi.walk(detached)), [detached])

    def test_real_child_kept_after_unavailable_index(self):
        surviving = FakeNode()
        root = FakeNode([None, surviving], failed_indices={0})
        self.assertEqual(list(atspi.walk(root)), [root, surviving])


if __name__ == "__main__":
    unittest.main()
