#!/usr/bin/env python3
"""Validate public release metadata; never read signing credentials.

This checks metadata and signature *presence*, not cryptographic signatures,
code signing, or notarization. Those checks belong to the macOS release job.
All commands resolve repository inputs relative to this script, not the CWD.
"""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
PROJECT = Path("BullMQDashboard.xcodeproj/project.pbxproj")
INFO_PLIST = Path("BullMQDashboard/Info.plist")
CASK = Path("distribution/Casks/queuescope.rb")
RELEASE_BASE = "https://github.com/raynirola/queuescope/releases/download"
FEED_URL = f"{RELEASE_BASE}/appcast/appcast.xml"
PUBLIC_ED_KEY = "wm5B2dbY1t3GYcdr3oB1z2omXQsBtn8d1nVu4GVc8c0="
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def validate_version(version):
    """Return a canonical X.Y.Z version, rejecting prefixes and leading zeros."""
    if not isinstance(version, str) or not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("version must be exactly X.Y.Z, with no leading zeros")
    return version


def validate_commit(commit, head):
    """Require an explicit full lowercase SHA-1 commit matching checkout HEAD."""
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("commit must be a full 40-character lowercase hex SHA")
    if commit != head:
        raise ValueError("requested commit does not match git HEAD")
    return commit


def validate_sha256(sha256):
    if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ValueError("sha256 must be 64 lowercase hexadecimal characters")
    return sha256


def project_build(project_text, version):
    """Check all four app/test configurations and return their common build."""
    validate_version(version)

    def values(setting):
        matches = re.findall(
            rf"^\s*{setting}\s*=\s*([^;\r\n]+)\s*;", project_text, re.MULTILINE
        )
        result = []
        for value in matches:
            value = value.strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            result.append(value)
        return result

    versions = values("MARKETING_VERSION")
    builds = values("CURRENT_PROJECT_VERSION")
    if len(versions) != 4 or versions != [version] * 4:
        raise ValueError("all four MARKETING_VERSION settings must match version")
    if len(builds) != 4 or len(set(builds)) != 1:
        raise ValueError("all four CURRENT_PROJECT_VERSION settings must agree")
    if not re.fullmatch(r"[1-9][0-9]*", builds[0]):
        raise ValueError("CURRENT_PROJECT_VERSION must be a positive integer")
    return int(builds[0])


def validate_sparkle_settings(info):
    """Pin the existing updater feed/key; key rotation requires deliberate review."""
    if info.get("SUFeedURL") != FEED_URL:
        raise ValueError("Info.plist SUFeedURL does not match the stable appcast feed")
    if info.get("SUPublicEDKey") != PUBLIC_ED_KEY:
        raise ValueError("Info.plist SUPublicEDKey is missing or changed")


def basic_metadata(project_text, info, version, commit, head):
    """Pure metadata validation used by the CLI and unit tests."""
    validate_version(version)
    validate_commit(commit, head)
    build = project_build(project_text, version)
    validate_sparkle_settings(info)
    return {"version": version, "build": build, "commit": commit}


def repository_metadata(root, version, commit):
    validate_version(version)
    # Validate format before running git or touching any release files.
    validate_commit(commit, commit)
    head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    with (root / INFO_PLIST).open("rb") as source:
        info = plistlib.load(source)
    return basic_metadata(
        (root / PROJECT).read_text(encoding="utf-8"), info, version, commit, head
    )


def asset_name(version):
    return f"QueueScope-{validate_version(version)}-macOS.zip"


def _sparkle_value(item, enclosure, name):
    """Support current Sparkle elements and legacy enclosure attributes."""
    elements = item.findall(f"{SPARKLE}{name}")
    if len(elements) > 1:
        raise ValueError(f"appcast has duplicate Sparkle {name} values")
    element_value = elements[0].text if elements else None
    if elements and element_value is None:
        raise ValueError(f"appcast Sparkle {name} is empty")
    attribute_value = enclosure.get(f"{SPARKLE}{name}")
    values = [value for value in (element_value, attribute_value) if value is not None]
    if not values or len(set(values)) != 1:
        raise ValueError(f"appcast Sparkle {name} is missing or inconsistent")
    return values[0]


def validate_appcast(xml, version, build, size):
    """Check the newest item against the release, including its primary ZIP."""
    validate_version(version)
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as error:
        raise ValueError("appcast.xml is not valid XML") from error
    channels = root.findall("channel")
    if root.tag != "rss" or len(channels) != 1:
        raise ValueError("appcast must contain one RSS channel")
    items = channels[0].findall("item")
    if not items:
        raise ValueError("appcast has no release items")
    # generate_appcast emits the latest item first. Never silently accept a
    # matching older item buried underneath another release.
    newest = items[0]
    enclosures = newest.findall("enclosure")
    if len(enclosures) != 1:
        raise ValueError("latest appcast item must have exactly one primary enclosure")
    enclosure = enclosures[0]
    if _sparkle_value(newest, enclosure, "shortVersionString") != version:
        raise ValueError("latest appcast version does not match project version")
    if _sparkle_value(newest, enclosure, "version") != str(build):
        raise ValueError("latest appcast build does not match project build")
    for item in items[1:]:
        older_enclosures = item.findall("enclosure")
        if len(older_enclosures) != 1:
            raise ValueError("appcast item must have exactly one primary enclosure")
        older_build = _sparkle_value(item, older_enclosures[0], "version")
        if not re.fullmatch(r"[1-9][0-9]*", older_build) or int(older_build) >= build:
            raise ValueError("appcast latest item is not the unique newest build")
    expected_url = f"{RELEASE_BASE}/appcast/{asset_name(version)}"
    if enclosure.get("url") != expected_url:
        raise ValueError("appcast enclosure URL does not match stable release asset URL")
    signature = enclosure.get(f"{SPARKLE}edSignature", "")
    if not signature.strip():
        raise ValueError("appcast enclosure EdDSA signature is missing")
    length = enclosure.get("length", "")
    if not re.fullmatch(r"[0-9]+", length) or int(length) != size:
        raise ValueError("appcast enclosure length does not match ZIP byte length")
    return expected_url


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def make_manifest(metadata, sha256, size):
    """Build a public-only manifest from already validated release metadata."""
    validate_sha256(sha256)
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise ValueError("release ZIP must not be empty")
    return {
        "version": metadata["version"],
        "build": metadata["build"],
        "commit": metadata["commit"],
        "asset": asset_name(metadata["version"]),
        "sha256": sha256,
        "size": size,
    }


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate_release(root, directory, version, commit):
    metadata = repository_metadata(root, version, commit)
    directory.mkdir(parents=True, exist_ok=True)
    write_json(directory / "metadata.json", metadata)
    return metadata


def finalize_release(root, directory, version, commit):
    metadata = repository_metadata(root, version, commit)
    metadata_path = directory / "metadata.json"
    if metadata_path.exists():
        saved = json.loads(metadata_path.read_text(encoding="utf-8"))
        if saved != metadata:
            raise ValueError("metadata.json does not match this version/build/commit")
    archive = directory / asset_name(version)
    appcast = directory / "appcast.xml"
    size = archive.stat().st_size
    validate_appcast(appcast.read_bytes(), version, metadata["build"], size)
    manifest = make_manifest(metadata, sha256_file(archive), size)
    write_json(directory / "manifest.json", manifest)
    checksum_files = [archive, appcast, directory / "manifest.json"]
    if metadata_path.exists():
        checksum_files.append(metadata_path)
    (directory / "SHA256SUMS").write_text(
        "".join(
            f"{sha256_file(path)}  {path.name}\n"
            for path in sorted(checksum_files, key=lambda path: path.name)
        ),
        encoding="utf-8",
    )
    return manifest


def update_cask_text(text, version, sha256):
    """Return (previous version, updated cask), requiring unambiguous fields."""
    validate_version(version)
    validate_sha256(sha256)
    version_pattern = r'^(\s*version\s+)"([^"]+)"([ \t]*)$'
    sha_pattern = r'^(\s*sha256\s+)"([^"]+)"([ \t]*)$'
    versions = list(re.finditer(version_pattern, text, re.MULTILINE))
    hashes = list(re.finditer(sha_pattern, text, re.MULTILINE))
    if len(versions) != 1 or len(hashes) != 1:
        raise ValueError("cask must contain exactly one version and sha256 field")
    old_version = validate_version(versions[0].group(2))
    text = re.sub(
        version_pattern,
        lambda match: f'{match.group(1)}"{version}"{match.group(3)}',
        text,
        flags=re.MULTILINE,
    )
    text = re.sub(
        sha_pattern,
        lambda match: f'{match.group(1)}"{sha256}"{match.group(3)}',
        text,
        flags=re.MULTILINE,
    )
    return old_version, text


def update_site_html(text, old_version, version):
    """Replace current QueueScope version contexts, leaving other numbers intact."""
    validate_version(old_version)
    validate_version(version)
    old = re.escape(old_version)
    text = text.replace(
        f"{RELEASE_BASE}/v{old_version}/{asset_name(old_version)}",
        f"{RELEASE_BASE}/v{version}/{asset_name(version)}",
    )
    patterns = (
        rf"(QueueScope-)({old})(-macOS\.zip)",
        rf"(\bQueueScope\s+v?)({old})(?![\w.])",
        rf'("softwareVersion"\s*:\s*")({old})(")',
        rf"((?<![\w./])v)({old})(?![\w.])",
    )
    for pattern in patterns:
        text = re.sub(
            pattern,
            lambda match: (
                match.group(1) + version
                + (match.group(3) if match.lastindex == 3 else "")
            ),
            text,
        )
    return text


def update_distribution(root, version, sha256):
    cask_path = root / CASK
    cask_text = cask_path.read_text(encoding="utf-8")
    old_version, updated_cask = update_cask_text(cask_text, version, sha256)
    paths = sorted((root / "site").glob("*.html"))
    if not paths:
        raise ValueError("site contains no HTML files")
    updates = []
    for path in paths:
        original = path.read_text(encoding="utf-8")
        updated = update_site_html(original, old_version, version)
        if updated != original:
            updates.append((path, updated))
    # Read and validate every input before changing any file. Update the cask
    # last so an interrupted run still knows the site's previous version.
    if updated_cask != cask_text:
        updates.append((cask_path, updated_cask))
    for path, text in updates:
        path.write_text(text, encoding="utf-8")
    return [str(path.relative_to(root)) for path, _ in updates]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--version", required=True)
    validate.add_argument("--commit", required=True)
    validate.add_argument("--output", required=True, type=Path)
    finalize = commands.add_parser("finalize")
    finalize.add_argument("--version", required=True)
    finalize.add_argument("--commit", required=True)
    finalize.add_argument("--directory", required=True, type=Path)
    distribution = commands.add_parser("update-distribution")
    distribution.add_argument("--version", required=True)
    distribution.add_argument("--sha256", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            result = validate_release(ROOT, args.output, args.version, args.commit)
        elif args.command == "finalize":
            result = finalize_release(ROOT, args.directory, args.version, args.commit)
        else:
            result = {"updated": update_distribution(ROOT, args.version, args.sha256)}
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"release metadata error: {error}\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
