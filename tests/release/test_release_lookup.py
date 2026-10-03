"""Offline draft-aware release lookup tests; never call GitHub or use real tokens."""

import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release/release_lookup.py"
SPEC = importlib.util.spec_from_file_location("release_lookup", SCRIPT)
lookup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lookup)


def release(tag="v0.5.1", ident=123, draft=False):
    return {"id": ident, "tag_name": tag, "draft": draft, "prerelease": False,
            "target_commitish": "a" * 40, "assets": [], "name": "QueueScope"}


class ReleaseListingTests(unittest.TestCase):
    def test_draft_on_later_page_is_returned_as_rest_object(self):
        expected = release(draft=True)
        pages = [[release("v0.5.0", 122)], [release("appcast", 121), expected]]
        self.assertEqual(lookup.find_release(json.dumps(pages), "v0.5.1"), expected)

    def test_published_and_appcast_releases(self):
        for tag in ("v0.5.1", "appcast"):
            expected = release(tag)
            with self.subTest(tag=tag):
                self.assertEqual(lookup.find_release(json.dumps([[expected]]), tag), expected)

    def test_missing_only_after_complete_valid_listing(self):
        for pages in ([[]], [[release("v0.5.0")], []]):
            with self.subTest(pages=pages):
                self.assertIsNone(lookup.find_release(json.dumps(pages), "v0.5.1"))

    def test_match_is_exact(self):
        pages = [[release("v0.5.10"), release("v0.5.1-beta", 124)]]
        self.assertIsNone(lookup.find_release(json.dumps(pages), "v0.5.1"))

    def test_duplicate_tag_rejected_across_pages(self):
        pages = [[release(draft=True)], [release(ident=124)]]
        with self.assertRaisesRegex(lookup.LookupError, "multiple releases"):
            lookup.find_release(json.dumps(pages), "v0.5.1")
        with self.assertRaisesRegex(lookup.LookupError, "multiple releases"):
            lookup.find_release(json.dumps([[release(), release()]]), "v0.5.1")

    def test_malformed_release_ids_rejected_even_on_other_tags(self):
        for ident in (None, "123", 0, -1, True, 1.0):
            pages = [[release("v0.5.0", ident)], [release()]]
            with self.subTest(ident=ident), self.assertRaisesRegex(lookup.LookupError, "release ID"):
                lookup.find_release(json.dumps(pages), "v0.5.1")
        missing_id = release()
        del missing_id["id"]
        with self.assertRaisesRegex(lookup.LookupError, "release ID"):
            lookup.find_release(json.dumps([[missing_id]]), "v0.5.1")

    def test_invalid_or_incomplete_json_pages_are_not_missing(self):
        values = ("", "not JSON", "null", "{}", "[]", '[{"message":"API error"}]',
                  "[null]", "[[null]]", "[[42]]", "[[[]]]", json.dumps([release()]),
                  json.dumps([[release()], {"message": "later page error"}]),
                  json.dumps([[{"id": 123}]]), json.dumps([[release(None)]]))
        for value in values:
            with self.subTest(value=value), self.assertRaises(lookup.LookupError):
                lookup.find_release(value, "v0.5.1")

    def test_nonstandard_json_and_duplicate_keys_rejected(self):
        for text in ('[[{"id":1,"tag_name":"v0.5.1","id":2}]]',
                     '[[{"id":1,"tag_name":"v0.5.1","size":NaN}]]',
                     '[[{"id":1,"tag_name":"v0.5.1","size":Infinity}]]'):
            with self.subTest(text=text), self.assertRaises(lookup.LookupError):
                lookup.find_release(text, "v0.5.1")

    def test_release_state_requires_actual_booleans(self):
        for field in ("draft", "prerelease"):
            for value in (None, "false", "true", 0, 1, []):
                item = {**release(), field: value}
                with self.subTest(field=field, value=value), self.assertRaisesRegex(lookup.LookupError, "boolean"):
                    lookup.find_release(json.dumps([[item]]), "v0.5.1")

    def test_target_commitish_requires_nonempty_string(self):
        for target in (None, "", "   ", 123, False, []):
            with self.subTest(target=target), self.assertRaisesRegex(lookup.LookupError, "target_commitish"):
                lookup.validate_release({**release(), "target_commitish": target}, "v0.5.1")

    def test_assets_require_list_of_named_objects(self):
        for assets in (None, {}, "file.zip", [None], ["file.zip"], [{}], [{"name": 123}], [{"name": ""}], [{"name": "  "}]):
            with self.subTest(assets=assets), self.assertRaises(lookup.LookupError):
                lookup.validate_release({**release(), "assets": assets}, "v0.5.1")
        item = {**release(), "assets": [{"name": "QueueScope-0.5.1-macOS.zip", "id": 789}]}
        self.assertIs(lookup.validate_release(item, "v0.5.1"), item)

    def test_reusable_validator_requires_exact_expected_tag(self):
        item = release()
        self.assertIs(lookup.validate_release(item, "v0.5.1"), item)
        for tag in ("v0.5.10", "appcast"):
            with self.subTest(tag=tag), self.assertRaisesRegex(lookup.LookupError, "exactly match"):
                lookup.validate_release(item, tag)

    def test_strict_tag_format(self):
        for tag in ("appcast", "v0.0.0", "v0.5.1", "v12.34.567"):
            self.assertEqual(lookup.validate_tag(tag), tag)
        for tag in (None, "", "0.5.1", "v01.5.1", "v0.05.1", "v0.5.01", "v0.5.1-beta", "v0.5.1\n", "appcast\n", "v١.2.3", "../main"):
            with self.subTest(tag=tag), self.assertRaises(lookup.LookupError):
                lookup.validate_tag(tag)


class GitHubInvocationTests(unittest.TestCase):
    def setUp(self):
        self.environment = mock.patch.dict(lookup.os.environ, {"GH_TOKEN": "test-secret-never-print"}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_read_only_paginated_subprocess_arguments_and_full_object(self):
        expected = release(draft=True)
        result = subprocess.CompletedProcess([], 0, json.dumps([[expected]]), "")
        with mock.patch.object(lookup.subprocess, "run", return_value=result) as run:
            self.assertEqual(lookup.lookup_release("v0.5.1"), expected)
        run.assert_called_once_with([
            "gh", "api", "--hostname", "github.com", "--method", "GET",
            "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28",
            "repos/raynirola/queuescope/releases?per_page=100", "--paginate", "--slurp",
        ], capture_output=True, text=True, timeout=90, check=False)
        self.assertNotIn("test-secret-never-print", repr(run.call_args))

    def test_api_failures_do_not_become_missing_or_expose_stderr(self):
        for status in (403, 404, 429, 500, 503):
            result = subprocess.CompletedProcess([], 1, "[[]]", f"gh: failure (HTTP {status}) token=test-secret-never-print")
            with self.subTest(status=status), mock.patch.object(lookup.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(lookup.LookupError, f"HTTP {status}") as error:
                    lookup.lookup_release("v0.5.1")
                self.assertNotIn("test-secret", str(error.exception))

    def test_timeout_and_missing_cli_are_failures(self):
        for error in (subprocess.TimeoutExpired(["gh"], 90), FileNotFoundError("gh")):
            with self.subTest(error=error), mock.patch.object(lookup.subprocess, "run", side_effect=error):
                with self.assertRaisesRegex(lookup.LookupError, "existence is unknown"):
                    lookup.lookup_release("v0.5.1")

    def test_absent_authentication_cannot_fall_back_to_public_only_listing(self):
        with mock.patch.dict(lookup.os.environ, {}, clear=True), mock.patch.object(lookup.subprocess, "run") as run:
            with self.assertRaisesRegex(lookup.LookupError, "required"):
                lookup.lookup_release("v0.5.1")
            run.assert_not_called()

    def test_github_token_is_also_an_explicit_authentication_source(self):
        result = subprocess.CompletedProcess([], 0, "[[]]", "")
        with mock.patch.dict(lookup.os.environ, {"GITHUB_TOKEN": "test-only"}, clear=True), mock.patch.object(
                lookup.subprocess, "run", return_value=result):
            self.assertIsNone(lookup.lookup_release("v0.5.1"))

    def test_invalid_tag_rejected_before_api_call(self):
        with mock.patch.object(lookup.subprocess, "run") as run:
            with self.assertRaises(lookup.LookupError):
                lookup.lookup_release("../main")
            run.assert_not_called()

    def test_cli_prints_only_rest_object_or_json_null(self):
        for value in (release(draft=True), None):
            with self.subTest(value=value), mock.patch.object(lookup, "lookup_release", return_value=value), mock.patch.object(
                    lookup.sys, "stdout", new_callable=io.StringIO) as output:
                self.assertEqual(lookup.main(["v0.5.1"]), 0)
                self.assertEqual(json.loads(output.getvalue()), value)
                self.assertEqual(len(output.getvalue().splitlines()), 1)

    def test_cli_failure_has_no_stdout_json_null(self):
        result = subprocess.CompletedProcess([], 1, "[[]]", "gh: HTTP 403 secret=test-secret-never-print")
        with mock.patch.object(lookup.subprocess, "run", return_value=result), mock.patch.object(
                lookup.sys, "stdout", new_callable=io.StringIO) as output, mock.patch.object(
                lookup.sys, "stderr", new_callable=io.StringIO) as error:
            self.assertEqual(lookup.main(["v0.5.1"]), 1)
            self.assertEqual(output.getvalue(), "")
            self.assertIn("HTTP 403", error.getvalue())
            self.assertNotIn("test-secret", error.getvalue())


if __name__ == "__main__":
    unittest.main()
