#!/usr/bin/env bash
# tests/secret-hygiene.sh: regression test for app_secret_leak_status (scripts/common.sh), the
# helper behind tests/smoke.sh's A10 check.
#
# What it guards, and why it exists
# ----------------------------------
# A10 flags a generated credential that leaked into the journal or the container log with a raw
# substring search: `[[ $haystack == *"$secret"* ]]`. During a real cutover on woowtechopenclaw,
# scripts/migrate-legacy.sh carried over the legacy dashboard password verbatim (carry(), by
# design - it is how every existing API client, webhook sender and saved dashboard login keeps
# working across the migration). That password happened to be only 8 characters, and an 8-char
# alnum string has a real chance of turning up as a literal substring somewhere in a haystack the
# size of a container's logs. It did, twice, against completely unrelated text:
#   - the io.woowtech.hermes.base image label (container/Containerfile), which contains the
#     8-char run "woowtech" between two dots
#   - the woowtech_odoo_mcp MCP server name logged by tools.mcp_tool, which contains the same
#     8-char run before the underscore
# A10 flagged this as a leak, and migrate-legacy.sh's auto-rollback undid an otherwise clean
# migration on the strength of that false positive. Manual inspection confirmed no secret had
# actually leaked anywhere.
#
# app_secret_leak_status fixes this by only trusting a hit as a real leak (status "fail") once the
# secret is at least SECRET_HYGIENE_MIN_LEN chars - short enough that install.sh's generated
# secrets (32/64 chars) are always trusted, long enough that the two real collisions above (an
# 8-char carried secret) are downgraded to "warn" (inconclusive) instead of blocking a migration.
# A genuine leak of a full-length secret must still fail: that is A10's entire reason to exist.
#
# Needs nothing but scripts/lib/quadlet-lib.sh and scripts/common.sh: no container, no unit, no
# network, no podman. REPO must resolve like every other script does (../ from this file).
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
HOME=$(mktemp -d "${TMPDIR:-/tmp}/secret-hygiene-home.XXXXXX")
export HOME
trap 'rm -rf "$HOME"' EXIT
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"

npass=0 nfail=0
FAILED=()
die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

# check <name> <expected-status> <secret> <haystack...>
check() {
  local name=$1 want=$2 secret=$3 got
  shift 3
  got=$(app_secret_leak_status "$secret" "$@")
  if [[ $got == "$want" ]]; then
    npass=$((npass + 1)); printf 'ok    %s (got %s)\n' "$name" "$got"
  else
    nfail=$((nfail + 1)); FAILED+=("$name")
    printf 'FAIL  %s: expected [%s], got [%s]\n' "$name" "$want" "$got"
  fi
}

# ---- the real false-positive scenario (both colliding strings from the woowtechopenclaw cutover)
LABEL_TEXT='LABEL org.opencontainers.image.title="Woow Hermes Agent" org.opencontainers.image.source="https://github.com/WOOWTECH/Woow_podman_hermes" org.opencontainers.image.version="v2026.8.31-woow1" io.woowtech.hermes.base="docker.io/nousresearch/hermes-agent:v2026.8.31@sha256:64923faeae267792bf9bf87fe3b4c4869e35004e360c7df01730ad801b74d524"'
MCP_LOG_TEXT="2026-09-04 15:20:35,344 WARNING tools.mcp_tool: MCP server 'woowtech_odoo_mcp' failed after 5 reconnection attempts, parking; will self-probe every 300s until it recovers (state: degraded -> parked): MCPError: Server returned an error response"
LEGACY_DASH_PW='woowtech' # 8 chars: the real carried, un-rotated legacy dashboard password

check "false-positive: 8-char carried password vs the image label (A10's actual trigger #1)" \
  warn "$LEGACY_DASH_PW" "$LABEL_TEXT"
check "false-positive: 8-char carried password vs the MCP server name (A10's actual trigger #2)" \
  warn "$LEGACY_DASH_PW" "$MCP_LOG_TEXT"
check "false-positive: same, both haystacks scanned together like tests/smoke.sh A10 does" \
  warn "$LEGACY_DASH_PW" "" "$MCP_LOG_TEXT $LABEL_TEXT"

# ---- a genuine leak of a full-length, install.sh-shaped secret must still fail --------------
GENERATED_PW='Xk92pQvT7mLwYbR4Nc3ZdA8sFj1HgEu6' # 32 alnum chars, like random:32
LEAK_LOG="2026-09-14 09:00:00 ERROR hermes_cli.dashboard: basic auth check failed for admin:${GENERATED_PW}"
check "true-positive: a real 32-char secret echoed into a log line still fails" \
  fail "$GENERATED_PW" "$LEAK_LOG"

GENERATED_KEY='7f3c9a1e5d8b2046c1a9e7f4b6d0389217634859026174839261748392617483' # 64+ chars, like random:64
LEAK_LOG2="Authorization: Bearer ${GENERATED_KEY}"
check "true-positive: a real 64-char API key echoed into a log line still fails" \
  fail "$GENERATED_KEY" "$LEAK_LOG2"

# ---- sanity: no hit at all is clean, and an empty secret (never generated) is never a leak ----
check "no hit: a real secret nowhere in the haystack is clean" \
  clean "$GENERATED_PW" "$LABEL_TEXT" "$MCP_LOG_TEXT"
check "empty secret is always clean (podman secret read failed / not set)" \
  clean "" "$LABEL_TEXT" "anything at all, even ''"

# ---- boundary: exactly at SECRET_HYGIENE_MIN_LEN still trusted as a real leak -----------------
BOUNDARY_SECRET=$(printf 'a%.0s' $(seq 1 "$SECRET_HYGIENE_MIN_LEN")) # SECRET_HYGIENE_MIN_LEN chars
check "boundary: a hit exactly SECRET_HYGIENE_MIN_LEN chars long still fails (not downgraded)" \
  fail "$BOUNDARY_SECRET" "prefix-${BOUNDARY_SECRET}-suffix"
SHORT_SECRET=${BOUNDARY_SECRET:1} # one char shorter than the floor
check "boundary: one char under SECRET_HYGIENE_MIN_LEN is downgraded to warn" \
  warn "$SHORT_SECRET" "prefix-${SHORT_SECRET}-suffix"

printf '%s passed, %s failed\n' "$npass" "$nfail"
if ((nfail)); then
  printf 'failed: %s\n' "${FAILED[*]}" >&2
  exit 1
fi
