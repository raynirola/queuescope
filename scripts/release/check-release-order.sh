#!/bin/bash
set -euo pipefail
: "${RELEASE_VERSION:?}" "${GH_TOKEN:?}"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/queuescope-order.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
gh api --paginate 'repos/raynirola/queuescope/releases?per_page=100' \
  --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' > "$WORK/tags"
python3 - "$WORK/tags" "$RELEASE_VERSION" <<'PY'
import re,sys
target=tuple(map(int,sys.argv[2].split('.')))
for tag in open(sys.argv[1]):
    tag=tag.strip()
    if re.fullmatch(r'v\d+\.\d+\.\d+',tag) and tuple(map(int,tag[1:].split('.'))) > target:
        raise SystemExit('A newer public GitHub release already exists: '+tag)
PY
