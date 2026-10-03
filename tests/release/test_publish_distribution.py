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
# Fixed historical inputs: a release updates the real cask and site, so reading
# those files here would silently turn upgrade tests into checksum conflicts.
CASK = '''cask "queuescope" do
  version "0.5.0"
  sha256 "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

  url "https://github.com/raynirola/queuescope/releases/download/v#{version}/QueueScope-#{version}-macOS.zip"
  name "QueueScope"
  desc "Dashboard for BullMQ queues"
  homepage "https://github.com/raynirola/queuescope"

  auto_updates true
  depends_on macos: :sonoma

  app "QueueScope.app"
end
'''
HOMEPAGE = '''<!DOCTYPE html>
<html lang="en"><head>
<script type="application/ld+json">{"@context": "https://schema.org", "@type": "SoftwareApplication", "name": "QueueScope", "softwareVersion": "0.5.0", "downloadUrl": "https://github.com/raynirola/queuescope/releases/download/v0.5.0/QueueScope-0.5.0-macOS.zip"}</script>
</head><body>
<div class="eyebrow">Native macOS · Open source · v0.5.0</div>
<a data-download-location="hero" href="https://github.com/raynirola/queuescope/releases/download/v0.5.0/QueueScope-0.5.0-macOS.zip">Download for Mac</a>
<a data-download-location="install" href="https://github.com/raynirola/queuescope/releases/download/v0.5.0/QueueScope-0.5.0-macOS.zip">Download QueueScope 0.5.0 ↓</a>
<p>QueueScope 0.5.0 requires macOS 14 or later. BullMQ 5.77.x.</p>
<a href="https://github.com/raynirola/queuescope">GitHub</a>
</body></html>
'''
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
        with mock.patch.dict(publication.os.environ, {"HOMEBREW_NO_INSTALL_FROM_API": "1", "GH_TOKEN": "test-only", "GITHUB_TOKEN": "test-only", "HOMEBREW_GITHUB_API_TOKEN": "inherited-write-token"}, clear=True), tempfile.TemporaryDirectory() as directory, mock.patch.object(
                publication.subprocess, "check_output", return_value=directory + "\n"), mock.patch.object(
                publication.subprocess, "run") as run:
            publication.validate_brew_cask(CASK)
            calls = [call.args[0] for call in run.call_args_list]
            self.assertEqual([command[1] for command in calls], ["style", "audit", "fetch"])
            for call in run.call_args_list:
                self.assertNotIn("GH_TOKEN", call.kwargs["env"])
                self.assertNotIn("GITHUB_TOKEN", call.kwargs["env"])
                self.assertNotIn("HOMEBREW_GITHUB_API_TOKEN", call.kwargs["env"])
                self.assertNotIn("HOMEBREW_NO_INSTALL_FROM_API", call.kwargs["env"])
                self.assertEqual(call.kwargs["env"]["HOMEBREW_DEVELOPER"], "1")
                self.assertEqual(call.kwargs["env"]["HOMEBREW_NO_AUTO_UPDATE"], "1")
                self.assertEqual(call.kwargs["env"]["HOMEBREW_NO_ANALYTICS"], "1")
            self.assertTrue(all(command[-1].startswith("queuescope/release-verification-") for command in calls))
            self.assertEqual(list((Path(directory) / "Library/Taps/queuescope").iterdir()), [])
            self.assertEqual(publication.os.environ["HOMEBREW_NO_INSTALL_FROM_API"], "1")


class ReadOnlyCaskTests(unittest.TestCase):
    def tap_github(self, content=CASK):
        gh = mock.Mock(spec=publication.GitHub)
        gh.snapshot.return_value = (HEAD, "tree", {publication.CASK_PATH: entry(publication.CASK_PATH)})
        gh.text.return_value = content
        gh.commit_changes.return_value = "new-commit"
        return gh

    def proposed_digest(self):
        updated = publication.updated_cask(CASK, VERSION, CHECKSUM)
        return hashlib.sha256(updated.encode("utf-8")).hexdigest()

    def test_matching_digest_skips_brew_but_still_verifies_asset(self):
        gh = self.tap_github()
        with mock.patch.dict(publication.os.environ, {"BREW_VALIDATED_CASK_SHA256": self.proposed_digest()}, clear=True), mock.patch.object(
                publication, "verify_public_asset") as asset, mock.patch.object(publication, "validate_brew_cask") as brew:
            self.assertEqual(publication.publish_tap(MANIFEST, gh), "new-commit")
        asset.assert_called_once_with(MANIFEST)
        brew.assert_not_called()
        gh.commit_changes.assert_called_once()

    def test_same_digest_never_bypasses_failed_asset_verification(self):
        gh = self.tap_github()
        with mock.patch.dict(publication.os.environ, {"BREW_VALIDATED_CASK_SHA256": self.proposed_digest()}, clear=True), mock.patch.object(
                publication, "verify_public_asset", side_effect=publication.PublishError("bad ZIP")):
            with self.assertRaisesRegex(publication.PublishError, "bad ZIP"):
                publication.publish_tap(MANIFEST, gh)
        gh.commit_changes.assert_not_called()

    def test_changed_live_cask_rejects_prior_digest_before_commit(self):
        gh = self.tap_github(CASK.replace('desc "Dashboard for BullMQ queues"', 'desc "Updated description"'))
        with mock.patch.dict(publication.os.environ, {"BREW_VALIDATED_CASK_SHA256": self.proposed_digest()}, clear=True), mock.patch.object(
                publication, "verify_public_asset") as asset, mock.patch.object(publication, "validate_brew_cask") as brew:
            with self.assertRaisesRegex(publication.PublishError, "differs from the validated cask"):
                publication.publish_tap(MANIFEST, gh)
        gh.commit_changes.assert_not_called()
        asset.assert_not_called()
        brew.assert_not_called()

    def test_malformed_or_wrong_digest_cannot_fall_back_to_brew(self):
        for digest in ("", "A" * 64, "a" * 63, "a" * 64 + "\n", "0" * 64):
            gh = self.tap_github()
            with self.subTest(digest=digest), mock.patch.dict(publication.os.environ, {"BREW_VALIDATED_CASK_SHA256": digest}, clear=True), mock.patch.object(
                    publication, "validate_brew_cask") as brew:
                with self.assertRaises(publication.PublishError):
                    publication.publish_tap(MANIFEST, gh)
                brew.assert_not_called()
                gh.commit_changes.assert_not_called()

    def test_anonymous_public_cask_validation_is_bounded_and_reports_exact_digest(self):
        response = io.BytesIO(CASK.encode("utf-8"))
        response.read = mock.Mock(wraps=response.read)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            output.write_text("existing=value\n")
            with mock.patch.dict(publication.os.environ, {"GITHUB_OUTPUT": str(output)}, clear=True), mock.patch.object(
                    publication, "public_request", return_value=response) as request, mock.patch.object(
                    publication, "verify_public_asset") as asset, mock.patch.object(publication, "validate_brew_cask") as brew:
                digest = publication.validate_public_cask(MANIFEST)
            self.assertEqual(output.read_text(), f"existing=value\ncask_sha256={digest}\n")
        self.assertEqual(digest, self.proposed_digest())
        request.assert_called_once_with("https://raw.githubusercontent.com/raynirola/homebrew-tap/main/Casks/queuescope.rb")
        response.read.assert_called_once_with(64 * 1024 + 1)
        asset.assert_called_once_with(MANIFEST)
        brew.assert_called_once_with(publication.updated_cask(CASK, VERSION, CHECKSUM))

    def test_oversized_public_cask_cannot_reach_brew(self):
        with mock.patch.object(publication, "public_request", return_value=io.BytesIO(b"x" * (64 * 1024 + 1))), mock.patch.object(
                publication, "verify_public_asset") as asset, mock.patch.object(publication, "validate_brew_cask") as brew:
            with self.assertRaisesRegex(publication.PublishError, "64 KiB"):
                publication.validate_public_cask(MANIFEST)
        asset.assert_not_called()
        brew.assert_not_called()

    def test_public_requests_have_no_auth_and_reject_plain_http_or_redirects(self):
        with mock.patch.object(publication, "build_opener") as opener, mock.patch.dict(
                publication.os.environ, {"GH_TOKEN": "write-token", "GITHUB_TOKEN": "another-write-token"}):
            publication.public_request(publication.PUBLIC_TAP_CASK)
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, publication.PUBLIC_TAP_CASK)
            self.assertIsNone(request.get_header("Authorization"))
            with self.assertRaisesRegex(publication.PublishError, "requires HTTPS"):
                publication.public_request("http://raw.githubusercontent.com/example")
            with self.assertRaisesRegex(publication.PublishError, "insecure"):
                publication.HTTPSRedirectsOnly().redirect_request(None, None, 302, None, {}, "http://example.com/")

    def test_validation_cli_needs_no_gh_token_or_github_api(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            manifest.write_text(json.dumps(MANIFEST))
            with mock.patch.dict(publication.os.environ, {"RELEASE_VERSION": VERSION, "RELEASE_COMMIT": COMMIT}, clear=True), mock.patch.object(
                    sys, "argv", ["publish_distribution.py", "--validate-cask", "--manifest", str(manifest)]), mock.patch.object(
                    publication, "validate_public_cask") as validate, mock.patch.object(publication, "GitHub") as github:
                self.assertEqual(publication.main(), 0)
        validate.assert_called_once_with(MANIFEST)
        github.assert_not_called()

    def test_validation_and_tap_modes_are_mutually_exclusive(self):
        with mock.patch.object(sys, "argv", ["publish_distribution.py", "--validate-cask", "--tap"]), mock.patch.object(
                sys, "stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as error:
                publication.main()
        self.assertEqual(error.exception.code, 2)

    def test_only_explicit_read_only_token_reaches_brew_without_mutating_parent_env(self):
        values = {"GH_TOKEN": "write-token", "GITHUB_TOKEN": "write-token-2", "HOMEBREW_GITHUB_API_TOKEN": "inherited-write-token",
                  "BREW_READONLY_GITHUB_TOKEN": "read-only-token", "HOMEBREW_NO_INSTALL_FROM_API": "1"}
        with mock.patch.dict(publication.os.environ, values, clear=True), tempfile.TemporaryDirectory() as directory, mock.patch.object(
                publication.subprocess, "check_output", return_value=directory + "\n") as root, mock.patch.object(
                publication.subprocess, "run") as run:
            publication.validate_brew_cask(CASK)
            for call in [root.call_args, *run.call_args_list]:
                child = call.kwargs["env"]
                self.assertEqual(child["HOMEBREW_GITHUB_API_TOKEN"], "read-only-token")
                for key in ("GH_TOKEN", "GITHUB_TOKEN", "BREW_READONLY_GITHUB_TOKEN", "HOMEBREW_NO_INSTALL_FROM_API"):
                    self.assertNotIn(key, child)
                self.assertEqual(child["HOMEBREW_DEVELOPER"], "1")
            self.assertEqual(dict(publication.os.environ), values)


class CommitTests(unittest.TestCase):
    def test_tree_preserves_live_base_and_ref_is_never_forced(self):
        gh = publication.GitHub(publication.TAP_REPOSITORY)
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
        gh = publication.GitHub(publication.TAP_REPOSITORY)
        gh.head = mock.Mock(return_value="concurrent-head")
        gh.api = mock.Mock()
        with self.assertRaisesRegex(publication.PublishError, "main moved"):
            gh.commit_changes(HEAD, "tree", {"file": entry("file")}, {"file": "updated"}, "message")
        gh.api.assert_not_called()

    def test_head_move_before_ref_update_leaves_ref_untouched(self):
        gh = publication.GitHub(publication.TAP_REPOSITORY)
        gh.head = mock.Mock(side_effect=[HEAD, "concurrent-head"])
        gh.api = mock.Mock(side_effect=[{"sha": "tree"}, {"sha": "commit"}])
        with self.assertRaisesRegex(publication.PublishError, "main moved"):
            gh.commit_changes(HEAD, "tree", {"file": entry("file")}, {"file": "updated"}, "message")
        self.assertTrue(all(call.kwargs["method"] == "POST" for call in gh.api.call_args_list))

    def test_atomic_ref_conflict_is_not_retried_or_forced(self):
        gh = publication.GitHub(publication.TAP_REPOSITORY)
        gh.head = mock.Mock(return_value=HEAD)
        gh.api = mock.Mock(side_effect=[{"sha": "tree"}, {"sha": "commit"}, publication.PublishError("409")])
        with self.assertRaisesRegex(publication.PublishError, "409"):
            gh.commit_changes(HEAD, "tree", {"file": entry("file")}, {"file": "updated"}, "message")
        self.assertEqual(gh.api.call_count, 3)
        self.assertIs(gh.api.call_args.kwargs["data"]["force"], False)

    def test_noop_is_a_read_only_head_check(self):
        gh = publication.GitHub(publication.TAP_REPOSITORY)
        gh.head = mock.Mock(return_value=HEAD)
        gh.api = mock.Mock()
        self.assertEqual(gh.commit_changes(HEAD, "tree", {}, {}, "message"), HEAD)
        gh.api.assert_not_called()

    def test_symlinks_are_not_loaded_as_source(self):
        gh = publication.GitHub(publication.TAP_REPOSITORY)
        with self.assertRaises(publication.PublishError):
            gh.text({"path": "site/index.html", "type": "blob", "mode": "120000"})


class DistributionTests(unittest.TestCase):
    def test_current_main_edits_are_preserved(self):
        gh, entries = source_github()
        changes = publication.distribution_changes(gh, entries, MANIFEST)
        self.assertEqual(set(changes), {publication.MIRROR_PATH, "site/index.html"})
        self.assertIn("<!-- concurrent copy edit preserved -->", changes["site/index.html"])
        publication.verify_homepage(changes["site/index.html"], VERSION)

    def test_already_published_metadata_is_a_noop(self):
        gh, entries = source_github()
        published = publication.distribution_changes(gh, entries, MANIFEST)
        current = {publication.PROJECT_PATH: project(), **published}
        gh.text.side_effect = lambda item: current[item["path"]]
        self.assertEqual(publication.distribution_changes(gh, entries, MANIFEST), {})

    def test_new_marketing_version_or_build_blocks_old_release(self):
        for version, build in (("0.5.2", 8), (VERSION, 9)):
            gh, entries = source_github(version, build)
            with self.subTest(version=version, build=build), self.assertRaises(publication.PublishError):
                publication.distribution_changes(gh, entries, MANIFEST)

    def test_homepage_requires_actual_links_visible_and_structured_version(self):
        gh, entries = source_github()
        html = publication.distribution_changes(gh, entries, MANIFEST)["site/index.html"]
        invalid = [html.replace(f'href="{publication.release_url(VERSION)}"',
                                f'href="{publication.release_url("0.5.0")}"', 1),
                   html.replace(f'"downloadUrl": "{publication.release_url(VERSION)}"',
                                f'"downloadUrl": "{publication.release_url("0.5.0")}"'),
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
