#!/usr/bin/env bash
# tests/patch-anchors.sh: check that container/patches/iss-callback.py still matches the upstream
# source at the pinned base tag, before a build gets that far. The patch script exits 1 on a missing
# anchor, so this only moves the failure earlier (and into CI).
#
#   tests/patch-anchors.sh [--tag v2026.8.31]
#
# It downloads three files from the upstream repository, so it needs network access. Without network
# it reports SKIP and exits 0: the build still fails loudly on a moved anchor.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TAG=${2:-}
[[ ${1:-} == --tag && -n $TAG ]] || TAG=$(sed -n 's/.*hermes-agent:\([^@]*\)@.*/\1/p' "$REPO/scripts/common.sh" | head -n1)
[[ -n $TAG ]] || { echo "cannot determine the upstream tag from scripts/common.sh" >&2; exit 1; }
BASE=https://raw.githubusercontent.com/NousResearch/hermes-agent/$TAG
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

files=(hermes_cli/web_routers/mcp.py tools/mcp_dashboard_oauth.py tools/mcp_oauth.py)
for f in "${files[@]}"; do
  mkdir -p "$WORK/$(dirname "$f")"
  if ! curl -fsSL -m 30 -o "$WORK/$f" "$BASE/$f"; then
    echo "SKIP patch-anchors: cannot fetch $BASE/$f (no network?)"
    exit 0
  fi
done

# The patch script chdirs to /opt/hermes and edits in place; run it against the downloaded copy.
cd "$WORK"
if python3 - "$REPO/container/patches/iss-callback.py" <<'PY'
import pathlib, re, sys
src = pathlib.Path(sys.argv[1]).read_text()
# Run the patch script with os.chdir("/opt/hermes") replaced by the current directory.
src = src.replace('os.chdir("/opt/hermes")', 'pass')
exec(compile(src, sys.argv[1], "exec"), {"__name__": "__main__"})
PY
then
  echo "ok   every iss-callback anchor is present in upstream $TAG"
else
  echo "FAIL an iss-callback anchor is missing in upstream $TAG: update container/patches/ or the pinned base"
  exit 1
fi
