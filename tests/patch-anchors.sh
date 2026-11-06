#!/usr/bin/env bash
# tests/patch-anchors.sh: check the image patches against the upstream source at the pinned base tag,
# before a build gets that far:
#   - container/patches/scoped-prompt-gc.py accepts the upstream session module (its reviewed source
#     hash) and its output passes its own --check
#   - the upstream contracts that replaced the dropped iss-callback / iss-permissive patches and the
#     approval patch are still there (the same anchors upstream-contract.py and the Containerfile
#     build proof rely on)
#   - what the Paseo host adapter (container/vendor/paseo) hooks into: the dashboard's auth guard and
#     plugin enable set, the s6 dashboard service it reloads, and the privilege-drop shim that execs
#     the venv entry point the adapter's wrapper replaces
# The build fails on the same drift; this only moves the failure earlier (and into CI).
#
#   tests/patch-anchors.sh [--tag v0.22.5]
#
# It downloads seven files from the upstream repository, so it needs network access. Without network
# it reports SKIP and exits 0: the build still fails loudly on a moved anchor.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TAG=${2:-}
[[ ${1:-} == --tag && -n $TAG ]] || TAG=$(sed -n 's/.*hermes-agent:\([^@]*\)@.*/\1/p' "$REPO/scripts/common.sh" | head -n1)
[[ -n $TAG ]] || { echo "cannot determine the upstream tag from scripts/common.sh" >&2; exit 1; }
BASE=https://raw.githubusercontent.com/NousResearch/hermes-agent/$TAG
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

files=(hermes_state_sessions.py hermes_cli/web_routers/mcp.py tools/mcp_oauth.py tools/approval.py
  hermes_cli/web_server.py hermes_cli/plugins_cmd.py docker/hermes-exec-shim.sh docker/s6-rc.d/dashboard/run)
for f in "${files[@]}"; do
  mkdir -p "$WORK/$(dirname "$f")"
  if ! curl -fsSL -m 30 -o "$WORK/$f" "$BASE/$f"; then
    echo "SKIP patch-anchors: cannot fetch $BASE/$f (no network?)"
    exit 0
  fi
done

fails=0
# scoped-prompt-gc.py patches in place, then verifies; run it against a copy of the module.
mkdir -p "$WORK/gc"
cp "$WORK/hermes_state_sessions.py" "$WORK/gc/"
if python3 "$REPO/container/patches/scoped-prompt-gc.py" --directory "$WORK/gc" >/dev/null \
  && python3 "$REPO/container/patches/scoped-prompt-gc.py" --directory "$WORK/gc" --check >/dev/null; then
  echo "ok   scoped-prompt-gc.py applies to upstream $TAG and verifies"
else
  echo "FAIL scoped-prompt-gc.py does not accept upstream $TAG: review the new session module and update its pins"
  fails=$((fails + 1))
fi

# anchor <file> <fixed string> <what>
anchor() {
  if grep -qF -- "$2" "$WORK/$1"; then
    echo "ok   $3"
  else
    echo "FAIL $3: '$2' is gone from $1 in upstream $TAG"
    fails=$((fails + 1))
  fi
}
anchor hermes_cli/web_routers/mcp.py 'iss: Optional[str] = None' "the dashboard OAuth callback still takes the RFC 9207 iss"
anchor tools/mcp_oauth.py '_authorization_code_result(*await dashboard_flow.wait_for_callback())' "the MCP OAuth flow still hands iss to the SDK"
anchor tools/approval.py 'def _presence(' "the approval gate still routes through _presence"
anchor tools/approval.py '_NOTIFIER_BLIND_APPROVAL_PLATFORMS' "unattended platforms still get the deny path"
anchor hermes_cli/web_server.py 'def _require_token(request: Request) -> None:' "the Paseo adapter's auth guard (web_server._require_token) is still there"
anchor hermes_cli/plugins_cmd.py '_get_disabled_set = ' "the Paseo adapter's plugin enable/disable sets are still there"
anchor docker/hermes-exec-shim.sh 'REAL=/opt/hermes/.venv/bin/hermes' "the privilege-drop shim still execs the venv entry point the Paseo wrapper replaces"
anchor docker/s6-rc.d/dashboard/run 's6-setuidgid hermes hermes dashboard' "the dashboard still runs as an s6 service through the hermes entry point"

((fails == 0))
