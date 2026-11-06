#!/usr/bin/env bash
# tests/image-test.sh: boot a built agent image in throwaway containers and check what the image and
# its provisioning promise. Local only (CI does not build the image): it needs podman, ~4 GB of RAM
# and a few minutes. It publishes no host port and touches no installed unit, volume or secret.
#
#   tests/image-test.sh [IMAGE]      default: localhost/woow-hermes-agent:<HERMES_IMAGE_TAG>
#
#   IMAGE_TEST_PREFIX=NAME           prefix of the containers and volumes it creates and removes
#                                    (default hermes-imagetest)
#
# B1 boot on a fresh volume: s6 is PID 1, the gateway and the dashboard answer, both run as uid 1000
# B2 woow-provision (what hermes-provision.service runs) exits 0, twice, and writes its defaults;
#    upstream's approval defaults (smart, cron/unattended deny) are left alone
# B3 /opt/data/.env: a key from the env file (MiniMax, LiteLLM) is applied once; a key edited in the dashboard survives
#    a restart; a changed env-file value is applied; secrets the unit manages are stripped
# B4 a dashboard login survives a restart (HERMES_DASHBOARD_BASIC_AUTH_SECRET)
# B5 the unattended approval gate (tests/test-approval-gate.py) and the scoped prompt GC
#    (tests/run-scoped-prompt-gc-image.py) inside the image
# B6 a volume carried over from the compose stack (everything owned by uid 1000) boots and
#    provisions without an ownership change, and its stale ui-tui copy is removed
# B7 nothing but stage2's account remap is written into the image layer
# P1 the Paseo wrapper keeps upstream's privilege drop: `podman exec ... hermes` as root runs as 1000
# P2 the dashboard carries the Paseo host adapter (/api/hermes-paseo-host/*) behind its login
# P3 with an HTTPS public URL: that origin and HERMES_PASEO_EXTRA_ORIGIN are accepted, others are
#    ORIGIN_DENIED; the extra origin reaches the dashboard canonical; a stale public URL in .env is
#    stripped
# P4 the loopback login (http://127.0.0.1:9119) still works with an HTTPS public URL, and so does a
#    tunnel-shaped login (public Host, X-Forwarded-Proto https from loopback: __Host- Secure cookies)
# P5 a public URL that is not an exact origin: 503 INVALID_DASHBOARD_ORIGIN, login unaffected
# P6 a malformed HERMES_PASEO_EXTRA_ORIGIN stops the boot without echoing the value
#
# The credentials are random throwaway values in a 0600 file; they are never printed.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"
IMAGE=${1:-$HERMES_IMAGE}
PFX=${IMAGE_TEST_PREFIX:-hermes-imagetest}
podman image exists "$IMAGE" || { echo "image $IMAGE not found; build it first (scripts/build-image.sh)" >&2; exit 2; }

npass=0 nfail=0
pass() { printf 'PASS %s\n' "$*"; npass=$((npass + 1)); }
fail() { printf 'FAIL %s\n' "$*"; nfail=$((nfail + 1)); }
check() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/hermes-image-test.XXXXXX")
chmod 700 "$T"
cleanup() {
  podman rm -f -t 10 "$PFX-1" "$PFX-2" "$PFX-3" "$PFX-4" >/dev/null 2>&1 || true
  podman volume rm -f "$PFX-data" "$PFX-data-uid1000" "$PFX-data-paseo" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
cleanup
mkdir -p "$T" && chmod 700 "$T"

rnd() { head -c "$1" /dev/urandom | base64 -w0 | tr -d '/+='; }
# What the unit passes: the Environment= lines, the env file and the four env-type secrets.
write_env() { # write_env <minimax value> [public URL] [HERMES_PASEO_EXTRA_ORIGIN]
  local pub=${2:-http://localhost:19119}
  (umask 077 && cat >"$T/env" <<EOF
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
API_SERVER_CORS_ORIGINS=*
GATEWAY_ALLOW_ALL_USERS=true
HERMES_UID=1000
HERMES_GID=1000
HERMES_DASHBOARD_PUBLIC_URL=$pub
HERMES_BASE_URL=$pub
HERMES_PASEO_EXTRA_ORIGIN=${3:-}
MINIMAX_API_KEY=$1
OPENROUTER_API_KEY=
LITELLM_API_KEY=imagetest-litellm-dummy
API_SERVER_KEY=$API_KEY
WEBHOOK_SECRET=$WEBHOOK
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$DASH_PW
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$SESSION
EOF
  )
}
API_KEY=$(rnd 48) WEBHOOK=$(rnd 48) DASH_PW=$(rnd 24) SESSION=$(rnd 48)

start() { # start <name> <volume>
  podman run -d --name "$1" --env-file "$T/env" --memory=4g --shm-size=1g \
    -v "$2:/opt/data" "$IMAGE" gateway run >/dev/null || return 1
  wait_up "$1"
}
wait_up() {
  local i
  for ((i = 0; i < 60; i++)); do
    podman exec "$1" curl -fsS -o /dev/null http://127.0.0.1:8642/health 2>/dev/null \
      && podman exec "$1" curl -fsS -o /dev/null http://127.0.0.1:9119/login 2>/dev/null && return 0
    sleep 3
  done
  return 1
}
in_c() { podman exec "$C" sh -c "$1" 2>/dev/null; }
cfg() { podman exec -u hermes "$C" /opt/hermes/.venv/bin/hermes config get "$1" 2>&1; }
envkey() { in_c "sed -n 's/^$1=//p' /opt/data/.env"; }

# ---- B1 ------------------------------------------------------------------------------------------
write_env "imagetest-minimax-1"
podman volume create "$PFX-data" >/dev/null
C=$PFX-1
check "B1 the container boots on a fresh volume (gateway /health and dashboard /login answer)" start "$C" "$PFX-data"
check "B1 s6-overlay is PID 1" bash -c "podman exec $C cat /proc/1/cmdline | tr '\\0' ' ' | grep -q s6-svscan"
uids=$(in_c "ps -eo uid=,args= | grep -E 'hermes_cli.main import main.* (dashboard|gateway run)' | grep -v grep | awk '{print \$1}' | sort -u")
check "B1 the gateway and the dashboard run as uid 1000 (HERMES_UID)" test "$uids" = 1000
check "B1 /opt/data belongs to uid 1000" test "$(in_c 'stat -c %u:%g /opt/data')" = 1000:1000

# ---- B2 ------------------------------------------------------------------------------------------
check "B2 woow-provision exits 0" podman exec "$C" /usr/local/bin/woow-provision --wait 300
check "B2 woow-provision exits 0 again (idempotent)" podman exec "$C" /usr/local/bin/woow-provision --wait 60
for kv in web.search_backend=ddgs web.extract_backend=parallel browser.backend=off \
  platforms.webhook.enabled=true approvals.mode=smart approvals.cron_mode=deny approvals.unattended_mode=deny; do
  got=$(cfg "${kv%%=*}")
  check "B2 ${kv%%=*} is ${kv#*=} (got $got)" test "$got" = "${kv#*=}"
done
check "B2 the tools/plugins stamp is set" in_c 'test -f /opt/data/.woow-policy-v1'

# ---- B3/B4 ---------------------------------------------------------------------------------------
check "B3 MINIMAX_API_KEY from the env file is in /opt/data/.env" test "$(envkey MINIMAX_API_KEY)" = imagetest-minimax-1
check "B3 LITELLM_API_KEY from the env file is in /opt/data/.env (Omnigent sessions read only that file)" test "$(envkey LITELLM_API_KEY)" = imagetest-litellm-dummy
check "B3 /opt/data/.env is 0600 hermes" test "$(in_c 'stat -c "%U %a" /opt/data/.env')" = "hermes 600"
# log in through the dashboard, from inside the container (no host port)
login='import json,os,urllib.request as u
r=u.Request("http://127.0.0.1:9119/auth/password-login",data=json.dumps({"provider":"basic","username":"admin","password":os.environ["HERMES_DASHBOARD_BASIC_AUTH_PASSWORD"],"next":"/"}).encode(),headers={"Content-Type":"application/json"})
c=u.urlopen(r).headers.get_all("Set-Cookie")
open("/tmp/imagetest-cookie","w").write("; ".join(x.split(";")[0] for x in c))'
podman exec "$C" /opt/hermes/.venv/bin/python -c "$login" >/dev/null 2>&1
# shellcheck disable=SC2016 # expanded by the container's sh, not here
authed() { in_c 'curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $(cat /tmp/imagetest-cookie)" http://127.0.0.1:9119/api/config'; }
check "B4 the dashboard login works" test "$(authed)" = 200
check "B4 the dashboard API refuses an anonymous caller" bash -c "test \"\$(podman exec $C curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9119/api/config)\" = 401"
# a dashboard edit plus stale copies of two managed secrets, then a restart with the same env file
# (the values go in as arguments: tests/lint-repo.sh flags any literal KEY=value credential)
# shellcheck disable=SC2016 # expanded by the container's sh
podman exec -u hermes "$C" sh -c 'sed -i "s/^MINIMAX_API_KEY=.*/MINIMAX_API_KEY=$1/" /opt/data/.env &&
  printf "API_SERVER_KEY=%s\nHERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\n" "$2" "$2" >>/opt/data/.env' \
  sh imagetest-dashboard-edit imagetest-stale
podman restart -t 30 "$C" >/dev/null
check "B3 the container comes back after a restart" wait_up "$C"
check "B4 the login survives the restart" test "$(authed)" = 200
check "B3 a key edited in the dashboard survives the restart" test "$(envkey MINIMAX_API_KEY)" = imagetest-dashboard-edit
check "B3 secrets the unit manages are stripped from /opt/data/.env" \
  bash -c "! podman exec $C grep -qE '^(API_SERVER_KEY|WEBHOOK_SECRET|HERMES_DASHBOARD_BASIC_AUTH_[A-Z_]*)=' /opt/data/.env"
podman rm -f -t 30 "$C" >/dev/null
write_env "imagetest-minimax-2"
check "B3 the container is recreated with a changed env file" start "$C" "$PFX-data"
check "B3 a changed env-file value is applied" test "$(envkey MINIMAX_API_KEY)" = imagetest-minimax-2

# ---- B7 ------------------------------------------------------------------------------------------
left=$(podman diff "$C" | grep -E ' (/opt/hermes|/usr|/etc)' | grep -vE '^C /etc$|^C /etc/(\.pwd\.lock|passwd-?|group-?|shadow-?|gshadow-?)$' || true)
check "B7 nothing but the account remap is written into the image layer" test -z "$left"
podman rm -f -t 30 "$C" >/dev/null

# ---- B5 ------------------------------------------------------------------------------------------
check "B5 the unattended approval gate refuses cron/API/webhook commands" \
  podman run --rm --name "$PFX-approval" -v "$REPO/tests:/t:ro" --entrypoint /opt/hermes/.venv/bin/python "$IMAGE" /t/test-approval-gate.py
id=$(podman image inspect --format '{{.Id}}' "$IMAGE")
check "B5 the scoped prompt GC holds against the image's real SessionDB" \
  bash -c "python3 '$REPO/tests/run-scoped-prompt-gc-image.py' --image 'sha256:$id' | grep -q '\"expected_result\": true'"

# ---- B6 ------------------------------------------------------------------------------------------
podman volume create "$PFX-data-uid1000" >/dev/null
podman run --rm --name "$PFX-seed" --user 0 -v "$PFX-data-uid1000:/opt/data" --entrypoint sh "$IMAGE" -c '
  set -e; cd /opt/data
  printf "approvals:\n  mode: manual\nterminal:\n  backend: local\n" >config.yaml
  printf "MINIMAX_API_KEY=%s\n" imagetest-compose >.env
  mkdir -p sessions memories skills/brainstorming ui-tui/dist workspace/p
  echo old >skills/brainstorming/SKILL.md; echo x >ui-tui/dist/entry.js; echo w >workspace/p/f
  python3 -c "import sqlite3; c=sqlite3.connect(\"state.db\"); c.execute(\"create table t(x)\"); c.commit()"
  echo v2026.8.31-woow1 >.woow-image-version; touch .woow-policy-v1
  chown -R 1000:1000 /opt/data; chmod 700 /opt/data; chmod 600 .env' >/dev/null
C=$PFX-2
check "B6 the container boots on a uid-1000 (compose-era) volume" start "$C" "$PFX-data-uid1000"
check "B6 woow-provision exits 0 on it" podman exec "$C" /usr/local/bin/woow-provision --wait 300
other=$(in_c 'find /opt/data -path /opt/data/.woow-dotenv -prune -o \( ! -uid 1000 -o ! -gid 1000 \) -print' | head -5)
check "B6 every file still belongs to 1000:1000 (only .woow-dotenv is root's)" test -z "$other"
check "B6 the stale /opt/data/ui-tui copy is gone" in_c 'test ! -e /opt/data/ui-tui'
check "B6 the existing approvals.mode (manual) is kept" test "$(cfg approvals.mode)" = manual

# ---- P1-P6: Paseo ---------------------------------------------------------------------------------
# What the owner runs: the dashboard behind an HTTPS tunnel, the loopback as the extra origin (with a
# trailing slash, which the boot hook drops).
PUB=https://hermes-p2.example
write_env "imagetest-minimax-3" "$PUB" "http://127.0.0.1:9119/"
podman volume create "$PFX-data-paseo" >/dev/null
C=$PFX-3
check "P  the container boots with an HTTPS public URL and an extra Paseo origin" start "$C" "$PFX-data-paseo"
# P1: the root exec path goes through /opt/hermes/bin/hermes (s6-setuidgid) into the wrapper; the
# pycache the wrapper's Python writes is owned by whoever ran it (the image sets
# PYTHONDONTWRITEBYTECODE=1; empty turns it off). The opt-out is the control.
podman exec -e PYTHONDONTWRITEBYTECODE= -e PYTHONPYCACHEPREFIX=/tmp/p1-drop "$C" hermes --version >/dev/null 2>&1
podman exec -e PYTHONDONTWRITEBYTECODE= -e PYTHONPYCACHEPREFIX=/tmp/p1-root -e HERMES_DOCKER_EXEC_AS_ROOT=1 "$C" hermes --version >/dev/null 2>&1
check "P1 podman exec ... hermes (as root) runs the CLI as uid 1000" test "$(in_c 'stat -c %u /tmp/p1-drop')" = 1000
check "P1 the control: HERMES_DOCKER_EXEC_AS_ROOT=1 keeps root" test "$(in_c 'stat -c %u /tmp/p1-root')" = 0
# shellcheck disable=SC2016 # expanded by the container's sh
check "P1 the venv entry point is the Paseo wrapper, the shim is upstream's" \
  in_c 'grep -q "from dashboard_control import install" /opt/hermes/.venv/bin/hermes && cmp -s /opt/hermes/bin/hermes /opt/hermes/docker/hermes-exec-shim.sh && test "$(command -v hermes)" = /opt/hermes/bin/hermes'
# req <method> <path> [curl args...]: "<status> <detail>" of a dashboard request from inside the container
# shellcheck disable=SC2016 # expanded by the container's sh
req() {
  local m=$1 path=$2
  shift 2
  podman exec "$C" sh -c 'm=$1 p=$2; shift 2; code=$(curl -s -o /tmp/p-body -w "%{http_code}" -X "$m" "$@" "http://127.0.0.1:9119$p"); printf "%s %s" "$code" "$(sed -n "s/.*\"detail\": *\"\([A-Z_]*\)\".*/\1/p" /tmp/p-body)"' \
    sh "$m" "$path" "$@" 2>/dev/null
}
# login [curl args...]: log in with the dashboard password, keep the cookie in /tmp/p-cookie
# shellcheck disable=SC2016,SC2120 # expanded by the container's sh; check passes the arguments
login() {
  podman exec "$C" sh -c 'rm -f /tmp/p-cookie; curl -s -o /dev/null -D /tmp/p-headers -c /tmp/p-cookie "$@" -H "Content-Type: application/json" \
    --data "{\"provider\":\"basic\",\"username\":\"admin\",\"password\":\"$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD\",\"next\":\"/\"}" \
    http://127.0.0.1:9119/auth/password-login' sh "$@" >/dev/null 2>&1
}
CAP=/api/hermes-paseo-host/capabilities
check "P2 the adapter route refuses an anonymous caller (401)" test "$(req GET $CAP -H "Origin: $PUB" | cut -d' ' -f1)" = 401
check "P4 the loopback login works with an HTTPS public URL" login
check "P4 the loopback session reaches the API" test "$(req GET /api/config -b /tmp/p-cookie | cut -d' ' -f1)" = 200
# Not installed yet, so an accepted origin ends at PLUGIN_DISABLED, the check after the origin check:
# that 403 proves the adapter is mounted and the origin passed.
check "P2/P3 the public HTTPS origin is accepted by the adapter" test "$(req GET $CAP -b /tmp/p-cookie -H "Origin: $PUB")" = "403 PLUGIN_DISABLED"
check "P3 the extra (loopback) origin is accepted" test "$(req GET $CAP -b /tmp/p-cookie -H 'Origin: http://127.0.0.1:9119')" = "403 PLUGIN_DISABLED"
check "P3 another origin is refused" test "$(req GET $CAP -b /tmp/p-cookie -H 'Origin: https://evil.example')" = "403 ORIGIN_DENIED"
check "P3 localhost is not 127.0.0.1" test "$(req GET $CAP -b /tmp/p-cookie -H 'Origin: http://localhost:9119')" = "403 ORIGIN_DENIED"
check "P3 the extra origin reaches the dashboard canonical" \
  test "$(in_c 'cat /run/s6/container_environment/HERMES_PASEO_INGRESS_ORIGIN')" = http://127.0.0.1:9119
# What cloudflared sends to the published port: the public Host and X-Forwarded-Proto https.
check "P4 a tunnel-shaped login works" login -H 'Host: hermes-p2.example' -H 'X-Forwarded-Proto: https'
check "P4 ... and gets __Host- Secure cookies" in_c 'grep -i "^set-cookie: __Host-" /tmp/p-headers | grep -qi "secure"'
# curl never sends a Secure cookie over http://, so replay them as a header, as the browser would
in_c 'sed -n "s/^[Ss]et-[Cc]ookie: \(__Host-[^;]*\);.*/\1/p" /tmp/p-headers | paste -sd";" | sed "s/;/; /g" >/tmp/p-tunnel-cookie'
# shellcheck disable=SC2016 # expanded by the container's sh
check "P4 ... which reach the API through the same proxy headers" \
  test "$(req GET /api/config -H 'Host: hermes-p2.example' -H 'X-Forwarded-Proto: https' -H "Cookie: $(in_c 'cat /tmp/p-tunnel-cookie')" | cut -d' ' -f1)" = 200
# a stale public URL in .env (`hermes dashboard register` writes one) would override hermes.env
podman exec -u hermes "$C" sh -c 'printf "HERMES_DASHBOARD_PUBLIC_URL=http://stale.example\nHERMES_PASEO_INGRESS_ORIGIN=\n" >>/opt/data/.env'
podman restart -t 30 "$C" >/dev/null
check "P3 the container comes back after a restart" wait_up "$C"
check "P3 a public URL or Paseo origin in /opt/data/.env is stripped" \
  bash -c "! podman exec $C grep -qE '^(HERMES_DASHBOARD_PUBLIC_URL|HERMES_BASE_URL|HERMES_PASEO_[A-Z_]*)=' /opt/data/.env"
# shellcheck disable=SC2119 # no extra curl arguments: the plain loopback login
login
check "P3 the public origin is still the accepted one after the restart" test "$(req GET $CAP -b /tmp/p-cookie -H "Origin: $PUB")" = "403 PLUGIN_DISABLED"
podman rm -f -t 30 "$C" >/dev/null

# P5: a public URL with a path is fine for OAuth, but the adapter cannot derive an origin from it
write_env "imagetest-minimax-3" "$PUB/hermes"
check "P5 the container boots with a public URL that has a path" start "$C" "$PFX-data-paseo"
check "P5 the loopback login still works" login
check "P5 the adapter answers 503 INVALID_DASHBOARD_ORIGIN" test "$(req GET $CAP -b /tmp/p-cookie -H "Origin: $PUB")" = "503 INVALID_DASHBOARD_ORIGIN"
check "P5 ... also without an Origin header" test "$(req GET $CAP -b /tmp/p-cookie)" = "503 INVALID_DASHBOARD_ORIGIN"
podman rm -f -t 30 "$C" >/dev/null

# P6: a malformed extra origin stops the boot (S6_BEHAVIOUR_IF_STAGE2_FAILS=2), as on Home Assistant
write_env "imagetest-minimax-3" "$PUB" "https://admin:p6-unique-marker@hermes-p2.example"
C=$PFX-4
podman run -d --name "$C" --env-file "$T/env" --memory=4g -v "$PFX-data-paseo:/opt/data" "$IMAGE" gateway run >/dev/null
stopped() { [[ $(podman inspect --format '{{.State.Status}}' "$C" 2>/dev/null) == exited ]]; }
p6=0
for ((i = 0; i < 40; i++)); do stopped && { p6=1; break; }; sleep 3; done
check "P6 a malformed HERMES_PASEO_EXTRA_ORIGIN stops the container" test "$p6" = 1
logs=$(podman logs "$C" 2>&1)
check "P6 ... with the reason in the log" grep -q 'Invalid HERMES_PASEO_EXTRA_ORIGIN' <<<"$logs"
# shellcheck disable=SC2016 # $1 is the inner bash's argument
check "P6 ... and without the rejected value" bash -c '! grep -q p6-unique-marker <<<"$1"' _ "$logs"
podman rm -f -t 10 "$C" >/dev/null

printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0))
