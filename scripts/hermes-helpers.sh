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

# hermes_check_env: the settings the agent cannot start usefully without
hermes_check_env() {
  local no_llm=$1 pub base
  pub=$(ql_env_get HERMES_DASHBOARD_PUBLIC_URL '')
  base=$(ql_env_get HERMES_BASE_URL '')
  [[ -n $pub ]] || ql_die "HERMES_DASHBOARD_PUBLIC_URL is empty; MCP OAuth callbacks need the URL the dashboard is opened from"
  ql_assert_match HERMES_DASHBOARD_PUBLIC_URL "$pub" 'https?://[^[:space:]/]+(/.*)?'
  [[ $pub == "$base" ]] || ql_die "HERMES_DASHBOARD_PUBLIC_URL and HERMES_BASE_URL must be the same value"
  if ((no_llm == 0)) && [[ -z $(ql_env_get MINIMAX_API_KEY '') ]]; then
    ql_die "MINIMAX_API_KEY is empty in $ENV_FILE. Set it, or run with --no-llm for a platform-only install"
  fi
}

# hermes_wait_provision <timeout>: the oneshot provisioning unit must finish (it applies the config
# policy once and fixes the model routes after the gateway is up)
_hermes_provision_done() {
  [[ $(systemctl --user show -p ActiveState --value hermes-provision.service 2>/dev/null) == active ]]
}
hermes_wait_provision() {
  ql_wait_until "$1" "hermes-provision.service to finish" _hermes_provision_done
}
