#!/usr/bin/env python3
"""Verify a universal Mach-O from lipo's architecture listing."""
import subprocess
import sys


def verify_architectures(output):
    found = set(output.split())
    expected = {"arm64", "x86_64"}
    if found != expected:
        raise ValueError(f"Expected arm64 and x86_64 slices; found {sorted(found)}")


def verify_binary(path):
    # Listing is supported consistently across Apple's lipo versions; avoid
    # -verify_arch's variable-length argument parsing differences.
    output = subprocess.check_output(["lipo", "-archs", str(path)], text=True)
    verify_architectures(output)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: architectures.py MACH_O_PATH")
    try:
        verify_binary(sys.argv[1])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
