# shellcheck shell=bash
# scripts/render-args.sh: values computed from ~/.config/hermes/hermes.env. Sourced by
# scripts/install.sh and tests/dryrun.sh, so CI renders exactly what a host gets.
#
# render_args <envfile>: QL_ENV is already loaded from <envfile>; sets RENDER_ARGS=(KEY=VALUE...) and
# validates the values that are rendered straight from the env file.
render_args() {
  local bind prefix name port
  local -A seen=()
  bind=$(ql_env_get WOOW_HERMES_BIND)
  ql_assert_match WOOW_HERMES_BIND "$bind" 'all|[0-9]{1,3}(\.[0-9]{1,3}){3}'
  ql_assert_match WOOW_HERMES_MEMORY "$(ql_env_get WOOW_HERMES_MEMORY)" '[0-9]+[bkmgBKMG]?'
  ql_assert_match WOOW_HERMES_CPUS "$(ql_env_get WOOW_HERMES_CPUS)" '[0-9]+(\.[0-9]+)?'
  # "all" publishes on every address family (IPv4 and IPv6): omit the host IP.
  if [[ $bind == all ]]; then prefix=''; else prefix="$bind:"; fi
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller
  RENDER_ARGS=()
  for name in GATEWAY DASHBOARD WEBHOOK; do
    port=$(ql_env_get "WOOW_HERMES_PORT_$name")
    ql_assert_match "WOOW_HERMES_PORT_$name" "$port" '[1-9][0-9]{0,4}'
    ((port <= 65535)) || ql_die "WOOW_HERMES_PORT_$name: $port is not a TCP port"
    [[ -z ${seen[$port]+x} ]] || ql_die "WOOW_HERMES_PORT_$name: port $port is already used by WOOW_HERMES_PORT_${seen[$port]}"
    seen[$port]=$name
    RENDER_ARGS+=("HERMES_PUBLISH_$name=$prefix$port")
  done
}
