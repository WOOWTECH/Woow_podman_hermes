# shellcheck shell=bash
# scripts/hermes-helpers.sh: Hermes-specific helpers, sourced after scripts/common.sh.

# hermes_bytes <value>: 6g / 512m / 1024k / plain bytes -> bytes (for the MemAvailable check)
hermes_bytes() {
  local v=${1,,} n=${1//[!0-9]/}
  case $v in
    *g) printf '%s' $((n * 1024 * 1024 * 1024)) ;;
    *m) printf '%s' $((n * 1024 * 1024)) ;;
    *k) printf '%s' $((n * 1024)) ;;
    *) printf '%s' "$n" ;;
  esac
}

# hermes_check_memory <limit>: warn when the host cannot back the container's memory limit
hermes_check_memory() {
  local want avail
  want=$(hermes_bytes "$1")
  avail=$(awk '/^MemAvailable:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null || echo 0)
  if ((avail > 0 && avail < want)); then
    ql_warn "MemAvailable is $((avail / 1024 / 1024)) MB but WOOW_HERMES_MEMORY is $1; lower the limit or free memory"
  fi
}

# hermes_check_env <no_llm>: the settings the agent cannot start usefully without. A provider key
# is wanted unless --no-llm: any of the three provider keys hermes.env carries will do.
hermes_check_env() {
  local no_llm=$1 pub base
  pub=$(ql_env_get HERMES_DASHBOARD_PUBLIC_URL '')
  base=$(ql_env_get HERMES_BASE_URL '')
  [[ -n $pub ]] || ql_die "HERMES_DASHBOARD_PUBLIC_URL is empty; MCP OAuth callbacks need the URL the dashboard is opened from"
  ql_assert_match HERMES_DASHBOARD_PUBLIC_URL "$pub" 'https?://[^[:space:]/]+(/.*)?'
  [[ $pub == "$base" ]] || ql_die "HERMES_DASHBOARD_PUBLIC_URL and HERMES_BASE_URL must be the same value"
  ((no_llm == 0)) || return 0
  local k
  for k in MINIMAX_API_KEY OPENROUTER_API_KEY LITELLM_API_KEY; do
    [[ -z $(ql_env_get "$k" '') ]] || return 0
  done
  ql_die "no LLM provider key in $ENV_FILE (MINIMAX_API_KEY, OPENROUTER_API_KEY or LITELLM_API_KEY). Set one, or run with --no-llm (scripts/upgrade.sh passes it on) when the provider is configured in the dashboard or in config.yaml instead"
}

# hermes_wait_provision <timeout>: the oneshot provisioning unit must finish (it enables the tools
# and plugins once, fixes the model routes and writes the defaults after the gateway is up)
_hermes_provision_done() {
  [[ $(systemctl --user show -p ActiveState --value hermes-provision.service 2>/dev/null) == active ]]
}
hermes_wait_provision() {
  ql_wait_until "$1" "hermes-provision.service to finish" _hermes_provision_done
}

# hermes_ensure_resources <rendered-dir>: a network or volume oneshot unit that is still "active
# (exited)" although its podman object is gone is restarted, together with the three containers.
# Quadlet's -network/-volume services are RemainAfterExit oneshots: when the objects are removed
# behind systemd's back (`podman system reset`, `podman network rm`, a storage wipe) the unit stays
# active, ql_apply_units only restarts units whose files changed, and the containers then fail with
# "unable to find network with name or ID hermes". A unit that is not active needs nothing: starting
# a container pulls it in and it creates the object.
hermes_ensure_resources() {
  local out=$1 f kind name unit missing=()
  for f in "$out"/*.network "$out"/*.volume; do
    [[ -f $f ]] || continue
    case $f in
      *.network) kind=network name=$(sed -n 's/^NetworkName=//p' "$f") ;;
      *) kind=volume name=$(sed -n 's/^VolumeName=//p' "$f") ;;
    esac
    [[ -n $name ]] || continue
    unit=$(ql_unit_for "$f")
    [[ $(systemctl --user is-active "$unit" 2>/dev/null || true) == active ]] || continue
    podman "$kind" exists "$name" && continue
    if [[ $kind == volume ]]; then
      ql_warn "podman volume $name is gone although $unit is active; it is recreated EMPTY. If it held data, stop now and use scripts/restore.sh"
    else
      ql_warn "podman network $name is gone although $unit is active; recreating it"
    fi
    missing+=("$unit")
  done
  ((${#missing[@]})) || return 0
  if [[ ${QL_DRY_RUN:-0} == 1 ]]; then
    ql_info "[dry-run] would restart ${missing[*]} and the hermes containers"
    return 0
  fi
  ql_mark_changed "$APP" "${missing[@]}" hermes-postgres.service hermes-redis.service hermes-agent.service
}
