#!/usr/bin/env bash
# GH_TOKEN must be the fine-grained Contents:write token for raynirola/homebrew-tap.
# The shared publisher verifies the public ZIP, stages only the current cask's
# version/hash, and runs brew style, audit and fetch before any remote write.
# Git's non-forced ref update rejects a concurrent main commit; unlike Contents
# PUT's file-SHA guard, this also protects concurrent changes to other tap files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
command -v brew >/dev/null || { echo '::error::Homebrew is required to validate the cask'; exit 1; }
command -v gh >/dev/null || { echo '::error::GitHub CLI is required'; exit 1; }
exec python3 scripts/release/publish_distribution.py --tap "$@"
