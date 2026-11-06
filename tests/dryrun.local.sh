# shellcheck shell=bash
# tests/dryrun.local.sh: Hermes-specific assertions. Sourced at the end of tests/dryrun.sh (vendored),
# which provides run_variant, render_variant, $WORK, $REPO, $base, $failures.
# shellcheck disable=SC2154 # the variables above are defined by tests/dryrun.sh

check() { # check <description> <command...>
  if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
has_line() { grep -qxF -- "$3" "$WORK/$1/out/$2"; }

check "example publishes the gateway on 127.0.0.1" has_line example hermes-agent.container 'PublishPort=127.0.0.1:18642:8642'
check "example publishes the dashboard on 127.0.0.1" has_line example hermes-agent.container 'PublishPort=127.0.0.1:19119:9119'
check "example publishes the webhook receiver on 127.0.0.1" has_line example hermes-agent.container 'PublishPort=127.0.0.1:18644:8644'
check "example uses the default limits" has_line example hermes-agent.container 'PodmanArgs=--memory=6g --cpus=3'
check "BIND=all omits the host address" has_line fixture-lan hermes-agent.container 'PublishPort=28642:8642'
check "smaller per-host limits are rendered" has_line fixture-lan hermes-agent.container 'PodmanArgs=--memory=3g --cpus=2'
check "moved dashboard and webhook ports are rendered" bash -c \
  "grep -qx 'PublishPort=127.0.0.1:29119:9119' '$WORK/fixture-ports-moved/out/hermes-agent.container' && grep -qx 'PublishPort=127.0.0.1:28644:8644' '$WORK/fixture-ports-moved/out/hermes-agent.container'"
check "the database and the cache publish no port" bash -c \
  "! grep -q '^PublishPort=' '$WORK/example/out/hermes-postgres.container' '$WORK/example/out/hermes-redis.container'"
check "the agent image is local and never pulled" bash -c \
  "grep -qx 'Pull=never' '$WORK/example/out/hermes-agent.container' && grep -q '^Image=localhost/woow-hermes-agent:' '$WORK/example/out/hermes-agent.container'"
check "the image tag matches scripts/common.sh" bash -c \
  "grep -qx \"Image=localhost/woow-hermes-agent:\$(sed -n 's/^HERMES_IMAGE_TAG=//p' '$REPO/scripts/common.sh')\" '$REPO/quadlet/hermes-agent.container'"
check "the Containerfile base matches scripts/common.sh" bash -c \
  "grep -qF \"ARG HERMES_BASE=\$(sed -n 's/^HERMES_BASE=//p' '$REPO/scripts/common.sh')\" '$REPO/container/Containerfile'"
check "the database password never reaches the environment" bash -c \
  "grep -qx 'Environment=POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password' '$WORK/example/out/hermes-postgres.container' && ! grep -q '^Environment=POSTGRES_PASSWORD=' '$WORK/example/out/hermes-postgres.container'"
check "the provisioning unit is pulled in by the agent" bash -c \
  "grep -qx 'WantedBy=hermes-agent.service' '$WORK/example/out/hermes-provision.service'"

# The volume names are rendered, so an existing compose deployment can be adopted in place.
check "example renders the default data volume name" has_line example hermes-data.volume 'VolumeName=hermes-data'
check "example renders the default database volume name" has_line example hermes-postgres-data.volume 'VolumeName=hermes-postgres-data'
check "example renders the default cache volume name" has_line example hermes-redis-data.volume 'VolumeName=hermes-redis-data'
check "the legacy-adoption fixture renders the compose-era data volume" \
  has_line fixture-legacy-adopt hermes-data.volume 'VolumeName=podman_hermes-data'
check "the legacy-adoption fixture renders the compose-era database volume" \
  has_line fixture-legacy-adopt hermes-postgres-data.volume 'VolumeName=podman_postgres-data'
check "the legacy-adoption fixture renders the compose-era cache volume" \
  has_line fixture-legacy-adopt hermes-redis-data.volume 'VolumeName=podman_redis-data'
# The network is never the compose one: adopting podman_default would make uninstall --purge delete
# the legacy stack's network, and every "remove the stray podman_default" cleanup a rollback-killer.
check "the network keeps its own name, not the compose project's" has_line example hermes.network 'NetworkName=hermes'
check "no rendered unit adopts the compose network name" \
  bash -c "! grep -rqx 'NetworkName=podman_default' '$WORK'/*/out"

# Invalid knobs must stop the render before any file is written.
reject() { # reject <description> <KEY> <bad value>
  local env=$WORK/bad-$2.env
  sed "s|^$2=.*|$2=$3|" "$REPO/config/hermes.env.example" >"$env"
  mkdir -p "$WORK/bad-$2/src" "$WORK/bad-$2/out"
  cp -p -- "${base[@]}" "$WORK/bad-$2/src/"
  if (render_variant "$WORK/bad-$2/src" "$env" "$WORK/bad-$2/out") >/dev/null 2>&1; then
    echo "FAIL $1 was accepted"
    failures=$((failures + 1))
  else
    echo "ok   $1 is refused"
  fi
}
reject "a memory limit with shell metacharacters" WOOW_HERMES_MEMORY '6g --privileged'
reject "a port out of range" WOOW_HERMES_PORT_GATEWAY 70000
reject "a port used by two knobs" WOOW_HERMES_PORT_WEBHOOK 19119
reject "a volume name with shell metacharacters" WOOW_HERMES_DATA_VOLUME 'hermes-data;rm -rf /'
# The origins: a value the Paseo adapter can never accept stops the install (scripts/render-args.sh).
reject "an extra Paseo origin with a path" HERMES_PASEO_EXTRA_ORIGIN 'https://hermes.example.com/hermes'
reject "an extra Paseo origin with credentials" HERMES_PASEO_EXTRA_ORIGIN 'https://user:pw@hermes.example.com'
reject "an extra Paseo origin with a wildcard" HERMES_PASEO_EXTRA_ORIGIN 'https://*.example.com'
reject "an extra Paseo origin that is not http(s)" HERMES_PASEO_EXTRA_ORIGIN 'ftp://hermes.example.com'
reject "a public URL with credentials" HERMES_DASHBOARD_PUBLIC_URL 'https://user:pw@hermes.example.com'
reject "a public URL with a query" HERMES_DASHBOARD_PUBLIC_URL 'https://hermes.example.com/?a=b'
# origins: the example with these origin lines, through render_args as install.sh runs it
origins() { # origins <expect ok|fail> <description> <line...>
  local want=$1 what=$2 env=$WORK/origins-$RANDOM.env got=ok
  shift 2
  { grep -vE '^(HERMES_DASHBOARD_PUBLIC_URL|HERMES_BASE_URL|HERMES_PASEO_EXTRA_ORIGIN)=' "$REPO/config/hermes.env.example"
    printf '%s\n' "$@"; } >"$env"
  ( ql_env_load "$env" && render_args "$env" ) >/dev/null 2>&1 || got=fail
  if [[ $got == "$want" ]]; then echo "ok   $what"; else echo "FAIL $what (expected $want, got $got)"; failures=$((failures + 1)); fi
}
origins ok "an HTTPS tunnel origin with the loopback as the extra Paseo origin is accepted" \
  HERMES_DASHBOARD_PUBLIC_URL=https://hermes-openclaw.woowtech.io HERMES_BASE_URL=https://hermes-openclaw.woowtech.io \
  HERMES_PASEO_EXTRA_ORIGIN=http://127.0.0.1:19119
origins ok "a public URL behind a path prefix is accepted without an extra origin (OAuth only; Paseo warns)" \
  HERMES_DASHBOARD_PUBLIC_URL=https://proxy.example.com/hermes HERMES_BASE_URL=https://proxy.example.com/hermes \
  HERMES_PASEO_EXTRA_ORIGIN=
origins fail "an extra Paseo origin next to a public URL with a path is refused" \
  HERMES_DASHBOARD_PUBLIC_URL=https://proxy.example.com/hermes HERMES_BASE_URL=https://proxy.example.com/hermes \
  HERMES_PASEO_EXTRA_ORIGIN=http://127.0.0.1:19119
origins fail "HERMES_PASEO_INGRESS_ORIGIN in hermes.env is refused (the image sets it)" \
  HERMES_DASHBOARD_PUBLIC_URL=https://hermes.example.com HERMES_BASE_URL=https://hermes.example.com \
  HERMES_PASEO_EXTRA_ORIGIN= HERMES_PASEO_INGRESS_ORIGIN=https://hermes.example.com
