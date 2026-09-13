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

# 3. A model_routes section with nothing to anchor on is a state the script does not understand,
#    and guessing an insertion point in someone's config is worse than stopping.
cat >"$T/anchorless.yaml" <<'EOF'
gateway:
  providers:
    openrouter:
      model_routes: {}
EOF
run "$T/anchorless.yaml"
if ((RC == 1)); then pass "model_routes with no api_key: anchor still fails"; else fail "an anchorless model_routes exited $RC, want 1"; fi

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
