"""Exercise release shell guards without credentials or network access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/release/publish.sh").read_text()
COMMIT = "a" * 40


def shell_function(name):
    start = SCRIPT.index(name + "() {")
    return SCRIPT[start:SCRIPT.index("\n}\n", start) + 3]


class ReleasePublicationTests(unittest.TestCase):
    def run_guard(self, command, release=None, api_status=0):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work)
            release = release if release is not None else {
                "id": 42, "tag_name": "v0.5.1", "target_commitish": COMMIT,
                "draft": True, "prerelease": False, "assets": [],
            }
            (path / "response.json").write_text(json.dumps(release))
            (path / "payload.zip").write_text("verified artifact")
            shell = '''set -euo pipefail
REPO=raynirola/queuescope
TAG=v0.5.1
VERSION_RELEASE_ID=42
APPCAST_RELEASE_ID=43
gh() {
  if [ "$1" = api ]; then
    test "$API_STATUS" = 0 || return "$API_STATUS"
    cat "$WORK/response.json"
  else
    printf '%s\\n' "$*" >> "$WORK/writes"
  fi
}
''' + shell_function("assert_version_release") + shell_function("ensure_asset") + command
            env = dict(os.environ, WORK=work, RELEASE_COMMIT=COMMIT, API_STATUS=str(api_status))
            result = subprocess.run(["bash", "-c", shell], env=env, capture_output=True, text=True)
            writes = (path / "writes").read_text() if (path / "writes").exists() else ""
            return result, writes

    def test_draft_and_published_identity_can_resume(self):
        for draft in (True, False):
            release = {"id": 42, "tag_name": "v0.5.1", "target_commitish": COMMIT,
                       "draft": draft, "prerelease": False, "assets": []}
            result, writes = self.run_guard('assert_version_release\n', release)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(writes, "")

    def test_wrong_source_identity_or_prerelease_blocks_upload(self):
        for key, value in (("id", 44), ("tag_name", "v0.5.2"), ("target_commitish", "b" * 40),
                           ("draft", "true"), ("prerelease", True), ("assets", None)):
            release = {"id": 42, "tag_name": "v0.5.1", "target_commitish": COMMIT,
                       "draft": True, "prerelease": False, "assets": []}
            release[key] = value
            with self.subTest(key=key):
                result, writes = self.run_guard('assert_version_release\nensure_asset "$TAG" "$WORK/payload.zip"\n', release)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(writes, "")

    def test_asset_lookup_failure_does_not_attempt_upload(self):
        result, writes = self.run_guard('ensure_asset "$TAG" "$WORK/payload.zip"\n', api_status=7)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(writes, "")

    def test_asset_lookup_identity_failure_does_not_attempt_upload(self):
        result, writes = self.run_guard('ensure_asset "$TAG" "$WORK/payload.zip"\n', {"id": 99, "tag_name": "v0.5.1", "assets": []})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(writes, "")

    def test_retargeted_draft_blocks_each_asset_upload(self):
        release = {"id": 42, "tag_name": "v0.5.1", "target_commitish": "b" * 40,
                   "draft": True, "prerelease": False, "assets": []}
        result, writes = self.run_guard('ensure_asset "$TAG" "$WORK/payload.zip"\n', release)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(writes, "")

    def test_verified_absent_asset_is_uploaded_to_exact_tag(self):
        result, writes = self.run_guard('assert_version_release\nensure_asset "$TAG" "$WORK/payload.zip"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release upload v0.5.1 ", writes)
        self.assertIn("--repo raynirola/queuescope", writes)

    def test_version_lookup_never_uses_published_only_tag_endpoint(self):
        self.assertNotIn('releases/tags/$TAG', SCRIPT)
        self.assertNotIn('releases/tags/$tag', SCRIPT)
        self.assertIn('python3 scripts/release/release_lookup.py "$TAG"', SCRIPT)
        self.assertIn('assert_version_release\ngh release edit', SCRIPT)


if __name__ == "__main__":
    unittest.main()
