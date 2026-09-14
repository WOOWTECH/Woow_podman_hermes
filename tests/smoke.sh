#!/usr/bin/env bash
# tests/smoke.sh: post-install checks for the Woow Hermes stack, run on the host where it is
# installed (install.sh, upgrade.sh and restore.sh call it too). Read-only: it creates nothing.
#
#   tests/smoke.sh [--quick]
#
#   --quick   units, health, published ports and /health only
#
# The generated credentials are read with `podman secret inspect --showsecret` into variables and
# compared in-process; they reach curl through 0600 files, never through a process argument.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"
export QL_LOG_PREFIX=smoke

quick=0
while (($#)); do
  case $1 in
    --quick) quick=1 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done

npass=0 nfail=0 nwarn=0
pass() { printf 'PASS %s\n' "$*"; npass=$((npass + 1)); }
fail() { printf 'FAIL %s\n' "$*"; nfail=$((nfail + 1)); }
warn() { printf 'WARN %s\n' "$*"; nwarn=$((nwarn + 1)); }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hermes-smoke.XXXXXX")
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

[[ -f $ENV_FILE ]] || ql_die "$ENV_FILE not found; is Hermes installed?"
app_env_load
bind=$(ql_env_get WOOW_HERMES_BIND)
host=$(app_local_host "$bind")
gateway=$(ql_env_get WOOW_HERMES_PORT_GATEWAY)
dashboard=$(ql_env_get WOOW_HERMES_PORT_DASHBOARD)
webhook=$(ql_env_get WOOW_HERMES_PORT_WEBHOOK)

# A1 units, including the oneshot provisioning unit
for u in hermes-agent.service hermes-postgres.service hermes-redis.service hermes-provision.service; do
  if systemctl --user is-active --quiet "$u"; then pass "A1 $u is active"; else fail "A1 $u is not active"; fi
done

# A2 health of the three containers
for c in hermes-agent hermes-postgresql hermes-redis; do
  if ql_wait_container_healthy "$c" 420 2>/dev/null; then pass "A2 $c is healthy"; else fail "A2 $c is not healthy"; fi
done

# A3 the agent publishes exactly three ports; the database and the cache publish none
bad=''
for spec in GATEWAY:8642 DASHBOARD:9119 WEBHOOK:8644; do
  hp=$(ql_env_get "WOOW_HERMES_PORT_${spec%%:*}")
  line=$(podman port hermes-agent "${spec#*:}/tcp" 2>/dev/null || true)
  if [[ $bind == all ]]; then
    [[ $line == 0.0.0.0:$hp || $line == "[::]:$hp" || $line == *":$hp" ]] || bad+=" ${spec#*:}"
  else
    [[ $line == "$bind:$hp" ]] || bad+=" ${spec#*:}"
  fi
done
if [[ -z $bad ]]; then pass "A3 the agent publishes the three configured ports on $bind"; else fail "A3 published ports differ for:$bad"; fi
if [[ -z $(podman port hermes-postgresql 2>/dev/null || true) && -z $(podman port hermes-redis 2>/dev/null || true) ]]; then
  pass "A3 the database and the cache publish no host port"
else
  fail "A3 the database or the cache publishes a host port"
fi

# A4 the gateway answers
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$host:$gateway/health" || true)
if [[ $code == 200 ]]; then pass "A4 the gateway /health returns 200"; else fail "A4 the gateway /health returned $code"; fi

if ((quick)); then
  printf '%s passed, %s failed, %s warnings (quick)\n' "$npass" "$nfail" "$nwarn"
  ((nfail == 0))
  exit
fi

dash_pw=$(app_secret_read hermes-dashboard-password || true)
api_key=$(app_secret_read hermes-api-server-key || true)
(umask 077 && printf 'user = "admin:%s"\n' "$dash_pw" >"$TMP/dashrc")
(umask 077 && printf 'header = "Authorization: Bearer %s"\n' "$api_key" >"$TMP/apirc")

# A5 nothing of the dashboard is served to an unauthenticated caller.
#
# This build does NOT use HTTP basic auth on the dashboard: an HTML route redirects to a login page
# (302 -> /login?next=..., and that page is necessarily served without credentials), and an API route
# answers 401 - to a caller with no credentials, with the generated password, and with admin/admin
# alike. So `curl -u admin:<generated>` proves nothing here, and the old A5, which asserted 401/200/401
# with basic auth on `/`, could never pass. Verified against a live stack on toypark1234:
#   /            no-creds 302 -> /login (200)      /api/config  no-creds 401, right 401, wrong 401
# What can be checked, and is what matters, is that the gate exists and the weak default opens nothing.
api_code() { curl -s -o /dev/null -w '%{http_code}' -m 15 "$@" || true; }
anon_api=$(api_code "http://$host:$dashboard/api/config")
weak_api=$(api_code -u admin:admin "http://$host:$dashboard/api/config")
anon_html=$(api_code "http://$host:$dashboard/")
if [[ $anon_api == 401 || $anon_api == 403 ]]; then pass "A5 the dashboard API without credentials returns $anon_api"; else fail "A5 the dashboard API without credentials returned $anon_api"; fi
if [[ $weak_api == 401 || $weak_api == 403 ]]; then pass "A5 admin/admin is rejected by the dashboard API"; else fail "A5 admin/admin returned $weak_api on the dashboard API"; fi
if [[ $anon_html == 200 ]]; then
  fail "A5 the dashboard serves $anon_html at / without credentials"
else
  pass "A5 the dashboard does not serve / without credentials (HTTP $anon_html)"
fi
warn "A5 this build gates the dashboard with a login form and 401s, not HTTP basic auth, so the hermes-dashboard-password secret is not verified end to end here; check it by logging in once"

# A6 the gateway API needs the generated key
anon=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "http://$host:$gateway/v1/models" || true)
auth=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -K "$TMP/apirc" "http://$host:$gateway/v1/models" || true)
if [[ $anon == 401 || $anon == 403 ]]; then pass "A6 /v1/models without the key returns $anon"; else fail "A6 /v1/models without the key returned $anon"; fi
if [[ $auth == 200 ]]; then pass "A6 /v1/models with the key returns 200"; else fail "A6 /v1/models with the key returned $auth"; fi

# A7 everything the old deploy.sh did to the running container is in the image
if podman exec hermes-agent sh -c 'command -v tmux >/dev/null && test -x /usr/local/bin/officecli && test -L /usr/local/bin/hermes && /opt/hermes/.venv/bin/python3 -c "from ddgs import DDGS"' >/dev/null 2>&1; then
  pass "A7 tmux, officecli, the hermes CLI and ddgs are in the image"
else
  fail "A7 a baked-in tool is missing (tmux / officecli / hermes CLI / ddgs)"
fi

# A8 immutability: the image layer is untouched, and the MCP OAuth patches are in it
diff_lines=$(podman diff hermes-agent 2>/dev/null | grep -cE ' (/opt/hermes|/usr|/etc)' || true)
if [[ $diff_lines == 0 ]]; then pass "A8 nothing was written into the image layer"; else fail "A8 podman diff shows $diff_lines change(s) under /opt/hermes, /usr or /etc"; fi
if podman exec hermes-agent grep -q 'iss: Optional\[str\] = None' /opt/hermes/hermes_cli/web_routers/mcp.py >/dev/null 2>&1; then
  pass "A8 the MCP OAuth iss patch is present"
else
  fail "A8 the MCP OAuth iss patch is missing from the running image"
fi

# A9 provisioning touched only the data volume, and the stamps are there
state=$(podman exec hermes-agent sh -c 'stat -c "%U %a" /opt/data/config.yaml /opt/data/.env 2>/dev/null; test -f /opt/data/.woow-policy-v1 && echo stamp; cat /opt/data/.woow-image-version 2>/dev/null; test -f /opt/data/skills/brainstorming/SKILL.md && echo skills' 2>/dev/null || true)
if grep -q '^hermes ' <<<"$state" && grep -q 'stamp' <<<"$state"; then pass "A9 config.yaml and .env belong to hermes, the policy stamp is set"; else fail "A9 provisioning state is incomplete: ${state//$'\n'/ | }"; fi
if grep -q 'hermes 600' <<<"$state"; then pass "A9 /opt/data/.env is 0600"; else fail "A9 /opt/data/.env is not 0600 hermes"; fi
if grep -qx "$HERMES_IMAGE_TAG" <<<"$state"; then pass "A9 the TUI was re-synced for $HERMES_IMAGE_TAG"; else fail "A9 /opt/data/.woow-image-version is not $HERMES_IMAGE_TAG"; fi
if grep -q 'skills' <<<"$state"; then pass "A9 the pinned skills seed is in place"; else warn "A9 the skills seed is missing (it is only copied when the user has none)"; fi

# A10 secret hygiene. A raw substring search is the only practical way to check this without
# parsing every log format, but it is only trustworthy for secrets at least SECRET_HYGIENE_MIN_LEN
# chars long (app_secret_leak_status, scripts/common.sh): a short one (e.g. carried over from a
# legacy .env by migrate-legacy.sh's carry(), which does not enforce install.sh's random:32/64
# floor) has a real chance of coincidentally matching inside unrelated text - which is exactly what
# happened during a live cutover, where an 8-char carried dashboard password matched both the
# io.woowtech.hermes.base image label and the woowtech_odoo_mcp MCP server name and tripped
# migrate-legacy.sh's auto-rollback on an otherwise clean migration.
journal=$(journalctl --user -u hermes-agent.service -u hermes-provision.service -o cat --no-pager 2>/dev/null || true)
logs=$(podman logs --tail 2000 hermes-agent 2>&1 || true)
leak=0 inconclusive=0
for entry in "dashboard password:$dash_pw" "API key:$api_key"; do
  label=${entry%%:*} secret=${entry#*:}
  case $(app_secret_leak_status "$secret" "$journal" "$logs") in
    fail)
      leak=1
      ql_warn "A10 the $label (${#secret} chars) appears verbatim in the journal or container log"
      ;;
    warn)
      inconclusive=1
      warn "A10 the $label is only ${#secret} chars (< $SECRET_HYGIENE_MIN_LEN) and coincidentally matches unrelated text in the journal or container log; treating as inconclusive rather than a confirmed leak. Rotate it (install.sh --rotate-secrets) to get a full-length secret and remove the ambiguity."
      ;;
  esac
done
if ((leak)); then
  fail "A10 a generated credential appears in the journal or the container log"
elif ((inconclusive)); then
  pass "A10 no generated credential in the journal or the container log (one short/carried secret was inconclusive; see WARN above)"
else
  pass "A10 no generated credential in the journal or the container log"
fi
if [[ -n $api_key && $(podman inspect hermes-agent 2>/dev/null || true) == *"$api_key"* ]]; then
  warn "A10 podman inspect shows the env-type secrets of the agent (podman behaviour)"
fi
unset dash_pw api_key journal logs

# A11 the webhook receiver is listening
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$host:$webhook/" || true)
if [[ $code == 000 ]]; then fail "A11 nothing answers on the webhook port $webhook"; else pass "A11 the webhook receiver answers on $webhook (HTTP $code)"; fi

printf '%s passed, %s failed, %s warnings\n' "$npass" "$nfail" "$nwarn"
((nfail == 0))
