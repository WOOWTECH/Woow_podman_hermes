#!/usr/bin/env bash
# scripts/install.sh: install or update the Woow Hermes Agent stack (agent + PostgreSQL + Redis) as
# rootless Quadlet units (podman >= 4.9, systemd --user, linger). Idempotent: a re-run with nothing
# changed restarts nothing.
#
#   scripts/install.sh [options]
#
#   --set KEY=VALUE    store a per-host setting in ~/.config/hermes/hermes.env first (repeatable),
#                      e.g. --set WOOW_HERMES_PORT_DASHBOARD=29119. Only keys of the example file.
#   --no-llm           install without a provider key (platform checks only)
#   --no-build         do not build the image; fail when localhost/woow-hermes-agent:<tag> is missing
#   --rebuild          rebuild the image even when the tag exists (keeps the old one as <tag>-prev)
#   --rotate-secrets   generate new values for the three secrets the agent reads (API key, webhook
#                      secret, dashboard password) and restart it. The database password is left
#                      alone: PostgreSQL reads it only at initdb.
#   --accept-defaults  on the first run, continue with the example settings instead of stopping
#   --no-start         install the files and daemon-reload only
#   --no-smoke         skip tests/smoke.sh at the end
#   --dry-run          render and validate, report what would change, touch nothing
#
# Everything the old deploy/podman/deploy.sh did to the running container now happens in the image
# (container/Containerfile) or in the in-image provisioning scripts, so an upgrade or a restart can
# no longer silently lose it.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=hermes-helpers.sh
. "$REPO/scripts/hermes-helpers.sh"

sets=() no_llm=0 no_build=0 rebuild=0 rotate=0 accept=0 no_start=0 no_smoke=0
while (($#)); do
  case $1 in
    --set) (($# >= 2)) || ql_die "--set needs KEY=VALUE"; sets+=("$2"); shift ;;
    --set=*) sets+=("${1#--set=}") ;;
    --no-llm) no_llm=1 ;;
    --no-build) no_build=1 ;;
    --rebuild) rebuild=1 ;;
    --rotate-secrets) rotate=1 ;;
    --accept-defaults) accept=1 ;;
    --no-start) no_start=1 ;;
    --no-smoke) no_smoke=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry=${QL_DRY_RUN:-0}

# ---- 1. host preflight ------------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
app_lock

# ---- 2. per-host settings ---------------------------------------------------------------------
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
if [[ $QL_ENV_CREATED == 1 && $accept == 0 && ${#sets[@]} == 0 ]]; then
  ql_info "review $ENV_FILE (at least MINIMAX_API_KEY and the public URL), then run $0 again"
  exit 0
fi
((${#sets[@]} == 0)) || app_apply_sets "${sets[@]}"
app_env_load
app_env_overlay "${sets[@]}"
app_refuse_env_secrets
hermes_check_env "$no_llm"
hermes_check_memory "$(ql_env_get WOOW_HERMES_MEMORY)"

# ---- 3. legacy guards -------------------------------------------------------------------------
app_guard_containers

# ---- 4. stage, render, validate -----------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/out"
cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$WORK/src/"
cp -p "$REPO/systemd/hermes-provision.service" "$WORK/src/"
RENDER_ARGS=()
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"
render_args "$RENDER_ENV"
ql_render "$WORK/src" "$RENDER_ENV" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
ql_dryrun "$WORK/out" --verify --ref-dir "$HOME/.config/containers/systemd" \
  || ql_die "the rendered units failed the Quadlet dry-run; nothing was installed"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# ---- 5. the image, the registry images and the secrets ----------------------------------------
if ((no_build)); then
  podman image exists "$HERMES_IMAGE" || [[ $dry == 1 ]] || ql_die "--no-build, but $HERMES_IMAGE is missing"
elif [[ $dry == 1 ]]; then
  podman image exists "$HERMES_IMAGE" || ql_info "[dry-run] would build $HERMES_IMAGE"
elif ((rebuild)); then
  "$REPO/scripts/build-image.sh" --force
else
  "$REPO/scripts/build-image.sh"
fi
ql_pull_images "$WORK/out"
if ((rotate)); then
  # Rotating invalidates every API client, webhook sender and saved dashboard login.
  ql_secret_ensure hermes-api-server-key random:64 --replace
  ql_secret_ensure hermes-webhook-secret random:64 --replace
  ql_secret_ensure hermes-dashboard-password random:32 --replace
else
  ql_secret_ensure hermes-api-server-key random:64
  ql_secret_ensure hermes-webhook-secret random:64
  ql_secret_ensure hermes-dashboard-password random:32
fi
# Never --replace: PostgreSQL reads POSTGRES_PASSWORD_FILE only when it initialises the cluster, so a
# new value would lock the existing data out. Rotate it with ALTER ROLE if the parity DB is ever used.
ql_secret_ensure hermes-postgres-password random:44

# ---- 6. install changed files, then start / restart only what changed --------------------------
changed=$(ql_install_files "$WORK/out" "$APP" --prune)
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
restart_agent=0
app_env_changed && restart_agent=1
((rotate == 0)) || restart_agent=1
if [[ $dry == 1 ]]; then
  ((restart_agent)) && ql_info "[dry-run] would restart hermes-agent.service (the settings changed)"
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
((restart_agent == 0)) || ql_mark_changed "$APP" hermes-agent.service
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start hermes-agent.service"
  exit 0
fi
# The agent keeps its own state in SQLite; PostgreSQL and Redis are parity services, so they are
# started first but the agent is not blocked on them (Wants=, not Requires=).
ql_apply_units "$APP" hermes-postgres.service hermes-redis.service
app_wait_healthy hermes-postgresql 180 hermes-postgres.service
app_wait_healthy hermes-redis 120 hermes-redis.service
ql_apply_units "$APP" hermes-agent.service
app_wait_healthy hermes-agent 420 hermes-agent.service
ql_apply_units "$APP" hermes-provision.service
hermes_wait_provision 420 || ql_die "hermes-provision.service did not finish; see: journalctl --user -u hermes-provision.service -n 100"

# ---- 7. health and smoke ----------------------------------------------------------------------
host=$(app_local_host "$(ql_env_get WOOW_HERMES_BIND)")
gateway=$(ql_env_get WOOW_HERMES_PORT_GATEWAY)
dashboard=$(ql_env_get WOOW_HERMES_PORT_DASHBOARD)
ql_wait_http "http://$host:$gateway/health" '200' 120 || ql_die "the gateway does not answer on $host:$gateway"
app_env_record
if ((no_smoke == 0)); then
  "$REPO/tests/smoke.sh" || ql_die "tests/smoke.sh failed; see the FAIL lines above"
fi

cat >&2 <<EOF
$APP is installed and healthy ($HERMES_IMAGE_TAG).
  Dashboard  http://$host:$dashboard/   user admin
  Gateway    http://$host:$gateway/v1   (OpenAI-compatible; needs the API key below)
  Passwords  (private terminal) podman secret inspect --showsecret --format '{{.SecretData}}' hermes-dashboard-password
             (private terminal) podman secret inspect --showsecret --format '{{.SecretData}}' hermes-api-server-key
  Settings   $ENV_FILE (edit, then run scripts/install.sh again)
EOF
