"""Regression checks for macOS-only packaging command contracts."""
from pathlib import Path
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/release"))
import architectures


class PackagingCommandTests(unittest.TestCase):
    def test_universal_architectures_accept_either_order(self):
        for output in ("arm64 x86_64\n", "x86_64 arm64\n", "  arm64\n x86_64  "):
            architectures.verify_architectures(output)

    def test_thin_missing_and_unexpected_slices_fail(self):
        for output in ("arm64", "x86_64", "", "arm64 x86_64 arm64e", "lipo: error"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                architectures.verify_architectures(output)

    def test_lipo_listing_uses_a_separate_quoted_path_argument(self):
        with mock.patch.object(architectures.subprocess, "check_output", return_value="x86_64 arm64\n") as run:
            architectures.verify_binary("/tmp/Queue Scope.app/Contents/MacOS/QueueScope")
        run.assert_called_once_with(["lipo", "-archs", "/tmp/Queue Scope.app/Contents/MacOS/QueueScope"], text=True)

    def test_package_uses_the_checked_helper_for_every_binary(self):
        script = (ROOT / "scripts/release/package.sh").read_text()
        self.assertNotIn("-verify_arch", script)
        self.assertEqual(script.count('python3 "$ROOT/scripts/release/architectures.py"'), 2)


if __name__ == "__main__":
    unittest.main()
