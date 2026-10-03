"""Public release metadata tests; no network, secrets, or macOS tools required."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release/metadata.py"
SPEC = importlib.util.spec_from_file_location("release_metadata", SCRIPT)
metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metadata)

VERSION = "0.5.1"
COMMIT = "a" * 40
SHA256 = "b" * 64
BUILD = 8
INFO = {"SUFeedURL": metadata.FEED_URL, "SUPublicEDKey": metadata.PUBLIC_ED_KEY}
BASIC = {"version": VERSION, "build": BUILD, "commit": COMMIT}


def project(version=VERSION, build=BUILD):
    return (f"\tMARKETING_VERSION = {version};\n\tCURRENT_PROJECT_VERSION = {build};\n") * 4


def appcast(version=VERSION, build=BUILD, size=3, url=None, signature="test-signature", extra=""):
    url = url or f"{metadata.RELEASE_BASE}/appcast/{metadata.asset_name(VERSION)}"
    return f'''<?xml version="1.0"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>{build}</sparkle:version>
    <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
    <enclosure url="{url}" length="{size}" sparkle:edSignature="{signature}" />
  </item>{extra}</channel>
</rss>'''


class MetadataTests(unittest.TestCase):
    def test_strict_versions(self):
        for value in ("0.0.0", "0.5.1", "12.30.401"):
            self.assertEqual(metadata.validate_version(value), value)
        for value in ("v0.5.1", "0.5", "0.5.1.0", "0.5.1-beta", "01.5.1", "0.05.1", "0.5.01", "-1.0.0", "0.5.1\n", " 0.5.1", "０.５.１", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.validate_version(value)

    def test_commit_requires_exact_full_lowercase_head(self):
        self.assertEqual(metadata.validate_commit(COMMIT, COMMIT), COMMIT)
        for value in ("a" * 39, "a" * 41, "A" * 40, "g" * 40, COMMIT + "\n", "HEAD", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.validate_commit(value, COMMIT)
        with self.assertRaisesRegex(ValueError, "git HEAD"):
            metadata.validate_commit(COMMIT, "b" * 40)

    def test_basic_metadata(self):
        self.assertEqual(metadata.basic_metadata(project(), INFO, VERSION, COMMIT, COMMIT), BASIC)

    def test_balanced_quoted_project_values(self):
        self.assertEqual(metadata.project_build(project(version='"0.5.1"', build='"8"'), VERSION), BUILD)
        for value in ('"0.5.1', '0.5.1"', '""0.5.1"'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.project_build(project(version=value), VERSION)

    def test_mixed_or_missing_project_versions(self):
        cases = (
            project().replace("0.5.1", "0.5.0", 1),
            project().replace("MARKETING_VERSION", "OTHER_VERSION", 1),
            project() + "MARKETING_VERSION = 0.5.1;\n",
            project().replace("CURRENT_PROJECT_VERSION = 8", "CURRENT_PROJECT_VERSION = 7", 1),
            project().replace("CURRENT_PROJECT_VERSION", "OTHER_BUILD", 1),
            project(build=0), project(build=-1), project(build="08"), project(build="8.0"),
        )
        for text in cases:
            with self.subTest(text=text), self.assertRaises(ValueError):
                metadata.project_build(text, VERSION)

    def test_sparkle_feed_and_key_are_pinned(self):
        for settings in ({}, {**INFO, "SUFeedURL": "https://example.com/feed.xml"}, {**INFO, "SUPublicEDKey": ""}, {**INFO, "SUPublicEDKey": "another-key"}):
            with self.subTest(settings=settings), self.assertRaises(ValueError):
                metadata.validate_sparkle_settings(settings)

    def test_repository_metadata_checks_git_head(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / metadata.PROJECT).parent.mkdir(parents=True)
            (root / metadata.PROJECT).write_text(project())
            (root / metadata.INFO_PLIST).parent.mkdir(parents=True)
            (root / metadata.INFO_PLIST).write_bytes(metadata.plistlib.dumps(INFO))
            with mock.patch.object(metadata.subprocess, "check_output", return_value=COMMIT + "\n") as git:
                self.assertEqual(metadata.repository_metadata(root, VERSION, COMMIT), BASIC)
                git.assert_called_once_with(["git", "rev-parse", "HEAD"], cwd=root, text=True)
            with mock.patch.object(metadata.subprocess, "check_output", return_value="b" * 40):
                with self.assertRaisesRegex(ValueError, "git HEAD"):
                    metadata.repository_metadata(root, VERSION, COMMIT)


class AppcastTests(unittest.TestCase):
    def test_matching_release(self):
        expected = f"{metadata.RELEASE_BASE}/appcast/QueueScope-0.5.1-macOS.zip"
        self.assertEqual(metadata.validate_appcast(appcast(), VERSION, BUILD, 3), expected)

    def test_legacy_version_attributes(self):
        xml = appcast().replace("<sparkle:version>8</sparkle:version>", "").replace("<sparkle:shortVersionString>0.5.1</sparkle:shortVersionString>", "")
        xml = xml.replace("<enclosure ", '<enclosure sparkle:version="8" sparkle:shortVersionString="0.5.1" ')
        metadata.validate_appcast(xml, VERSION, BUILD, 3)

    def test_wrong_or_missing_release_fields(self):
        cases = (
            appcast(version="0.5.0"), appcast(build=7), appcast(size=2), appcast(size="3x"),
            appcast(url=f"{metadata.RELEASE_BASE}/v0.5.1/QueueScope-0.5.1-macOS.zip"),
            appcast(url=f"{metadata.RELEASE_BASE}/appcast/QueueScope-0.5.0-macOS.zip"),
            appcast(url=f"{metadata.RELEASE_BASE}/appcast/QueueScope-0.5.1-macOS.zip?foo=1"),
            appcast(signature=""), appcast(signature="   "),
            appcast().replace('sparkle:edSignature="test-signature"', ""),
            appcast().replace("<sparkle:version>8</sparkle:version>", ""),
            appcast().replace("<enclosure ", '<enclosure sparkle:version="7" '),
            appcast().replace("</item>", '<enclosure url="extra" /></item>'),
            "<rss><channel /></rss>", "not xml",
        )
        for xml in cases:
            with self.subTest(xml=xml), self.assertRaises(ValueError):
                metadata.validate_appcast(xml, VERSION, BUILD, 3)

    def test_latest_item_must_be_unique_newest_build(self):
        for build in (8, 9):
            other = f'<item><sparkle:version>{build}</sparkle:version><enclosure /></item>'
            with self.subTest(build=build), self.assertRaisesRegex(ValueError, "newest build"):
                metadata.validate_appcast(appcast(extra=other), VERSION, BUILD, 3)
        older = '<item><sparkle:version>7</sparkle:version><enclosure /></item>'
        metadata.validate_appcast(appcast(extra=older), VERSION, BUILD, 3)


class ArtifactTests(unittest.TestCase):
    def test_finalize_hashes_and_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            archive = output / metadata.asset_name(VERSION)
            archive.write_bytes(b"abc")
            (output / "appcast.xml").write_text(appcast())
            with mock.patch.object(metadata, "repository_metadata", return_value=BASIC):
                metadata.validate_release(Path("unused"), output, VERSION, COMMIT)
                result = metadata.finalize_release(Path("unused"), output, VERSION, COMMIT)
            expected_hash = hashlib.sha256(b"abc").hexdigest()
            self.assertEqual(result, {**BASIC, "asset": archive.name, "size": 3, "sha256": expected_hash})
            self.assertEqual(json.loads((output / "manifest.json").read_text()), result)
            checksums = (output / "SHA256SUMS").read_text().splitlines()
            self.assertEqual(len(checksums), 4)
            for line in checksums:
                digest, filename = line.split("  ")
                self.assertEqual(digest, hashlib.sha256((output / filename).read_bytes()).hexdigest())
            first_manifest = (output / "manifest.json").read_bytes()
            first_sums = (output / "SHA256SUMS").read_bytes()
            with mock.patch.object(metadata, "repository_metadata", return_value=BASIC):
                metadata.finalize_release(Path("unused"), output, VERSION, COMMIT)
            self.assertEqual((output / "manifest.json").read_bytes(), first_manifest)
            self.assertEqual((output / "SHA256SUMS").read_bytes(), first_sums)

    def test_finalize_rejects_mixed_validation_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            metadata.write_json(output / "metadata.json", {**BASIC, "commit": "b" * 40})
            with mock.patch.object(metadata, "repository_metadata", return_value=BASIC):
                with self.assertRaisesRegex(ValueError, "metadata.json"):
                    metadata.finalize_release(Path("unused"), output, VERSION, COMMIT)
            self.assertFalse((output / "manifest.json").exists())

    def test_invalid_appcast_cannot_create_manifest_or_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / metadata.asset_name(VERSION)).write_bytes(b"abc")
            (output / "appcast.xml").write_text(appcast(signature=""))
            with mock.patch.object(metadata, "repository_metadata", return_value=BASIC):
                with self.assertRaisesRegex(ValueError, "signature"):
                    metadata.finalize_release(Path("unused"), output, VERSION, COMMIT)
            self.assertFalse((output / "manifest.json").exists())
            self.assertFalse((output / "SHA256SUMS").exists())

    def test_empty_zip_and_invalid_hash_rejected(self):
        for size in (0, -1, True, "3"):
            with self.subTest(size=size), self.assertRaises(ValueError):
                metadata.make_manifest(BASIC, SHA256, size)
        for digest in ("", "b" * 63, "B" * 64, "g" * 64):
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                metadata.make_manifest(BASIC, digest, 3)


class DistributionTests(unittest.TestCase):
    CASK = '''cask "queuescope" do
  version "0.5.0"
  sha256 "old-sha"
  url "https://github.com/raynirola/queuescope/releases/download/v#{version}/QueueScope-#{version}-macOS.zip"
end
'''
    HTML = '''<p>Native macOS · Open source · v0.5.0</p>
<p>QueueScope 0.5.0 requires macOS 14; BullMQ 5.77.x. Updated October 2, 2026.</p>
<script>{"softwareVersion": "0.5.0", "number": "0.5.0"}</script>
<a href="https://github.com/raynirola/queuescope/releases/download/v0.5.0/QueueScope-0.5.0-macOS.zip">Download QueueScope 0.5.0</a>
<p>IP 10.5.0.1; historical metric 0.5.0; v0.5.01; QueueScope 0.5.01.</p>
'''

    def test_targeted_site_versions_leave_other_numbers_unchanged(self):
        updated = metadata.update_site_html(self.HTML, "0.5.0", VERSION)
        for expected in ("· v0.5.1", "QueueScope 0.5.1 requires", '"softwareVersion": "0.5.1"', "/v0.5.1/QueueScope-0.5.1-macOS.zip", "Download QueueScope 0.5.1"):
            self.assertIn(expected, updated)
        for preserved in ("macOS 14", "BullMQ 5.77.x", "October 2, 2026", '"number": "0.5.0"', "10.5.0.1", "historical metric 0.5.0", "v0.5.01", "QueueScope 0.5.01"):
            self.assertIn(preserved, updated)
        self.assertEqual(metadata.update_site_html(updated, "0.5.0", VERSION), updated)

    def test_distribution_update_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cask = root / metadata.CASK
            cask.parent.mkdir(parents=True)
            cask.write_text(self.CASK)
            (root / "site").mkdir()
            for name in ("index.html", "faq.html"):
                (root / "site" / name).write_text(self.HTML)
            changed = metadata.update_distribution(root, VERSION, SHA256)
            self.assertEqual(len(changed), 3)
            self.assertIn('version "0.5.1"', cask.read_text())
            self.assertIn(f'sha256 "{SHA256}"', cask.read_text())
            self.assertIn('/v#{version}/QueueScope-#{version}-macOS.zip', cask.read_text())
            self.assertEqual(metadata.update_distribution(root, VERSION, SHA256), [])
            self.assertEqual((root / "site/index.html").read_text(), (root / "site/faq.html").read_text())

    def test_invalid_or_ambiguous_cask_rejected(self):
        for text in ("", self.CASK + 'version "0.5.0"\n', self.CASK.replace("0.5.0", "v0.5.0")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                metadata.update_cask_text(text, VERSION, SHA256)
        with self.assertRaises(ValueError):
            metadata.update_cask_text(self.CASK, VERSION, "invalid hash")


if __name__ == "__main__":
    unittest.main()
