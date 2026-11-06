# shellcheck shell=bash
# scripts/render-args.sh: values computed from ~/.config/hermes/hermes.env. Sourced by
# scripts/install.sh and tests/dryrun.sh, so CI renders exactly what a host gets.
#
# render_args <envfile>: QL_ENV is already loaded from <envfile>; sets RENDER_ARGS=(KEY=VALUE...) and
# validates the values that are rendered straight from the env file.
render_args() {
  local bind prefix name port vol
  local -A seen=()
  hermes_check_origins
  # Volume names reach the .volume units verbatim, so validate them the way podman would: a bad
  # value here is a stack pointed at a different (probably empty) volume, not a render error.
  for vol in DATA POSTGRES REDIS; do
    ql_assert_match "WOOW_HERMES_${vol}_VOLUME" "$(ql_env_get "WOOW_HERMES_${vol}_VOLUME")" '[a-zA-Z0-9][a-zA-Z0-9_.-]*'
  done
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

# hermes_origin <value>: print <value> as the exact browser origin the Paseo host adapter compares
# against (one trailing slash dropped), or return 1. The same grammar as
# container/rootfs/opt/woow/paseo_origin.py and the adapter's own origin(): http(s)://host[:port],
# host a DNS name or a bracketed IPv6 literal, no credentials, path, query, fragment or wildcard.
# tests/test-paseo-origin.py runs both against the same cases.
hermes_origin() {
  local v=$1 label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?' port
  local re="^https?://(($label)(\\.($label))*\\.?|\\[[0-9A-Fa-f:.]+\\])(:([0-9]+))?/?$"
  ((${#v} > 0 && ${#v} <= 2048)) || return 1
  [[ ! $v =~ [[:space:][:cntrl:]*\\?#] ]] || return 1
  [[ $v =~ $re ]] || return 1
  port=${BASH_REMATCH[8]}
  if [[ -n $port ]]; then
    ((${#port} <= 5 && 10#$port >= 1 && 10#$port <= 65535)) || return 1
  fi
  printf '%s' "${v%/}"
}

# hermes_check_origins: the dashboard public URL and the optional extra Paseo origin. Refuses what
# can never work and never prints a rejected value (a URL can carry credentials).
hermes_check_origins() {
  local pub extra pub_origin='' extra_origin host
  pub=$(ql_env_get HERMES_DASHBOARD_PUBLIC_URL '')
  extra=$(ql_env_get HERMES_PASEO_EXTRA_ORIGIN '')
  [[ -z ${QL_ENV[HERMES_PASEO_INGRESS_ORIGIN]+x} ]] \
    || ql_die "HERMES_PASEO_INGRESS_ORIGIN is set by the image from HERMES_PASEO_EXTRA_ORIGIN; remove that line and set HERMES_PASEO_EXTRA_ORIGIN instead"
  if [[ -n $pub ]]; then
    # upstream accepts any scheme://netloc[/path]; these can only be typos or leaked credentials
    [[ ! $pub =~ [[:space:]?#] && ! $pub =~ ^[a-z]+://[^/]*@ ]] \
      || ql_die "HERMES_DASHBOARD_PUBLIC_URL must not contain credentials, a query, a fragment or blanks (value not shown)"
    pub_origin=$(hermes_origin "$pub") || pub_origin=''
    if [[ -z $pub_origin ]]; then
      ql_warn "HERMES_DASHBOARD_PUBLIC_URL is not an exact origin (it has a path, or an unusual host): MCP OAuth works, but the Paseo plugin will answer 503 INVALID_DASHBOARD_ORIGIN"
    else
      host=${pub_origin#*://}
      host=${host%:*}
      if [[ $pub_origin == http://* && ! $host =~ ^(localhost|127\.[0-9.]+|\[::1\])$ ]]; then
        ql_warn "HERMES_DASHBOARD_PUBLIC_URL is plain http on a non-loopback host: put the dashboard behind HTTPS (a reverse proxy or tunnel) before using MCP OAuth or Paseo from other machines"
      fi
    fi
  fi
  [[ -n $extra ]] || return 0
  extra_origin=$(hermes_origin "$extra") \
    || ql_die "HERMES_PASEO_EXTRA_ORIGIN must be an exact origin, scheme://host[:port] with no path, credentials, query or wildcard (value not shown)"
  [[ -n $pub_origin ]] \
    || ql_die "HERMES_PASEO_EXTRA_ORIGIN is set, but HERMES_DASHBOARD_PUBLIC_URL is not an exact origin: the Paseo adapter needs the public URL as its primary origin and would refuse every request (503 INVALID_DASHBOARD_ORIGIN)"
  if [[ ${extra_origin,,} == "${pub_origin,,}" ]]; then
    ql_warn "HERMES_PASEO_EXTRA_ORIGIN is the same origin as HERMES_DASHBOARD_PUBLIC_URL; leave it empty"
  fi
  return 0
}
