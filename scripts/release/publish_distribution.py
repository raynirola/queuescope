#!/usr/bin/env python3
"""Publish verified release metadata without git credentials or force pushes.

Uses gh's API authentication from GH_TOKEN. The tap entry point deliberately
requires a separate, tap-scoped Contents:write token. No credentials are put in
URLs, subprocess arguments, a git checkout, or downloaded public requests.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import time
from html.parser import HTMLParser
from urllib.error import URLError
from urllib.parse import urlencode, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

REPOSITORY = "raynirola/queuescope"
TAP_REPOSITORY = "raynirola/homebrew-tap"
CASK_PATH = "Casks/queuescope.rb"
MIRROR_PATH = "distribution/" + CASK_PATH
PROJECT_PATH = "BullMQDashboard.xcodeproj/project.pbxproj"
CASK_URL = ('https://github.com/raynirola/queuescope/releases/download/'
            'v#{version}/QueueScope-#{version}-macOS.zip')
PUBLIC_SITE = "https://queuescope.app/"
PUBLIC_TAP_CASK = f"https://raw.githubusercontent.com/{TAP_REPOSITORY}/main/{CASK_PATH}"
MAX_PUBLIC_CASK_BYTES = 64 * 1024


class PublishError(RuntimeError):
    """A safe, user-actionable publication failure."""


def version_tuple(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value):
        raise PublishError(f"Expected a stable three-part version, got {value!r}")
    return tuple(map(int, value.split(".")))


def release_url(version: str) -> str:
    version_tuple(version)
    return f"https://github.com/{REPOSITORY}/releases/download/v{version}/QueueScope-{version}-macOS.zip"


def load_manifest(path: Path, version: str, commit: str) -> dict:
    version_tuple(version)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise PublishError("RELEASE_COMMIT must be a full lowercase 40-character commit SHA")
    data = json.loads(path.read_text())
    if data.get("version") != version or data.get("commit") != commit:
        raise PublishError("Release manifest does not match RELEASE_VERSION and RELEASE_COMMIT")
    if data.get("asset") != f"QueueScope-{version}-macOS.zip":
        raise PublishError("Unexpected release asset name in manifest")
    if not re.fullmatch(r"[0-9a-f]{64}", str(data.get("sha256", ""))):
        raise PublishError("Release manifest has no valid SHA-256")
    if type(data.get("build")) is not int or data["build"] <= 0:
        raise PublishError("Release manifest has no positive build number")
    if type(data.get("size")) is not int or data["size"] <= 0:
        raise PublishError("Release manifest has no positive byte size")
    return data


class HTTPSRedirectsOnly(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlparse(newurl).scheme != "https":
            raise PublishError("Refusing an insecure public download redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def public_request(url: str):
    if urlparse(url).scheme != "https":
        raise PublishError("Public verification requires HTTPS")
    # Deliberately unauthenticated: proves that users can actually download it.
    request = Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "QueueScope-release-verification"})
    return build_opener(HTTPSRedirectsOnly()).open(request, timeout=60)


def verify_public_asset(manifest: dict) -> None:
    digest = hashlib.sha256()
    length = 0
    with public_request(release_url(manifest["version"])) as response:
        while chunk := response.read(1024 * 1024):
            length += len(chunk)
            if length > manifest["size"]:
                raise PublishError("Public release ZIP is larger than the verified artifact")
            digest.update(chunk)
    if length != manifest["size"] or digest.hexdigest() != manifest["sha256"]:
        raise PublishError("Public release ZIP does not match the verified size and SHA-256")
    print(f"Verified public ZIP: {manifest['asset']} ({length} bytes)", flush=True)


def updated_cask(source: str, version: str, sha256: str) -> str:
    target_version = version_tuple(version)
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise PublishError("Invalid cask SHA-256")
    versions = re.findall(r'^  version "([^"\n]+)"$', source, re.M)
    hashes = re.findall(r'^  sha256 "([0-9a-f]{64})"$', source, re.M)
    urls = re.findall(r'^  url "([^"\n]+)"$', source, re.M)
    if len(versions) != 1 or len(hashes) != 1 or urls != [CASK_URL]:
        raise PublishError("Unexpected cask version, hash, or URL; refusing to rewrite it")
    old_version = version_tuple(versions[0])
    if old_version > target_version:
        raise PublishError(f"Cask already has newer version {versions[0]}; refusing downgrade")
    if old_version == target_version and hashes[0] != sha256:
        raise PublishError("Cask has this version with a different checksum; immutable release conflict")
    result = re.sub(r'^  version "[^"\n]+"$', f'  version "{version}"', source, flags=re.M)
    return re.sub(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{sha256}"', result, flags=re.M)


class GitHub:
    def __init__(self, repository: str):
        self.prefix = f"repos/{repository}"

    def api(self, endpoint: str, *, method: str = "GET", data=None):
        command = ["gh", "api", "--hostname", "github.com", "--method", method,
                   "-H", "Accept: application/vnd.github+json",
                   "-H", "X-GitHub-Api-Version: 2022-11-28", f"{self.prefix}/{endpoint}"]
        if data is not None:
            command += ["--input", "-"]
        # Do not retry an uncertain write. A fresh run will inspect remote state.
        try:
            result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                                    text=True, capture_output=True, timeout=90, check=False)
        except subprocess.TimeoutExpired as exc:
            raise PublishError(f"GitHub {method} {endpoint} timed out; inspect remote state before rerunning") from exc
        if result.returncode:
            raise PublishError(f"GitHub {method} {endpoint} failed: {result.stderr.strip()}")
        return json.loads(result.stdout) if result.stdout.strip() else None

    def head(self) -> str:
        result = self.api("git/ref/heads/main")
        if result["object"]["type"] != "commit":
            raise PublishError("main does not point to a commit")
        return result["object"]["sha"]

    def snapshot(self) -> tuple[str, str, dict]:
        head = self.head()
        commit = self.api(f"git/commits/{head}")
        tree_sha = commit["tree"]["sha"]
        tree = self.api(f"git/trees/{tree_sha}?recursive=1")
        if tree.get("truncated"):
            raise PublishError("Repository tree was truncated; no files have been changed")
        return head, tree_sha, {entry["path"]: entry for entry in tree["tree"]}

    def text(self, entry: dict) -> str:
        if entry.get("type") != "blob" or entry.get("mode") not in {"100644", "100755"}:
            raise PublishError(f"Expected a regular tracked file: {entry.get('path')}")
        blob = self.api(f"git/blobs/{entry['sha']}")
        if blob.get("encoding") != "base64":
            raise PublishError("Unexpected GitHub blob encoding")
        return base64.b64decode(blob["content"], validate=False).decode("utf-8")

    def assert_head(self, expected: str) -> None:
        if self.head() != expected:
            raise PublishError("main moved during publication; rerun after reviewing the newer commit")

    def commit_changes(self, head: str, tree_sha: str, entries: dict,
                       changes: dict[str, str], message: str) -> str:
        if not changes:
            self.assert_head(head)
            return head
        self.assert_head(head)
        tree = self.api("git/trees", method="POST", data={"base_tree": tree_sha, "tree": [
            {"path": path, "mode": entries[path]["mode"], "type": "blob", "content": content}
            for path, content in sorted(changes.items())
        ]})
        commit = self.api("git/commits", method="POST", data={
            "message": message, "tree": tree["sha"], "parents": [head]})
        self.assert_head(head)
        # A concurrent ordinary commit is a sibling, never an ancestor of ours.
        # Thus this atomic fast-forward check rejects it instead of overwriting.
        result = self.api("git/refs/heads/main", method="PATCH", data={
            "sha": commit["sha"], "force": False})
        if result["object"]["sha"] != commit["sha"]:
            raise PublishError("GitHub returned an unexpected branch update; inspect main before rerunning")
        print(f"Published {len(changes)} metadata file(s): {commit['sha']}", flush=True)
        return commit["sha"]


def required_entry(entries: dict, path: str) -> dict:
    try:
        return entries[path]
    except KeyError as exc:
        raise PublishError(f"Required file missing on current main: {path}") from exc


def validate_brew_cask(content: str) -> None:
    """Validate in an isolated local tap; never install the app or mutate a real tap."""
    environment = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_ANALYTICS="1",
                       HOMEBREW_DEVELOPER="1")
    # Developer commands must not persistently enable developer mode. Keep
    # API-backed core metadata available so audit does not bootstrap a core tap.
    # An inherited legacy flag is just as problematic as setting it ourselves.
    environment.pop("HOMEBREW_NO_INSTALL_FROM_API", None)
    # Homebrew only needs the public artifact and public cask metadata. Do not
    # give cask evaluation access to the token that can write the tap.
    for key in ("GH_TOKEN", "GITHUB_TOKEN", "HOMEBREW_GITHUB_API_TOKEN"):
        environment.pop(key, None)
    # The validation job explicitly supplies this token with contents:read only.
    # Never repurpose an inherited API token, whose write scope is unknown.
    read_only_token = environment.pop("BREW_READONLY_GITHUB_TOKEN", None)
    if read_only_token:
        environment["HOMEBREW_GITHUB_API_TOKEN"] = read_only_token
    brew_root = Path(subprocess.check_output(["brew", "--repository"], text=True, env=environment).strip())
    tap_parent = brew_root / "Library/Taps/queuescope"
    tap_parent.mkdir(parents=True, exist_ok=True)
    # A uniquely named temporary tap lets brew audit/fetch load a local cask on
    # Homebrew versions that no longer accept arbitrary cask file paths.
    with tempfile.TemporaryDirectory(prefix="homebrew-release-verification-", dir=tap_parent) as directory:
        root = Path(directory)
        cask = root / CASK_PATH
        cask.parent.mkdir()
        cask.write_text(content, encoding="utf-8")
        name = "queuescope/" + root.name.removeprefix("homebrew-") + "/queuescope"
        for command in (["brew", "style", "--cask", name],
                        ["brew", "audit", "--cask", "--online", name],
                        ["brew", "fetch", "--cask", name]):
            print("Validating: " + " ".join(command), flush=True)
            subprocess.run(command, env=environment, check=True)
        if cask.read_text(encoding="utf-8") != content:
            raise PublishError("Homebrew validation unexpectedly modified the proposed cask")


def validate_public_cask(manifest: dict) -> str:
    """Read-only CI phase: validate exact proposed tap bytes and report their hash."""
    with public_request(PUBLIC_TAP_CASK) as response:
        payload = response.read(MAX_PUBLIC_CASK_BYTES + 1)
    if len(payload) > MAX_PUBLIC_CASK_BYTES:
        raise PublishError("Public tap cask exceeded the 64 KiB validation size limit")
    updated = updated_cask(payload.decode("utf-8"), manifest["version"], manifest["sha256"])
    verify_public_asset(manifest)
    validate_brew_cask(updated)
    digest = hashlib.sha256(updated.encode("utf-8")).hexdigest()
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"cask_sha256={digest}\n")
    print(f"Validated cask SHA-256: {digest}", flush=True)
    return digest


def publish_tap(manifest: dict, github: GitHub) -> str:
    head, tree_sha, entries = github.snapshot()
    source = github.text(required_entry(entries, CASK_PATH))
    updated = updated_cask(source, manifest["version"], manifest["sha256"])
    validated_digest = os.environ.get("BREW_VALIDATED_CASK_SHA256")
    if validated_digest is not None:
        if not re.fullmatch(r"[0-9a-f]{64}", validated_digest):
            raise PublishError("BREW_VALIDATED_CASK_SHA256 must be exactly 64 lowercase hexadecimal characters")
        if hashlib.sha256(updated.encode("utf-8")).hexdigest() != validated_digest:
            raise PublishError("Live tap cask differs from the validated cask; rerun read-only validation before publishing")
    verify_public_asset(manifest)
    if validated_digest is None:
        validate_brew_cask(updated)
    else:
        print("Fresh proposed cask matches the read-only Homebrew validation digest", flush=True)
    changes = {} if source == updated else {CASK_PATH: updated}
    result = github.commit_changes(head, tree_sha, entries, changes,
                                   f"Update QueueScope to {manifest['version']}")
    if not changes:
        print("Homebrew cask already matches the verified release; no commit needed", flush=True)
    return result


def distribution_changes(github: GitHub, entries: dict, manifest: dict) -> dict[str, str]:
    import metadata
    project = github.text(required_entry(entries, PROJECT_PATH))
    try:
        build = metadata.project_build(project, manifest["version"])
    except ValueError as exc:
        raise PublishError(f"Current main version settings do not match the release: {exc}") from exc
    if build != manifest["build"]:
        raise PublishError("Current main build does not match the release; refusing stale publication")
    paths = [MIRROR_PATH] + sorted(path for path in entries if path.startswith("site/") and path.endswith(".html"))
    if "site/index.html" not in paths:
        raise PublishError("Current main has no website homepage")
    originals = {path: github.text(required_entry(entries, path)) for path in paths}
    # Reject a future/stale cask and unexpected source URL before the shared helper.
    expected_cask = updated_cask(originals[MIRROR_PATH], manifest["version"], manifest["sha256"])
    with tempfile.TemporaryDirectory(prefix="queuescope-distribution-") as directory:
        root = Path(directory)
        for path, content in originals.items():
            if PurePosixPath(path).is_absolute() or ".." in PurePosixPath(path).parts:
                raise PublishError("Unexpected source file path")
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        # Imported from the tested release metadata helper, never from remote main.
        metadata.update_distribution(root, manifest["version"], manifest["sha256"])
        result = {path: (root / path).read_text(encoding="utf-8") for path in paths}
    if result[MIRROR_PATH] != expected_cask:
        raise PublishError("Metadata helper changed more than the cask version/hash")
    verify_homepage(result["site/index.html"], manifest["version"])
    return {path: content for path, content in result.items() if content != originals[path]}


class HomepageParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links: list[str] = []
        self.text: list[str] = []
        self.structured: list[str] = []
        self.in_json = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])
        if tag == "script" and attrs.get("type") == "application/ld+json":
            self.in_json = True

    def handle_endtag(self, tag):
        if tag == "script":
            self.in_json = False

    def handle_data(self, data):
        (self.structured if self.in_json else self.text).append(data)


def verify_homepage(html: str, version: str) -> None:
    parser = HomepageParser()
    parser.feed(html)
    target = release_url(version)
    downloads = [url for url in parser.links if url.startswith(f"https://github.com/{REPOSITORY}/releases/download/")]
    if not downloads or any(url != target for url in downloads):
        raise PublishError("Homepage download links do not all target the verified versioned ZIP")
    apps = []
    for raw in parser.structured:
        value = json.loads(raw)
        apps.extend(value if isinstance(value, list) else [value])
    apps = [app for app in apps if isinstance(app, dict) and app.get("@type") == "SoftwareApplication" and app.get("name") == "QueueScope"]
    if not apps or any(app.get("softwareVersion") != version or app.get("downloadUrl") != target for app in apps):
        raise PublishError("Homepage structured version/download metadata does not match the release")
    visible = " ".join(parser.text)
    if f"v{version}" not in visible or f"Download QueueScope {version}" not in visible:
        raise PublishError("Homepage visible release version does not match")


def pages_runs(github: GitHub, commit: str) -> list[dict]:
    query = urlencode({"head_sha": commit, "event": "workflow_dispatch", "per_page": 100})
    result = github.api("actions/workflows/pages.yml/runs?" + query)
    return [run for run in result["workflow_runs"] if run.get("head_sha") == commit and run.get("event") == "workflow_dispatch"]


def deploy_pages(github: GitHub, commit: str, version: str, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    previous_ids = {run["id"] for run in pages_runs(github, commit)}
    github.assert_head(commit)
    github.api("actions/workflows/pages.yml/dispatches", method="POST", data={"ref": "main"})
    print(f"Requested Pages deployment for exact commit {commit}", flush=True)
    run = None
    while time.monotonic() < deadline:
        candidates = [item for item in pages_runs(github, commit) if item["id"] not in previous_ids]
        if candidates:
            run = max(candidates, key=lambda item: item["id"])
            if run["status"] == "completed":
                if run.get("conclusion") != "success":
                    raise PublishError(f"Pages deployment {run.get('html_url', run['id'])} ended with {run.get('conclusion')}; release metadata is already committed")
                break
        elif github.head() != commit:
            raise PublishError("main moved before Pages recorded the requested commit; inspect the Pages runs and rerun publication")
        time.sleep(min(15, max(0, deadline - time.monotonic())))
    else:
        raise PublishError("Timed out waiting for Pages at the exact distribution commit; check Pages environment approval and workflow logs")
    print(f"Pages workflow succeeded: {run.get('html_url', run['id'])}", flush=True)
    last_error = "Homepage has not been checked"
    while time.monotonic() < deadline:
        try:
            query = urlencode({"release": commit, "check": time.time_ns()})
            with public_request(PUBLIC_SITE + "?" + query) as response:
                if urlparse(response.url).hostname not in {"queuescope.app", "www.queuescope.app"}:
                    raise PublishError("Public homepage redirected away from queuescope.app")
                payload = response.read(2 * 1024 * 1024 + 1)
                if len(payload) > 2 * 1024 * 1024:
                    raise PublishError("Public homepage exceeded the verification size limit")
                verify_homepage(payload.decode("utf-8"), version)
            print(f"Verified {PUBLIC_SITE} serves QueueScope {version} and the versioned ZIP", flush=True)
            return
        except (PublishError, URLError, TimeoutError, UnicodeError, ValueError) as exc:
            last_error = str(exc)
        time.sleep(min(15, max(0, deadline - time.monotonic())))
    raise PublishError(f"Pages succeeded, but public homepage verification timed out: {last_error}")


def publish_distribution(manifest: dict, github: GitHub, timeout: int) -> str:
    head, tree_sha, entries = github.snapshot()
    comparison = github.api(f"compare/{manifest['commit']}...{head}")
    if comparison["status"] not in {"ahead", "identical"}:
        raise PublishError("Released commit is no longer an ancestor of main; refusing publication")
    changes = distribution_changes(github, entries, manifest)
    verify_public_asset(manifest)
    result = github.commit_changes(head, tree_sha, entries, changes,
                                   f"Publish QueueScope {manifest['version']} download metadata")
    deploy_pages(github, result, manifest["version"], timeout)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--tap", action="store_true", help="Validate and update the separate Homebrew tap")
    mode.add_argument("--validate-cask", action="store_true", help="Read-only Homebrew validation; no GH_TOKEN required")
    parser.add_argument("--manifest", type=Path, default=Path("release-output/manifest.json"))
    args = parser.parse_args()
    try:
        if not args.validate_cask and not os.environ.get("GH_TOKEN"):
            raise PublishError("GH_TOKEN is required; use the appropriate repository-scoped token")
        manifest = load_manifest(args.manifest, os.environ.get("RELEASE_VERSION", ""), os.environ.get("RELEASE_COMMIT", ""))
        if args.validate_cask:
            validate_public_cask(manifest)
        elif args.tap:
            publish_tap(manifest, GitHub(TAP_REPOSITORY))
        else:
            timeout = int(os.environ.get("PAGES_TIMEOUT_SECONDS", "900"))
            if not 60 <= timeout <= 1200:
                raise PublishError("PAGES_TIMEOUT_SECONDS must be between 60 and 1200")
            publish_distribution(manifest, GitHub(REPOSITORY), timeout)
        return 0
    except (PublishError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
