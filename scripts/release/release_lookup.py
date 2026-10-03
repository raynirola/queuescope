#!/usr/bin/env python3
"""Find a published or draft QueueScope release using an authenticated listing.

The tag endpoint does not reliably expose draft releases. Paginate the complete
REST release list instead; only a successful, well-formed list can mean missing.
This helper is read-only. It never logs tokens, API response errors, or credentials.
"""

import argparse
import json
import os
import re
import subprocess
import sys


REPOSITORY = "raynirola/queuescope"
TAG_PATTERN = r"(?:appcast|v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"


class LookupError(ValueError):
    """The listing could not establish whether the requested release exists."""


def validate_tag(tag):
    if not isinstance(tag, str) or not re.fullmatch(TAG_PATTERN, tag):
        raise LookupError("tag must be appcast or a stable vN.N.N version without leading zeros")
    return tag


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise LookupError("release listing contains duplicate JSON object keys")
        value[key] = item
    return value


def reject_constant(_value):
    raise LookupError("release listing contains nonstandard JSON constants")



def validate_release(release, expected_tag=None):
    """Validate fields used by the publisher without changing the REST object."""
    if not isinstance(release, dict):
        raise LookupError("release listing contains a malformed release object")
    if type(release.get("id")) is not int or release["id"] <= 0:
        raise LookupError("release listing contains a malformed release ID")
    if not isinstance(release.get("tag_name"), str) or not release["tag_name"].strip():
        raise LookupError("release listing contains a malformed release tag")
    if expected_tag is not None and release["tag_name"] != validate_tag(expected_tag):
        raise LookupError("release object does not exactly match the requested tag")
    if any(type(release.get(field)) is not bool for field in ("draft", "prerelease")):
        raise LookupError("release object must contain boolean draft and prerelease fields")
    target = release.get("target_commitish")
    if not isinstance(target, str) or not target.strip():
        raise LookupError("release object must contain a nonempty target_commitish")
    if not isinstance(release.get("assets"), list):
        raise LookupError("release object must contain an assets list")
    for asset in release["assets"]:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str) or not asset["name"].strip():
            raise LookupError("release assets must be objects with nonempty string names")
    return release


def find_release(pages_json, tag):
    """Return one unmodified REST release object, or None after a valid full list."""
    validate_tag(tag)
    try:
        pages = json.loads(pages_json, object_pairs_hook=unique_object, parse_constant=reject_constant)
    except json.JSONDecodeError as exc:
        raise LookupError("release listing is not valid JSON") from exc
    if not isinstance(pages, list) or not pages:
        raise LookupError("release listing must contain at least one paginated response")
    matches = []
    for page in pages:
        if not isinstance(page, list):
            raise LookupError("release listing contains a malformed page")
        for release in page:
            validate_release(release)
            if release["tag_name"] == tag:
                matches.append(validate_release(release, tag))
    if len(matches) > 1:
        raise LookupError("release listing contains multiple releases matching the requested tag")
    return matches[0] if matches else None


def lookup_release(tag):
    validate_tag(tag)
    # An anonymous listing omits drafts and could falsely report a missing tag.
    # Require explicit CI authentication rather than falling back to that result.
    if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        raise LookupError("GH_TOKEN or GITHUB_TOKEN is required for draft-aware release lookup")
    command = [
        "gh", "api", "--hostname", "github.com", "--method", "GET",
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2022-11-28",
        f"repos/{REPOSITORY}/releases?per_page=100", "--paginate", "--slurp",
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    except subprocess.TimeoutExpired as exc:
        raise LookupError("GitHub release listing timed out; release existence is unknown") from exc
    except OSError as exc:
        raise LookupError("Could not execute GitHub CLI; release existence is unknown") from exc
    if result.returncode:
        # Do not echo stderr: it may include credential-bearing diagnostic text.
        # Status alone is safe and keeps authorization/server errors distinct from
        # a successful list with no matching tag.
        status = re.search(r"\bHTTP ([1-5][0-9]{2})\b", result.stderr or "")
        detail = f"HTTP {status.group(1)}" if status else f"exit status {result.returncode}"
        raise LookupError(f"GitHub release listing failed ({detail}); release existence is unknown")
    return find_release(result.stdout, tag)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="appcast or a stable version tag such as v0.5.1")
    args = parser.parse_args(argv)
    try:
        release = lookup_release(args.tag)
    except LookupError as exc:
        print(f"release lookup error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(release, sort_keys=True, separators=(",", ":"), allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
