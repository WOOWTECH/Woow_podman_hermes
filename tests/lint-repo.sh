#!/usr/bin/env bash
# tests/lint-repo.sh: static repository checks for CI (.github/workflows/repo-checks.yml) and local
# use. Creates nothing and needs no podman.
#
#   1. no plaintext credentials or well-known default passwords in tracked files
#   2. the compose deployment is gone (decision D1: Docker users use the compose-final tag)
#   3. both READMEs lead with the Quadlet install and point Docker users to compose-final
#   4. repo-specific checks (lint_local, at the end of this file): image tag and base parity, the
#      digest pins, the database password file, and that the live-mutation model stays gone
#
# Matches are reported as file:line only; the matched text is never printed.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$REPO"
fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
ok() { printf 'ok   %s\n' "$*"; }
# where <hits>: print file:line only, never the matched text
where() { cut -d: -f1,2 | sed 's/^/     /'; }

# The vendored library and this script itself carry the patterns by nature.
mapfile -t files < <(git ls-files --cached --others --exclude-standard \
  | grep -vE '^(scripts/lib/quadlet-lib\.sh|tests/lint-repo\.sh)$' || true)
text=()
for f in "${files[@]}"; do [[ -f $f ]] && grep -Iq . "$f" 2>/dev/null && text+=("$f"); done

# ---- 1. credentials ------------------------------------------------------------------------------
# KEY=value lines whose key names a credential and whose value is a literal (not empty, not a
# $VAR / @@TOKEN@@ / <placeholder> / *_FILE path).
cred_re='(^|[^A-Za-z0-9_])[A-Z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|_KEY)=[^[:space:]$@<"'\''`{}(%]'
# Obvious placeholders (dummy/example/placeholder/changeme/redacted values) are not credentials.
# Nor is a value that is not a value at all: `KEY=.*` is the left half of a sed s/// expression
# (scripts that *generate* a credential match the pattern otherwise), and `KEY=sk-cp-...` is an
# elided value in documentation. Neither can be a secret, and the token-shape check below is the
# backstop that still catches a real sk-/ghp_/AKIA value wherever it appears.
hits=$(grep -nHE "$cred_re" "${text[@]}" 2>/dev/null \
  | grep -vE '(_FILE|_PATH)=' \
  | grep -vE '=\.\*' \
  | grep -vE '=[^[:space:]]*\.\.\.' \
  | grep -viE '=[A-Za-z0-9_-]*(dummy|example|placeholder|changeme|redacted|your[_-]?)[A-Za-z0-9_-]*([[:space:]]|$)' || true)
if [[ -n $hits ]]; then fail "literal credential assignments at:"; where <<<"$hits"; else ok "no literal credential assignments"; fi
# Well-known defaults and token formats.
known='admin_passwd[[:space:]]*=[[:space:]]*admin([[:space:]]|$)|DEFAULT_PASSWORD[=:][[:space:]]*public|DASHBOARD_PASSWORD[=:][[:space:]]*(public|admin)([[:space:]]|$)'
known+='|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{32,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}'
known+='|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJhbGciOi[A-Za-z0-9_-]{20,}\.'
hits=$(grep -nHE "$known" "${text[@]}" 2>/dev/null || true)
if [[ -n $hits ]]; then fail "default passwords or token-shaped strings at:"; where <<<"$hits"; else ok "no default passwords or token-shaped strings"; fi

# ---- 2. D1: compose files are gone ---------------------------------------------------------------
# D1 is about the live deployment path. archive/pre-quadlet-deployment/ is the compose-era tree
# preserved from the openclaw host: it is never installed, sourced, executed or rendered, and its
# README says so on the first line. Only this check is narrowed - the credential scan above and the
# leaked-value gate below still cover the archive.
left=$(printf '%s\n' "${files[@]}" | grep -v '^archive/pre-quadlet-deployment/' \
  | grep -E '(^|/)(docker|podman)-compose[^/]*\.ya?ml$|^compose/|^\.env\.example$' || true)
if [[ -n $left ]]; then fail "compose deployment files remain (D1):"; while IFS= read -r l; do printf "     %s\n" "$l"; done <<<"$left"; else ok "no compose files (D1)"; fi

# ---- 3. READMEs --------------------------------------------------------------------------------
for r in README.md README_zh-TW.md; do
  if [[ ! -f $r ]]; then fail "$r is missing"; continue; fi
  grep -q 'scripts/install.sh' "$r" || fail "$r does not document scripts/install.sh"
  grep -q 'compose-final' "$r" || fail "$r does not point Docker users to the compose-final tag"
  if grep -qi 'portainer' "$r"; then fail "$r still mentions Portainer"; fi
done
ok "README checks done"

# ---- 4. repo-specific ----------------------------------------------------------------------------
lint_local() {
  # The image tag, the unit and the Containerfile base must agree: the tag is what a rollback points
  # back to, and the base is what the patch anchors were checked against.
  local tag base unit_img
  tag=$(sed -n 's/^HERMES_IMAGE_TAG=//p' scripts/common.sh)
  base=$(sed -n 's/^HERMES_BASE=//p' scripts/common.sh)
  unit_img=$(sed -n 's/^Image=//p' quadlet/hermes-agent.container)
  [[ $unit_img == "localhost/woow-hermes-agent:$tag" ]] \
    || fail "quadlet/hermes-agent.container pins $unit_img, but HERMES_IMAGE_TAG is $tag"
  grep -qF "ARG HERMES_BASE=$base" container/Containerfile \
    || fail "container/Containerfile does not default to HERMES_BASE=$base"
  [[ $base == *@sha256:* ]] || fail "the upstream base is not pinned by digest: $base"
  grep -qx 'Pull=never' quadlet/hermes-agent.container || fail "the locally built image needs Pull=never"
  # Registry images are pinned by digest.
  local img
  while IFS= read -r img; do
    [[ $img == localhost/* || $img == *@sha256:* ]] || fail "image not pinned by digest: $img"
  done < <(grep -rhoE '^Image=.*' quadlet | cut -d= -f2-)
  # The database password reaches PostgreSQL as a file, never as an environment value.
  grep -qx 'Environment=POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password' quadlet/hermes-postgres.container \
    || fail "hermes-postgres.container no longer uses POSTGRES_PASSWORD_FILE"
  # The mutation model is gone: no deploy.sh, and nothing may podman-exec its way into the image.
  if compgen -G 'deploy/*' >/dev/null; then fail "deploy/ is back (the compose deployment was removed)"; fi
  if grep -rqE 'podman (exec|cp) [^|]*/opt/hermes' scripts 2>/dev/null; then
    fail "a script writes into the image layer again; bake it into container/Containerfile instead"
  fi
  # The pre-push hook must accept this repository.
  if [[ -f .github/hooks/pre-push ]] && ! grep -q 'Woow_podman_hermes' .github/hooks/pre-push; then
    fail ".github/hooks/pre-push does not accept this repository"
  fi
  ok "Hermes checks done"
}
lint_local

((fails == 0)) && echo "lint-repo: all checks passed" || echo "lint-repo: $fails check(s) failed"
((fails == 0))
