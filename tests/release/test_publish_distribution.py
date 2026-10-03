"""Offline tests: no GitHub writes, Homebrew execution, or secret access."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/release"))
import publish_distribution as publication

VERSION = "0.5.1"
COMMIT = "a" * 40
HEAD = "b" * 40
CHECKSUM = "c" * 64
CASK = (ROOT / "distribution/Casks/queuescope.rb").read_text()
HOMEPAGE = (ROOT / "site/index.html").read_text()
MANIFEST = {"version": VERSION, "commit": COMMIT, "build": 8,
            "asset": "QueueScope-0.5.1-macOS.zip", "sha256": CHECKSUM, "size": 3}


def project(version=VERSION, build=8):
    return (f"MARKETING_VERSION = {version};\nCURRENT_PROJECT_VERSION = {build};\n") * 4


def entry(path):
    return {"path": path, "type": "blob", "mode": "100644", "sha": path}


def source_github(version=VERSION, build=8):
    data = {publication.PROJECT_PATH: project(version, build),
            publication.MIRROR_PATH: CASK,
            "site/index.html": HOMEPAGE + "\n<!-- concurrent copy edit preserved -->\n"}
    gh = mock.Mock(spec=publication.GitHub)
    # Python 3.9 blocks dynamically created assert* mocks even with a class spec.
    # Assign this real API method explicitly; never disable mock safety globally.
    gh.assert_head = mock.create_autospec(publication.GitHub("unused").assert_head)
    gh.text.side_effect = lambda item: data[item["path"]]
    return gh, {path: entry(path) for path in data}


class ManifestTests(unittest.TestCase):
    def test_strict_version(self):
        self.assertEqual(publication.version_tuple("0.10.11"), (0, 10, 11))
        for version in ("v0.5.1", "0.5", "0.05.1", "0.5.1-beta", "0.5.1\n", "1.2.٣", None):
            with self.subTest(version=version), self.assertRaises(publication.PublishError):
                publication.version_tuple(version)

    def test_manifest_matches_every_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(MANIFEST))
            self.assertEqual(publication.load_manifest(path, VERSION, COMMIT), MANIFEST)
            invalid = [{"version": "0.5.2"}, {"commit": HEAD}, {"asset": "other.zip"},
                       {"sha256": "bad"}, {"size": True}, {"size": 0}, {"build": 0}]
            for change in invalid:
                path.write_text(json.dumps({**MANIFEST, **change}))
                with self.subTest(change=change), self.assertRaises(publication.PublishError):
                    publication.load_manifest(path, VERSION, COMMIT)

    def test_public_asset_is_hashed_and_sized(self):
        manifest = {**MANIFEST, "sha256": hashlib.sha256(b"zip").hexdigest()}
        with mock.patch.object(publication, "public_request", return_value=io.BytesIO(b"zip")) as request:
            publication.verify_public_asset(manifest)
            request.assert_called_once_with(publication.release_url(VERSION))
        for body in (b"different", b"zi", b"ZIP"):
            with mock.patch.object(publication, "public_request", return_value=io.BytesIO(body)):
                with self.subTest(body=body), self.assertRaises(publication.PublishError):
                    publication.verify_public_asset(manifest)


class CaskTests(unittest.TestCase):
    def test_only_version_and_hash_change(self):
        updated = publication.updated_cask(CASK, VERSION, CHECKSUM)
        self.assertEqual(len([line for line in updated.splitlines() if line not in CASK.splitlines()]), 2)
        self.assertIn(publication.CASK_URL, updated)
        self.assertEqual(publication.updated_cask(updated, VERSION, CHECKSUM), updated)

    def test_future_version_hash_conflict_and_url_fail(self):
        future = CASK.replace('version "0.5.0"', 'version "0.6.0"')
        conflict = CASK.replace('version "0.5.0"', 'version "0.5.1"')
        url = CASK.replace("releases/download", "releases/latest/download")
        duplicate = CASK + '\n  version "0.5.0"\n'
        for content in (future, conflict, url, duplicate):
            with self.subTest(content=content), self.assertRaises(publication.PublishError):
                publication.updated_cask(content, VERSION, CHECKSUM)

    def test_brew_validation_runs_before_commit(self):
        gh = mock.Mock(spec=publication.GitHub)
        gh.snapshot.return_value = (HEAD, "tree", {publication.CASK_PATH: entry(publication.CASK_PATH)})
        gh.text.return_value = CASK
        with mock.patch.object(publication, "verify_public_asset"), mock.patch.object(
                publication, "validate_brew_cask", side_effect=publication.PublishError("audit failed")):
            with self.assertRaisesRegex(publication.PublishError, "audit failed"):
                publication.publish_tap(MANIFEST, gh)
        gh.commit_changes.assert_not_called()

    def test_brew_uses_temporary_named_tap_and_all_three_checks(self):
        with mock.patch.dict(publication.os.environ, {"HOMEBREW_NO_INSTALL_FROM_API": "1", "GH_TOKEN": "test-only", "GITHUB_TOKEN": "test-only"}), tempfile.TemporaryDirectory() as directory, mock.patch.object(
                publication.subprocess, "check_output", return_value=directory + "\n"), mock.patch.object(
                publication.subprocess, "run") as run:
            publication.validate_brew_cask(CASK)
            calls = [call.args[0] for call in run.call_args_list]
            self.assertEqual([command[1] for command in calls], ["style", "audit", "fetch"])
            for call in run.call_args_list:
                self.assertNotIn("GH_TOKEN", call.kwargs["env"])
                self.assertNotIn("GITHUB_TOKEN", call.kwargs["env"])
                self.assertNotIn("HOMEBREW_NO_INSTALL_FROM_API", call.kwargs["env"])
                self.assertEqual(call.kwargs["env"]["HOMEBREW_DEVELOPER"], "1")
                self.assertEqual(call.kwargs["env"]["HOMEBREW_NO_AUTO_UPDATE"], "1")
                self.assertEqual(call.kwargs["env"]["HOMEBREW_NO_ANALYTICS"], "1")
            self.assertTrue(all(command[-1].startswith("queuescope/release-verification-") for command in calls))
            self.assertEqual(list((Path(directory) / "Library/Taps/queuescope").iterdir()), [])
            self.assertEqual(publication.os.environ["HOMEBREW_NO_INSTALL_FROM_API"], "1")


class CommitTests(unittest.TestCase):
    def test_tree_preserves_live_base_and_ref_is_never_forced(self):
        gh = publication.GitHub(publication.REPOSITORY)
        gh.head = mock.Mock(return_value=HEAD)
        gh.api = mock.Mock(side_effect=[{"sha": "new-tree"}, {"sha": "new-commit"},
                                        {"object": {"sha": "new-commit"}}])
        result = gh.commit_changes(HEAD, "live-tree", {"file": entry("file")}, {"file": "updated"}, "message")
        self.assertEqual(result, "new-commit")
        calls = gh.api.call_args_list
        self.assertEqual(calls[0].kwargs["data"]["base_tree"], "live-tree")
        self.assertEqual(calls[1].kwargs["data"]["parents"], [HEAD])
        self.assertEqual(calls[2].kwargs["data"], {"sha": "new-commit", "force": False})

    def test_head_move_before_start_writes_nothing(self):
        gh = publication.GitHub(publication.REPOSITORY)
        gh.head = mock.Mock(return_value="concurrent-head")
        gh.api = mock.Mock()
        with self.assertRaisesRegex(publication.PublishError, "main moved"):
            gh.commit_changes(HEAD, "tree", {"file": entry("file")}, {"file": "updated"}, "message")
        gh.api.assert_not_called()

    def test_head_move_before_ref_update_leaves_ref_untouched(self):
        gh = publication.GitHub(publication.REPOSITORY)
        gh.head = mock.Mock(side_effect=[HEAD, "concurrent-head"])
        gh.api = mock.Mock(side_effect=[{"sha": "tree"}, {"sha": "commit"}])
        with self.assertRaisesRegex(publication.PublishError, "main moved"):
            gh.commit_changes(HEAD, "tree", {"file": entry("file")}, {"file": "updated"}, "message")
        self.assertTrue(all(call.kwargs["method"] == "POST" for call in gh.api.call_args_list))

    def test_atomic_ref_conflict_is_not_retried_or_forced(self):
        gh = publication.GitHub(publication.REPOSITORY)
        gh.head = mock.Mock(return_value=HEAD)
        gh.api = mock.Mock(side_effect=[{"sha": "tree"}, {"sha": "commit"}, publication.PublishError("409")])
        with self.assertRaisesRegex(publication.PublishError, "409"):
            gh.commit_changes(HEAD, "tree", {"file": entry("file")}, {"file": "updated"}, "message")
        self.assertEqual(gh.api.call_count, 3)
        self.assertIs(gh.api.call_args.kwargs["data"]["force"], False)

    def test_noop_is_a_read_only_head_check(self):
        gh = publication.GitHub(publication.REPOSITORY)
        gh.head = mock.Mock(return_value=HEAD)
        gh.api = mock.Mock()
        self.assertEqual(gh.commit_changes(HEAD, "tree", {}, {}, "message"), HEAD)
        gh.api.assert_not_called()

    def test_symlinks_are_not_loaded_as_source(self):
        gh = publication.GitHub(publication.REPOSITORY)
        with self.assertRaises(publication.PublishError):
            gh.text({"path": "site/index.html", "type": "blob", "mode": "120000"})


class DistributionTests(unittest.TestCase):
    def test_current_main_edits_are_preserved(self):
        gh, entries = source_github()
        changes = publication.distribution_changes(gh, entries, MANIFEST)
        self.assertEqual(set(changes), {publication.MIRROR_PATH, "site/index.html"})
        self.assertIn("<!-- concurrent copy edit preserved -->", changes["site/index.html"])
        publication.verify_homepage(changes["site/index.html"], VERSION)

    def test_new_marketing_version_or_build_blocks_old_release(self):
        for version, build in (("0.5.2", 8), (VERSION, 9)):
            gh, entries = source_github(version, build)
            with self.subTest(version=version, build=build), self.assertRaises(publication.PublishError):
                publication.distribution_changes(gh, entries, MANIFEST)

    def test_homepage_requires_actual_links_visible_and_structured_version(self):
        gh, entries = source_github()
        html = publication.distribution_changes(gh, entries, MANIFEST)["site/index.html"]
        invalid = [html.replace(publication.release_url(VERSION), publication.release_url("0.5.0"), 1),
                   html.replace(f'"softwareVersion": "{VERSION}"', '"softwareVersion": "0.5.0"'),
                   html.replace(f"Download QueueScope {VERSION}", "Download QueueScope 0.5.0"),
                   HOMEPAGE]
        for content in invalid:
            with self.subTest(content=content[:80]), self.assertRaises(publication.PublishError):
                publication.verify_homepage(content, VERSION)

    def test_pages_run_filter_requires_exact_commit_and_event(self):
        gh = mock.Mock(spec=publication.GitHub)
        good = {"id": 1, "head_sha": HEAD, "event": "workflow_dispatch"}
        gh.api.return_value = {"workflow_runs": [good, {**good, "id": 2, "head_sha": COMMIT},
                                                          {**good, "id": 3, "event": "push"}]}
        self.assertEqual(publication.pages_runs(gh, HEAD), [good])

    def test_pages_failure_is_reported_and_never_verifies_site(self):
        gh = mock.Mock(spec=publication.GitHub)
        gh.assert_head = mock.create_autospec(publication.GitHub("unused").assert_head)
        failed = {"id": 2, "status": "completed", "conclusion": "failure", "html_url": "https://github.com/run/2"}
        with mock.patch.object(publication, "pages_runs", side_effect=[[], [failed]]), mock.patch.object(
                publication, "public_request") as public:
            with self.assertRaisesRegex(publication.PublishError, "ended with failure"):
                publication.deploy_pages(gh, HEAD, VERSION, 60)
            public.assert_not_called()

    def test_pages_excludes_prior_runs_and_verifies_public_site(self):
        gh, entries = source_github()
        html = publication.distribution_changes(gh, entries, MANIFEST)["site/index.html"]
        old = {"id": 1, "status": "completed", "conclusion": "success"}
        new = {**old, "id": 2}
        response = io.BytesIO(html.encode())
        response.url = publication.PUBLIC_SITE
        with mock.patch.object(publication, "pages_runs", side_effect=[[old], [old], [old, new]]), mock.patch.object(
                publication.time, "sleep"), mock.patch.object(publication, "public_request", return_value=response):
            gh.head.return_value = HEAD
            publication.deploy_pages(gh, HEAD, VERSION, 60)
        gh.assert_head.assert_called_once_with(HEAD)
        gh.api.assert_called_once_with("actions/workflows/pages.yml/dispatches", method="POST", data={"ref": "main"})


if __name__ == "__main__":
    unittest.main()
