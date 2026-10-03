"""Offline checks for PR-reviewed distribution updates; no live GitHub calls."""
import importlib.util
from pathlib import Path
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release/publish_distribution.py"
SPEC = importlib.util.spec_from_file_location("distribution_review_publisher", SCRIPT)
publication = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publication)

HEAD = "a" * 40
OTHER = "b" * 40
TREE = "c" * 40
NEW_TREE = "d" * 40
NEW_COMMIT = "e" * 40
VERSION = "0.5.1"
BRANCH = f"release/distribution-v{VERSION}-{HEAD}"
REF = "refs/heads/" + BRANCH
PATH = publication.MIRROR_PATH
ENTRIES = {PATH: {"path": PATH, "mode": "100644", "type": "blob", "sha": "f" * 40}}
CHANGES = {PATH: "updated cask"}
MANIFEST = {"version": VERSION, "commit": HEAD}


def ref(sha=NEW_COMMIT):
    return {"ref": REF, "object": {"type": "commit", "sha": sha}}


def existing(tree=NEW_TREE, parent=HEAD):
    return {"tree": {"sha": tree}, "parents": [{"sha": parent}]}


class ReviewBranchTests(unittest.TestCase):
    def github(self, replies, heads=None):
        gh = publication.GitHub(publication.REPOSITORY)
        gh.head = mock.Mock(return_value=HEAD) if heads is None else mock.Mock(side_effect=heads)
        gh.api = mock.Mock(side_effect=replies)
        return gh

    def propose(self, gh, changes=CHANGES):
        return gh.propose_distribution_changes(HEAD, TREE, ENTRIES, changes, VERSION)

    def assert_no_main_or_pr_write(self, gh):
        for call in gh.api.call_args_list:
            endpoint = call.args[0]
            method = call.kwargs.get("method", "GET")
            self.assertFalse(endpoint.startswith("pulls"))
            self.assertNotEqual(method, "PATCH")
            if method != "GET":
                self.assertIn(endpoint, {"git/trees", "git/commits", "git/refs"})
                data = call.kwargs["data"]
                self.assertNotIn("force", data)
                if endpoint == "git/refs":
                    self.assertEqual(data["ref"], REF)
                    self.assertNotEqual(data["ref"], "refs/heads/main")

    def test_create_only_branch_preserves_main_tree_and_parent(self):
        gh = self.github([[], {"sha": NEW_TREE}, {"sha": NEW_COMMIT}, ref()])
        self.assertEqual(self.propose(gh), BRANCH)
        calls = gh.api.call_args_list
        self.assertEqual(calls[1].kwargs["data"]["base_tree"], TREE)
        self.assertEqual(calls[1].kwargs["data"]["tree"], [
            {"path": PATH, "mode": "100644", "type": "blob", "content": "updated cask"}])
        self.assertEqual(calls[2].kwargs["data"]["parents"], [HEAD])
        self.assertEqual(calls[3].kwargs["data"], {"ref": REF, "sha": NEW_COMMIT})
        self.assert_no_main_or_pr_write(gh)

    def test_matching_existing_branch_reused_without_commit_or_ref_write(self):
        gh = self.github([[ref()], existing(), {"sha": NEW_TREE}, [ref()]])
        self.assertEqual(self.propose(gh), BRANCH)
        self.assertEqual([call.args[0] for call in gh.api.call_args_list if call.kwargs.get("method") == "POST"], ["git/trees"])
        self.assert_no_main_or_pr_write(gh)

    def test_existing_branch_with_other_parent_is_rejected_before_writes(self):
        gh = self.github([[ref()], existing(parent=OTHER)])
        with self.assertRaisesRegex(publication.PublishError, "branch changed"):
            self.propose(gh)
        self.assertTrue(all(call.kwargs.get("method", "GET") == "GET" for call in gh.api.call_args_list))

    def test_complete_tree_mismatch_rejects_unrelated_edits(self):
        gh = self.github([[ref()], existing(tree=TREE), {"sha": NEW_TREE}])
        with self.assertRaisesRegex(publication.PublishError, "branch changed"):
            self.propose(gh)
        self.assert_no_main_or_pr_write(gh)
        self.assertNotIn("git/refs", [call.args[0] for call in gh.api.call_args_list])

    def test_existing_branch_move_during_verification_is_rejected(self):
        gh = self.github([[ref()], existing(), {"sha": NEW_TREE}, [ref(OTHER)]])
        with self.assertRaisesRegex(publication.PublishError, "branch changed"):
            self.propose(gh)
        self.assert_no_main_or_pr_write(gh)

    def test_concurrent_main_before_start_prevents_all_writes(self):
        gh = self.github([], heads=[OTHER])
        with self.assertRaisesRegex(publication.PublishError, "main moved"):
            self.propose(gh)
        gh.api.assert_not_called()

    def test_concurrent_main_before_branch_creation_prevents_ref_write(self):
        gh = self.github([[], {"sha": NEW_TREE}, {"sha": NEW_COMMIT}], heads=[HEAD, OTHER])
        with self.assertRaisesRegex(publication.PublishError, "main moved"):
            self.propose(gh)
        self.assertNotIn("git/refs", [call.args[0] for call in gh.api.call_args_list])
        self.assert_no_main_or_pr_write(gh)

    def test_concurrent_main_after_branch_creation_fails_without_main_write(self):
        gh = self.github([[], {"sha": NEW_TREE}, {"sha": NEW_COMMIT}, ref()], heads=[HEAD, HEAD, OTHER])
        with self.assertRaisesRegex(publication.PublishError, "main moved"):
            self.propose(gh)
        self.assert_no_main_or_pr_write(gh)
        self.assertEqual(gh.api.call_count, 4)

    def test_concurrent_branch_creation_fails_without_retry_or_overwrite(self):
        gh = self.github([[], {"sha": NEW_TREE}, {"sha": NEW_COMMIT}, publication.PublishError("422 branch exists")])
        with self.assertRaisesRegex(publication.PublishError, "branch exists"):
            self.propose(gh)
        self.assertEqual(gh.api.call_count, 4)
        self.assert_no_main_or_pr_write(gh)

    def test_unexpected_lookup_or_branch_target_fails_closed(self):
        for response in ({}, [None], [ref(), ref()], [{**ref(), "object": {"type": "tag", "sha": NEW_COMMIT}}]):
            gh = self.github([response])
            with self.subTest(response=response), self.assertRaises(publication.PublishError):
                self.propose(gh)
            self.assertEqual(gh.api.call_count, 1)

    def test_review_branch_cannot_change_workflows_or_other_paths(self):
        for path in (".github/workflows/pages.yml", "README.md", "site/../README.html"):
            gh = self.github([])
            with self.subTest(path=path), self.assertRaisesRegex(publication.PublishError, "Unexpected distribution"):
                self.propose(gh, {path: "unapproved"})
            gh.api.assert_not_called()

    def test_direct_main_commit_method_rejects_queuescope_or_other_repositories(self):
        for repository in (publication.REPOSITORY, "another/repository"):
            gh = publication.GitHub(repository)
            gh.api = mock.Mock()
            with self.subTest(repository=repository), self.assertRaisesRegex(publication.PublishError, "restricted to the Homebrew tap"):
                gh.commit_changes(HEAD, TREE, ENTRIES, CHANGES, "message")
            gh.api.assert_not_called()

    def test_review_branch_method_cannot_target_another_repository(self):
        gh = publication.GitHub(publication.TAP_REPOSITORY)
        gh.api = mock.Mock()
        with self.assertRaisesRegex(publication.PublishError, "only in the QueueScope"):
            self.propose(gh)
        gh.api.assert_not_called()


class PublicationReviewTests(unittest.TestCase):
    def github(self):
        gh = mock.Mock(spec=publication.GitHub)
        gh.assert_head = mock.create_autospec(publication.GitHub("unused").assert_head)
        gh.snapshot.return_value = (HEAD, TREE, ENTRIES)
        gh.api.return_value = {"status": "identical"}
        gh.propose_distribution_changes.return_value = BRANCH
        return gh

    def test_changed_metadata_requires_review_without_creating_pr_or_running_pages(self):
        gh = self.github()
        with mock.patch.object(publication, "distribution_changes", return_value=CHANGES), mock.patch.object(
                publication, "verify_public_asset") as asset, mock.patch.object(publication, "deploy_pages") as pages:
            with self.assertRaisesRegex(publication.PublishError, "normal pull request and merge") as error:
                publication.publish_distribution(MANIFEST, gh, 900)
        self.assertIn("https://github.com/raynirola/queuescope/compare/main...", str(error.exception))
        self.assertIn("rerun this failed job", str(error.exception))
        gh.propose_distribution_changes.assert_called_once_with(HEAD, TREE, ENTRIES, CHANGES, VERSION)
        gh.commit_changes.assert_not_called()
        pages.assert_not_called()
        asset.assert_called_once_with(MANIFEST)
        self.assertEqual(gh.api.call_count, 1)

    def test_merged_metadata_rerun_verifies_pages_without_branch_write(self):
        gh = self.github()
        with mock.patch.object(publication, "distribution_changes", return_value={}), mock.patch.object(
                publication, "verify_public_asset") as asset, mock.patch.object(publication, "deploy_pages") as pages:
            self.assertEqual(publication.publish_distribution(MANIFEST, gh, 900), HEAD)
        gh.propose_distribution_changes.assert_not_called()
        gh.commit_changes.assert_not_called()
        gh.assert_head.assert_called_once_with(HEAD)
        pages.assert_called_once_with(gh, HEAD, VERSION, 900)
        asset.assert_called_once_with(MANIFEST)


if __name__ == "__main__":
    unittest.main()
