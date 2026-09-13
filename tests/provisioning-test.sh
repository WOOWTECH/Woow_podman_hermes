#!/usr/bin/env bash
# tests/provisioning-test.sh: container/fix-model-routes.py against the config shapes a real host
# produces. It is the last command of container/rootfs/usr/local/bin/woow-provision, which runs
# under `set -euo pipefail`, so its exit code decides whether hermes-provision.service - and through
# it scripts/install.sh and scripts/migrate-legacy.sh - succeeds.
#
# Needs python3 only; no container, no podman.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SCRIPT=$REPO/container/fix-model-routes.py
T=$(mktemp -d "${TMPDIR:-/tmp}/hermes-provisioning-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
npass=0 nfail=0
pass() { printf 'PASS %s\n' "$*"; npass=$((npass + 1)); }
fail() { printf 'FAIL %s\n' "$*"; nfail=$((nfail + 1)); }

run() { # run <config file> -> sets OUT and RC
  OUT=$(python3 "$SCRIPT" "$1" 2>&1); RC=$?
}

# 1. The state of every gateway that has not been given a provider, and of every config.yaml
#    adopted from the compose deployment: no model_routes section at all. Nothing to add is not a
#    failure - a non-zero exit here failed hermes-provision.service on the toypark1234 rehearsal
#    and took the whole cutover with it.
cat >"$T/no-routes.yaml" <<'EOF'
approvals:
  mode: "off"
terminal:
  backend: local
EOF
before=$(sha256sum <"$T/no-routes.yaml")
run "$T/no-routes.yaml"
if ((RC == 0)); then pass "a config with no model_routes section exits 0"; else fail "a config with no model_routes section exited $RC: $OUT"; fi
if [[ $OUT == *"No model_routes section yet"* ]]; then pass "and says why"; else fail "the message does not explain itself: $OUT"; fi
if [[ $(sha256sum <"$T/no-routes.yaml") == "$before" ]]; then pass "and changes nothing"; else fail "it rewrote a config it had nothing to add to"; fi

# 2. The normal case: a model_routes section with an api_key: line to insert after.
cat >"$T/routes.yaml" <<'EOF'
gateway:
  providers:
    openrouter:
      model_routes:
          "MiniMax-M1":
            model: minimax/minimax-m1
            base_url: https://openrouter.ai/api/v1
            api_key: sk-placeholder
EOF
run "$T/routes.yaml"
if ((RC == 0)); then pass "a config with model_routes exits 0"; else fail "a config with model_routes exited $RC: $OUT"; fi
if grep -q '"@openai:gpt-4o-mini":' "$T/routes.yaml" && grep -q '"@openai-api:gpt-4o-mini":' "$T/routes.yaml"; then
  pass "both prefixed route families were added"
else
  fail "the prefixed routes were not added"
fi
# and it is idempotent: the second run must add nothing and still exit 0
second_before=$(sha256sum <"$T/routes.yaml")
run "$T/routes.yaml"
if ((RC == 0)) && [[ $(sha256sum <"$T/routes.yaml") == "$second_before" ]]; then
  pass "a second run adds nothing and exits 0"
else
  fail "the second run was not idempotent (rc=$RC): $OUT"
fi

# 3. A model_routes section with no configured route to anchor on: also nothing to add, also not a
#    failure. This script only ADDS routes to an existing block.
cat >"$T/anchorless.yaml" <<'EOF'
gateway:
  providers:
    openrouter:
      model_routes: {}
EOF
before=$(sha256sum <"$T/anchorless.yaml")
run "$T/anchorless.yaml"
if ((RC == 0)); then pass "model_routes with no route to anchor on exits 0"; else fail "an anchorless model_routes exited $RC, want 0"; fi
if [[ $OUT == *"no configured route to insert after"* ]]; then pass "and says which of the two cases it is"; else fail "the message does not distinguish the cases: $OUT"; fi
if [[ $(sha256sum <"$T/anchorless.yaml") == "$before" ]]; then pass "and changes nothing"; else fail "it rewrote a config it had nothing to add to"; fi

# 3b. The one that actually bit on toypark1234: the generated config.yaml documents this feature in
#     a comment block that contains both "model_routes:" and "# api_key:". A scan that does not skip
#     comments decides there is a section, finds no anchor, and reports a corrupt config on a
#     perfectly ordinary gateway.
cat >"$T/commented.yaml" <<'EOF'
# Configure via the ``platforms.api_server.extra.model_routes`` gateway
# config block:
#
#   platforms:
#     api_server:
#       extra:
#         model_routes:
#           minimax-m2:
#             model: "minimax/minimax-m1"
#             # api_key: "sk-..."   # optional - per-route UPSTREAM provider key
approvals:
  mode: "off"
EOF
before=$(sha256sum <"$T/commented.yaml")
run "$T/commented.yaml"
if ((RC == 0)); then pass "model_routes mentioned only in comments exits 0"; else fail "a commented model_routes exited $RC, want 0"; fi
if [[ $OUT == *"No model_routes section yet"* ]]; then pass "and is not fooled into thinking a section exists"; else fail "comments were treated as a section: $OUT"; fi
if [[ $(sha256sum <"$T/commented.yaml") == "$before" ]]; then pass "and changes nothing"; else fail "it rewrote a config made of comments"; fi

# 4. woow-provision must keep running it as its last command, so this exit code keeps mattering.
# shellcheck disable=SC2016 # the literal call site in woow-provision, not an expansion
needle='fix-model-routes.py "$CFG"'
if grep -qF -- "$needle" "$REPO/container/rootfs/usr/local/bin/woow-provision"; then
  pass "woow-provision still runs fix-model-routes.py on the live config"
else
  fail "woow-provision no longer runs fix-model-routes.py the way this test assumes"
fi

printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0))
