#!/usr/bin/env bash
# scripts/migrate-legacy.sh: move the compose-era Hermes deployment (podman-compose project
# `podman` - the project name comes from the directory deploy/podman/, not from the app: containers
# hermes-agent, hermes-postgresql and hermes-redis, volumes podman_hermes-data, podman_postgres-data
# and podman_redis-data, network podman_default) to the Quadlet units of this repo.
#
# The three volumes are adopted exactly where they are - the 1.3 GB of agent state is never copied -
# and the adoption is proved after the install by comparing each volume's mountpoint, inode and
# CreatedAt with the values read before the cutover. install.sh renders VolumeName= from
# WOOW_HERMES_*_VOLUME, which this script sets to the compose-era names.
#
#   scripts/migrate-legacy.sh [--legacy-dir DIR] [--suffix YYYYMMDD] [--rotate-secrets]
#                             [--align-db-password] [--prepare-only | --dry-run]
#                             [--no-auto-rollback] [--yes]
#   scripts/migrate-legacy.sh --rollback [--yes]
#   scripts/migrate-legacy.sh --status
#
#   --legacy-dir DIR   the compose checkout (default: ~/Woow_podman_hermes). Only read; its
#                      deploy/podman/.env and podman-compose.yml are copied into the backup.
#   --suffix S         the legacy containers become <name>-legacy-S (default: today). Rename path
#                      only; see "Rollback shape" below.
#   --rotate-secrets   generate new values for the API key, the webhook secret and the dashboard
#                      password instead of carrying the legacy ones over. Every API client, webhook
#                      sender and saved dashboard login stops working until it is updated.
#   --reapply-config-policy
#                      let hermes-provision.service apply the WOOWTECH config policy to the adopted
#                      /opt/data again. By default the migration stamps .woow-policy-v1 instead: the
#                      compose-era deploy.sh already applied that policy to this very volume, and
#                      re-running its sed would revert anything changed in the dashboard since.
#   --align-db-password
#                      also ALTER ROLE the adopted PostgreSQL role to the recorded secret. Off by
#                      default: the secret is seeded FROM the legacy password, so they already
#                      agree, and PostgreSQL reads POSTGRES_PASSWORD_FILE only at initdb.
#   --prepare-only     steps 1-3 only, no downtime: checks, env file, secrets, the image build,
#                      the hot backup (pg_dump included) and the rollback copy
#   --dry-run          step 1 plus a render of the units; changes nothing
#   --no-auto-rollback leave a failed cutover in place for inspection
#   --rollback         undo the cutover: remove the Quadlet units (the three volumes, the legacy
#                      network and the secrets are kept), bring the legacy containers back, start
#                      them and wait for the gateway
#
# THE IMAGE CHANGES, on purpose. The compose stack ran docker.io/nousresearch/hermes-agent:latest
# and then mutated the running container with `podman exec` (deploy/podman/deploy.sh: apt-get tmux,
# uv pip install ddgs into the agent venv, an OfficeCLI download, symlinks into /usr/local/bin,
# rm -rf of skill packs under /opt/hermes, and two Python patches). The Quadlet stack runs
# localhost/woow-hermes-agent:<tag>, built from a digest-pinned base with all of that baked in. The
# script reports both images and their versions and names the change in the confirmation prompt; it
# is not a difference it can resolve for you.
#
# Rollback shape (STANDARD 7a): the legacy containers are kept for --rollback either by renaming
# them and leaving them stopped, or - where the user unit podman-restart.service is enabled AND a
# legacy container's restart policy is exactly `always`, because a renamed copy would revive at the
# next boot and fight the new Quadlet container - by capturing them into the backup directory and
# removing them. ql_rollback_strategy decides from this host's real state, never from its name, and
# --dry-run reports which path a cutover would take. On woowtechopenclaw all three hermes containers
# are `unless-stopped`, so that host takes the rename path today; the capture path is exercised by
# tests/rollback-model.sh and is the one that needs --commit, because hermes-agent's writable layer
# is 42 672 686 bytes / 844 files of exactly the changes deploy.sh made (measured live; note that
# `podman diff` prints an empty object for that container and is not a substitute for SizeRw).
#
# THE NETWORK IS NOT ADOPTED. podman-compose called it podman_default, which reads like podman's own
# default network and belongs to no app. A network holds no data, so a fresh `hermes` network is
# created and podman_default is left untouched for the rollback. Anyone cleaning up "stray" networks
# on woowtechopenclaw must know that podman_default IS the hermes stack's network.
#
# Steps:  1 pre-flight checks (read-only)
#         2 env file, secrets carried over from the legacy containers, and the image build
#         3 hot backup: pg_dump, volume exports, inspect, compose files, and the rollback copy
#         4 stop the legacy stack, cold exports, retire the containers (rename or capture+remove)
#         5 scripts/install.sh adopts the three volumes; prove it; tests/smoke.sh; compare
#         6 --rollback when needed
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=hermes-helpers.sh
. "$REPO/scripts/hermes-helpers.sh"
# shellcheck source=legacy-common.sh
. "$REPO/scripts/legacy-common.sh"

APP_STATE_DIR=$(app_state_dir)
STATE=$APP_STATE_DIR/migration.state
AGENT=hermes-agent DB=hermes-postgresql CACHE=hermes-redis
LEGACY_CONTAINERS=("$AGENT" "$DB" "$CACHE")
# The compose-era names this migration adopts. Each one is <volume>:<destination in the container>.
LEGACY_VOLUMES=(
  "podman_hermes-data:/opt/data:$AGENT:WOOW_HERMES_DATA_VOLUME"
  "podman_postgres-data:/var/lib/postgresql/data:$DB:WOOW_HERMES_POSTGRES_VOLUME"
  "podman_redis-data:/data:$CACHE:WOOW_HERMES_REDIS_VOLUME"
)
# The compose network. Never created, never removed, never adopted by this repo's units.
LEGACY_NETWORK=podman_default
DATA_VOLUME=podman_hermes-data
# The podman-compose project label the legacy containers must carry. It really is 'podman': the
# compose file lives in deploy/podman/, and podman-compose names the project after that directory.
# A same-named container from any other project is refused, not retired.
LEGACY_PROJECT=podman
MAIN_UNIT=hermes-agent.service

mode=migrate legacy_dir=$HOME/Woow_podman_hermes suffix=$(date +%Y%m%d)
rotate=0 align_db=0 reapply_policy=0 auto_rollback=1 yes=0
while (($#)); do
  case $1 in
    --legacy-dir) legacy_dir=${2:?--legacy-dir needs a directory}; shift ;;
    --suffix) suffix=${2:?--suffix needs a value}; shift ;;
    --rotate-secrets) rotate=1 ;;
    --align-db-password) align_db=1 ;;
    --reapply-config-policy) reapply_policy=1 ;;
    --prepare-only) mode=prepare ;;
    --dry-run) mode=dry-run ;;
    --no-auto-rollback) auto_rollback=0 ;;
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --yes) yes=1 ;;
    -h | --help) sed -n '2,78p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_assert_match --suffix "$suffix" '[A-Za-z0-9._-]+'

# ---- a small state file: what the cutover did, so --rollback needs no arguments ---------------
state_get() { if [[ -f $STATE ]]; then sed -n "s/^$1=//p" "$STATE" | tail -n1; fi; }
state_set() {
  local tmp
  (umask 077 && mkdir -p "$APP_STATE_DIR")
  tmp=$(mktemp "$APP_STATE_DIR/.migration.XXXXXX")
  { if [[ -f $STATE ]]; then grep -v "^$1=" "$STATE" || true; fi; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv -f "$tmp" "$STATE"
}

if [[ $mode == status ]]; then
  if [[ -f $STATE ]]; then cat "$STATE"; else echo "no migration recorded in $STATE"; fi
  exit 0
fi

ql_preflight "$PODMAN_MIN"
app_lock

unit_exists() { [[ -n $(systemctl --user show -p FragmentPath --value "$1" 2>/dev/null) ]]; }
quadlet_installed() { [[ -s $APP_STATE_DIR/manifest ]] && unit_exists "$MAIN_UNIT"; }
running() { [[ $(podman inspect --format '{{.State.Status}}' "$1" 2>/dev/null) == running ]]; }
now_s() { date +%s; }
# env_of <container> <KEY>: one environment value, read from the container object
env_of() {
  podman inspect --format \
    "{{range .Config.Env}}{{if eq (index (split . \"=\") 0) \"$2\"}}{{index (split . \"=\") 1}}{{end}}{{end}}" "$1" 2>/dev/null
}
mounts_of() { podman inspect --format '{{range .Mounts}}{{.Name}}|{{.Destination}}{{println}}{{end}}' "$1"; }

# stamp_config_policy: mark the adopted /opt/data as already carrying the WOOWTECH config policy.
# container/rootfs/usr/local/bin/woow-provision applies that policy (the old deploy.sh step 8: a sed
# over config.yaml plus tool and plugin enables) unless $DATA/.woow-policy-v1 exists. On an adopted
# volume deploy.sh already ran it, and the dashboard may have changed settings since, so re-applying
# would silently revert them. The stamp belongs to the container's hermes user (uid 1000 inside the
# container, a subuid on the host), hence podman unshare.
stamp_config_policy() {
  local mp
  mp=$(podman volume inspect --format '{{.Mountpoint}}' "$DATA_VOLUME" 2>/dev/null) || return 1
  [[ -n $mp ]] || return 1
  if ! podman unshare test -f "$mp/config.yaml"; then
    ql_info "no config.yaml in $DATA_VOLUME yet; the new agent creates one and the policy is applied as on a fresh install"
    return 0
  fi
  if podman unshare test -f "$mp/.woow-policy-v1"; then
    ql_info "$DATA_VOLUME is already stamped .woow-policy-v1"
    return 0
  fi
  podman unshare touch "$mp/.woow-policy-v1" || return 1
  podman unshare chown 1000:1000 "$mp/.woow-policy-v1" || return 1
  ql_info "stamped .woow-policy-v1 on $DATA_VOLUME: the compose deploy.sh already applied that config policy, so hermes-provision.service will not re-apply it over anything changed since. Delete the stamp to re-apply deliberately"
}

# derive_env <file>: fill the user-supplied keys in from the legacy agent container. The provider
# keys and the GitHub token are the values the compose stack ran with; scripts/common.sh lists them
# in ENV_CREDENTIAL_ALLOW, so install.sh accepts them in the env file.
derive_env() {
  local f=$1 k v
  ql_env_set "$f" HERMES_DASHBOARD_PUBLIC_URL "$pub"
  ql_env_set "$f" HERMES_BASE_URL "$pub"
  for k in MINIMAX_API_KEY OPENROUTER_API_KEY GITHUB_TOKEN; do
    v=$(env_of "$AGENT" "$k")
    [[ -z $v ]] || ql_env_set "$f" "$k" "$v"
  done
}

# =============================================================================================
# 6. rollback
# =============================================================================================
rollback() {
  local status sfx bk c port
  status=$(state_get STATUS) sfx=$(state_get SUFFIX) bk=$(state_get BACKUP)
  [[ $status == cutover || $status == "done" ]] || ql_die "nothing to roll back (migration status: ${status:-none})"
  app_confirm ROLLBACK "$yes" "--rollback removes the Hermes Quadlet units and brings the legacy containers back"
  ql_info "stopping and removing the Quadlet units (the three volumes, $LEGACY_NETWORK and the secrets are kept)"
  ql_uninstall_units "$APP"
  rm -f -- "$APP_STATE_DIR/applied-env.sha256"
  for c in "${LEGACY_CONTAINERS[@]}"; do
    if podman container exists "$c"; then
      case $(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c") in
        hermes-agent.service | hermes-postgres.service | hermes-redis.service) podman rm -f "$c" >/dev/null ;;
        *) ql_die "container $c exists and is not a Quadlet leftover; resolve it by hand" ;;
      esac
    fi
  done
  # renamed back, or recreated from the capture the cutover took - whichever the host needed
  app_legacy_restore "$sfx" "$bk" "${LEGACY_CONTAINERS[@]}"
  # The database and the cache first: the agent is the one with the published ports.
  podman start "$DB" "$CACHE" >/dev/null || ql_die "could not start the legacy database and cache"
  podman start "$AGENT" >/dev/null || ql_die "could not start the legacy agent"
  port=$(state_get LEGACY_PORT_GATEWAY)
  ql_wait_http "http://127.0.0.1:${port:-18642}/health" '200' 300 \
    || ql_die "the legacy gateway did not answer on 127.0.0.1:${port:-18642}/health after the rollback"
  state_set STATUS rolled-back
  ql_info "rolled back: the legacy Hermes stack runs again. Backup of the attempt: $bk"
  ql_info "the volumes were adopted in place and never rewritten, so no data restore is needed; the"
  ql_info "pg_dump and the cold exports in $bk are only for a damaged database (README, 'Rollback')"
  ql_warn "the legacy stack has NO systemd unit and its policy is unless-stopped, which podman-restart.service does not match: it will not come back by itself after a reboot. That was true before this migration too"
}

if [[ $mode == rollback ]]; then
  rollback
  exit 0
fi

# =============================================================================================
# 1. pre-flight checks (read-only) - every one of these refuses rather than guesses
# =============================================================================================
ql_info "step 1/5: pre-flight checks"
if [[ $(state_get STATUS) == "done" ]]; then
  if quadlet_installed && running "$AGENT"; then
    ql_info "already migrated on $(state_get DONE_AT): the Quadlet units are installed and $AGENT is running. Nothing to do"
    ql_info "  scripts/migrate-legacy.sh --status    what the cutover recorded"
    ql_info "  scripts/migrate-legacy.sh --rollback  undo it"
    exit 0
  fi
  ql_die "a completed migration is recorded in $STATE but the units are not installed or $AGENT is not running; inspect before doing anything else"
fi
[[ $(state_get STATUS) != cutover ]] || ql_die "a cutover is in progress in $STATE (use --status, or --rollback)"

for c in "${LEGACY_CONTAINERS[@]}"; do
  podman container exists "$c" || ql_die "legacy container $c not found; nothing to migrate"
  label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c")
  case $label in
    hermes-agent.service | hermes-postgres.service | hermes-redis.service)
      ql_die "$c is already managed by Quadlet ($label); this host needs no migration" ;;
  esac
  app_check_not_foreign "$c" "$LEGACY_PROJECT"
  running "$c" || ql_die "legacy container $c is not running; start the legacy stack first (the pg_dump, the volume exports and the snapshot are all taken hot)"
done
if quadlet_installed; then
  ql_die "the Hermes Quadlet units are already installed ($MAIN_UNIT); this host needs no migration"
fi
for f in "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$REPO"/systemd/*.service; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# -- the network name collision, handled deliberately (see the header) --------------------------
quadlet_net=$(sed -n 's/^NetworkName=//p' "$REPO/quadlet/hermes.network")
[[ $quadlet_net != "$LEGACY_NETWORK" ]] \
  || ql_die "quadlet/hermes.network is named $LEGACY_NETWORK, the compose network. This repo must not adopt that name: it is the legacy stack's network, the rollback needs it, and scripts/uninstall.sh --purge would then delete it"
podman network exists "$LEGACY_NETWORK" \
  || ql_warn "network $LEGACY_NETWORK does not exist; a rollback will recreate the containers but their network attachment may differ"
ql_info "the compose network $LEGACY_NETWORK belongs to this stack and is left untouched; the Quadlet units create '$quadlet_net' instead"

# -- the data really is where this repo expects it, and nothing else writes to it ---------------
declare -A VOL_ID_BEFORE=()
sets=()
for spec in "${LEGACY_VOLUMES[@]}"; do
  IFS=: read -r vol dest ctr key <<<"$spec"
  grep -qx "$vol|$dest" < <(mounts_of "$ctr") \
    || ql_die "$ctr does not mount the volume $vol at $dest; this migration only adopts that name (see the compose file in the archive branch)"
  podman volume exists "$vol" || ql_die "volume $vol does not exist"
  other=$(podman ps --format '{{.Names}}' --filter "volume=$vol" | grep -vxF -e "$AGENT" -e "$DB" -e "$CACHE" || true)
  [[ -z $other ]] || ql_die "another running container also uses $vol: $other. Two writers on the same data; resolve that first"
  VOL_ID_BEFORE[$vol]=$(app_volume_identity "$vol") || ql_die "cannot inspect volume $vol"
  sets+=("$key=$vol")
done

# -- the published ports, read from the agent (never guessed) -----------------------------------
# .HostIP is the Go field name; the JSON tag is HostIp and that spelling makes the whole template
# fail with exit 125 and no output (STANDARD section 8).
declare -A LEGACY_PORT=() LEGACY_BIND=()
while IFS='|' read -r cport hip hport; do
  [[ -n $cport ]] || continue
  LEGACY_PORT[${cport%%/*}]=$hport
  LEGACY_BIND[${cport%%/*}]=$hip
done < <(podman inspect --format '{{range $p, $bs := .NetworkSettings.Ports}}{{range $bs}}{{$p}}|{{.HostIP}}|{{.HostPort}}{{println}}{{end}}{{end}}' "$AGENT")
declare -A KNOB=([8642]=GATEWAY [9119]=DASHBOARD [8644]=WEBHOOK)
binds=''
for cport in 8642 9119 8644; do
  hport=${LEGACY_PORT[$cport]:-}
  [[ -n $hport ]] || ql_die "$AGENT does not publish container port $cport; this repo's unit publishes all three"
  sets+=("WOOW_HERMES_PORT_${KNOB[$cport]}=$hport")
  binds+="${LEGACY_BIND[$cport]:-0.0.0.0} "
done
bind=$(tr ' ' '\n' <<<"$binds" | grep -v '^$' | sort -u)
[[ $bind != *$'\n'* ]] \
  || ql_die "$AGENT publishes its ports on more than one address ($(tr '\n' ' ' <<<"$bind")); WOOW_HERMES_BIND takes a single value. Set the ports by hand with scripts/install.sh --set"
if [[ $bind == 0.0.0.0 || -z $bind ]]; then bind=all; fi
sets+=("WOOW_HERMES_BIND=$bind")
GW_PORT=${LEGACY_PORT[8642]} DASH_PORT=${LEGACY_PORT[9119]} WH_PORT=${LEGACY_PORT[8644]}
ql_info "legacy publish: bind $bind, gateway $GW_PORT, dashboard $DASH_PORT, webhook $WH_PORT"
[[ $bind != all ]] || ql_warn "the compose stack published all three ports on 0.0.0.0. The migration keeps that; WOOW_HERMES_BIND=127.0.0.1 in $ENV_FILE plus a re-run of scripts/install.sh closes them off afterwards"

for cport in 8642 9119 8644; do
  hport=${LEGACY_PORT[$cport]}
  used=0
  for c2 in 8642 9119 8644; do [[ ${LEGACY_PORT[$c2]:-} == "$hport" ]] && used=1; done
  ((used)) && continue
  ! ss -ltnH "sport = :$hport" 2>/dev/null | grep -q . || ql_die "port $hport is in use by something that is not the legacy Hermes stack"
done

# -- the resource limits the compose stack actually ran with ------------------------------------
mem=$(podman inspect --format '{{.HostConfig.Memory}}' "$AGENT")
cpus=$(podman inspect --format '{{.HostConfig.NanoCpus}}' "$AGENT")
if [[ ${mem:-0} =~ ^[0-9]+$ ]] && ((mem > 0)); then sets+=("WOOW_HERMES_MEMORY=$((mem / 1024 / 1024))m"); fi
if [[ ${cpus:-0} =~ ^[0-9]+$ ]] && ((cpus > 0)); then sets+=("WOOW_HERMES_CPUS=$((cpus / 1000000000))"); fi

# -- the settings the agent cannot start usefully without ---------------------------------------
pub=$(env_of "$AGENT" HERMES_DASHBOARD_PUBLIC_URL)
base=$(env_of "$AGENT" HERMES_BASE_URL)
[[ -n $pub ]] || ql_die "the legacy $AGENT has no HERMES_DASHBOARD_PUBLIC_URL; MCP OAuth callbacks need the URL the dashboard is opened from. Set it on the legacy container first, or pass it in $ENV_FILE after the cutover"
[[ $pub == "$base" || -z $base ]] || ql_die "the legacy HERMES_DASHBOARD_PUBLIC_URL ($pub) and HERMES_BASE_URL ($base) differ; the units require one value"
LEGACY_MINIMAX=$(env_of "$AGENT" MINIMAX_API_KEY)
no_llm=()
if [[ -z $LEGACY_MINIMAX ]]; then
  no_llm=(--no-llm)
  ql_warn "the legacy $AGENT runs with an empty MINIMAX_API_KEY; the install runs with --no-llm. Put a key into $ENV_FILE and re-run scripts/install.sh to enable the provider"
fi

# -- the database is reachable and holds what we are about to dump ------------------------------
psql_l() { podman exec "$DB" psql -U hermes -d hermes -tAc "$1" 2>/dev/null; }
podman exec "$DB" pg_isready -U hermes -d hermes >/dev/null 2>&1 \
  || ql_die "$DB does not answer pg_isready -U hermes -d hermes; fix the legacy database before migrating"
pg_major=$(podman exec "$DB" sh -c 'echo "$PG_MAJOR"' 2>/dev/null || true)
pg_pin=$(sed -n 's/^Image=docker.io\/library\/postgres:\([0-9]*\).*/\1/p' "$REPO/quadlet/hermes-postgres.container")
[[ -z $pg_major || -z $pg_pin || $pg_major == "$pg_pin" ]] \
  || ql_die "the legacy PostgreSQL major is $pg_major but quadlet/hermes-postgres.container pins $pg_pin; an adopted cluster cannot change major version in place"

# -- the image change, reported rather than guessed ---------------------------------------------
legacy_image=$(podman inspect --format '{{.ImageName}}' "$AGENT")
legacy_image_id=$(podman inspect --format '{{.Image}}' "$AGENT")
legacy_version=$(curl -fsS -m 5 "http://127.0.0.1:$GW_PORT/health" 2>/dev/null | tr -d '\n' | head -c 200 || true)
ql_info "agent image now: $legacy_image (${legacy_image_id:0:12})"
ql_info "agent image after: $HERMES_IMAGE, built from $HERMES_BASE"
rw=$(app_legacy_rw_bytes "$AGENT")
ql_info "the legacy $AGENT carries ${rw:-?} bytes in its writable layer - the changes deploy/podman/deploy.sh made with podman exec. They are baked into the new image instead; nothing reads them back out of the old container"

# -- how the legacy containers are kept for --rollback (asked of the host, never of its name) ---
STRATEGY=$(ql_rollback_strategy "${LEGACY_CONTAINERS[@]}")
if [[ $STRATEGY == rename ]]; then
  for c in "${LEGACY_CONTAINERS[@]}"; do
    ! podman container exists "$c-legacy-$suffix" || ql_die "$c-legacy-$suffix already exists; pick another --suffix"
  done
fi
hermes_check_memory "$(sed -n "s/^WOOW_HERMES_MEMORY=//p" <<<"$(printf '%s\n' "${sets[@]}")" | tail -n1 || echo 6g)"

# -- a functional snapshot to compare against afterwards ----------------------------------------
snapshot() {
  printf 'gateway_health=%s\n' "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://127.0.0.1:$GW_PORT/health" || echo 000)"
  printf 'dashboard=%s\n' "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://127.0.0.1:$DASH_PORT/" || echo 000)"
  printf 'db_tables=%s\n' "$(psql_l "select count(*) from pg_tables where schemaname='public'" || echo '?')"
  printf 'db_databases=%s\n' "$(psql_l "select count(*) from pg_database where datistemplate=false" || echo '?')"
  printf 'redis_keys=%s\n' "$(podman exec "$CACHE" redis-cli dbsize 2>/dev/null | tr -d '\r' || echo '?')"
  printf 'data_files=%s\n' "$(podman exec "$AGENT" sh -c 'find /opt/data -xdev -type f 2>/dev/null | wc -l' 2>/dev/null || echo '?')"
}
PRE_SNAPSHOT=$(snapshot)
ql_info "legacy snapshot: $(tr '\n' ' ' <<<"$PRE_SNAPSHOT")"
grep -qx 'gateway_health=200' <<<"$PRE_SNAPSHOT" \
  || ql_warn "the legacy gateway does not answer 200 on /health right now; the post-cutover comparison will not prove much"

legacy_dir_ok=0
if [[ -d $legacy_dir ]]; then legacy_dir=$(cd -- "$legacy_dir" && pwd -P) && legacy_dir_ok=1
else ql_warn "no legacy checkout at $legacy_dir; its .env and compose file will not be in the backup"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-migrate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [[ $mode == dry-run ]]; then
  # Render and validate against a scratch env file rather than calling install.sh --dry-run: that
  # would create and edit ~/.config/hermes/hermes.env (ql_env_ensure and --set are not dry-run
  # aware), and a --dry-run that writes to the host is not a dry run.
  mkdir -p "$WORK/src" "$WORK/out"
  if [[ -f $ENV_FILE ]]; then cp -p -- "$ENV_FILE" "$WORK/$APP.env"; else install -m 600 -- "$ENV_EXAMPLE" "$WORK/$APP.env"; fi
  derive_env "$WORK/$APP.env"
  for kv in "${sets[@]}"; do ql_env_set "$WORK/$APP.env" "${kv%%=*}" "${kv#*=}"; done
  QL_ENV_MODE_CHECK=0 ql_env_load "$WORK/$APP.env"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$WORK/src/"
  cp -p "$REPO/systemd/hermes-provision.service" "$WORK/src/"
  RENDER_ARGS=()
  # shellcheck source=render-args.sh
  . "$REPO/scripts/render-args.sh"
  render_args "$WORK/$APP.env"
  ql_render "$WORK/src" "$WORK/$APP.env" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
  ql_dryrun "$WORK/out" --verify --ref-dir "$HOME/.config/containers/systemd" \
    || ql_die "the units do not render for this host; nothing was changed"
  commit_note=without
  if app_legacy_commit_wanted "$AGENT" >/dev/null 2>&1; then commit_note=with; fi
  if [[ $STRATEGY == capture ]]; then
    ql_info "dry-run: the checks pass and the units render. The cutover would stop the three containers, capture them into the backup directory ($AGENT $commit_note --commit) and remove them, because podman-restart.service would revive a renamed copy here, and then install with:"
  else
    ql_info "dry-run: the checks pass and the units render. The cutover would stop the three containers, rename them to *-legacy-$suffix and then install with:"
  fi
  printf '    %s\n' "${sets[@]}" >&2
  for vol in "${!VOL_ID_BEFORE[@]}"; do ql_info "adopted in place: $vol (${VOL_ID_BEFORE[$vol]})"; done
  exit 0
fi

# =============================================================================================
# 2. prepare (no downtime): env file, secrets carried over, image build
# =============================================================================================
ql_info "step 2/5: env file, secrets and the image build (no downtime)"
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
[[ $QL_ENV_CREATED != 1 ]] || ql_info "filling $ENV_FILE in from the legacy containers (review it after the cutover)"
derive_env "$ENV_FILE"
for kv in "${sets[@]}"; do ql_env_set "$ENV_FILE" "${kv%%=*}" "${kv#*=}"; done
ql_env_load "$ENV_FILE"

# The secrets the agent reads. Carried over from the legacy container so every API client, webhook
# sender and saved dashboard login keeps working; --rotate-secrets breaks all three on purpose.
carry() { # carry <secret> <container> <ENV KEY> <fallback length>
  local s=$1 c=$2 k=$3 n=$4 v
  v=$(env_of "$c" "$k")
  if ((rotate)); then
    ql_secret_ensure "$s" "random:$n" --replace
    return 0
  fi
  if [[ -z $v ]]; then
    ql_warn "the legacy $c has no $k; generating $s instead of carrying one over"
    ql_secret_ensure "$s" "random:$n"
    return 0
  fi
  # shellcheck disable=SC2034 # read by ql_secret_ensure through env:LEGACY_SECRET_VALUE
  LEGACY_SECRET_VALUE=$v
  ql_secret_ensure "$s" env:LEGACY_SECRET_VALUE --update
  unset LEGACY_SECRET_VALUE
}
carry hermes-api-server-key "$AGENT" API_SERVER_KEY 64
carry hermes-webhook-secret "$AGENT" WEBHOOK_SECRET 64
carry hermes-dashboard-password "$AGENT" HERMES_DASHBOARD_BASIC_AUTH_PASSWORD 32
# Never rotated: PostgreSQL reads POSTGRES_PASSWORD_FILE only when it initialises a cluster, so on
# an adopted one the recorded secret must be the password the cluster already has.
LEGACY_DB_PASSWORD=$(env_of "$DB" POSTGRES_PASSWORD)
if [[ -n $LEGACY_DB_PASSWORD ]]; then
  # shellcheck disable=SC2034 # read by ql_secret_ensure through env:LEGACY_DB_PASSWORD
  ql_secret_ensure hermes-postgres-password env:LEGACY_DB_PASSWORD --update
else
  ql_warn "the legacy $DB has no POSTGRES_PASSWORD in its environment; generating one. It will NOT match the adopted cluster - use --align-db-password, or fix it with ALTER ROLE"
  ql_secret_ensure hermes-postgres-password random:44
fi
unset LEGACY_DB_PASSWORD

# The pinned registry images too, so the cutover is not waiting on a download.
while IFS= read -r img; do
  [[ -n $img ]] || continue
  podman image exists "$img" && continue
  podman pull -q "$img" >/dev/null \
    || ql_die "could not pull $img; nothing was changed and the legacy stack is untouched"
done < <(sed -n 's/^Image=//p' "$REPO/quadlet/hermes-postgres.container" "$REPO/quadlet/hermes-redis.container")

# The image build takes 5-15 minutes plus the base pull. It happens here, while the legacy stack is
# still serving, so the cutover itself is not waiting for a build.
if podman image exists "$HERMES_IMAGE"; then
  ql_info "$HERMES_IMAGE is already present"
else
  ql_info "building $HERMES_IMAGE before any downtime"
  "$REPO/scripts/build-image.sh" || ql_die "the image build failed; nothing was changed and the legacy stack is untouched"
fi

# =============================================================================================
# 3. hot backup: pg_dump, volume exports, inspect, compose files, the rollback copy
# =============================================================================================
ql_info "step 3/5: hot backup (no downtime)"
bk=$(state_get BACKUP)
if [[ $(state_get STATUS) != prepared || ! -d $bk ]]; then bk=$(app_new_backup_dir migrate); fi
podman inspect "${LEGACY_CONTAINERS[@]}" >"$bk/inspect.json"
chmod 600 "$bk/inspect.json"   # it carries the provider keys, the GitHub token and both passwords
if ((legacy_dir_ok)); then
  for f in "$legacy_dir/deploy/podman/podman-compose.yml" "$legacy_dir/deploy/podman/.env" "$legacy_dir/deploy/podman/deploy.sh"; do
    [[ -r $f ]] || continue
    (umask 077 && cp -p -- "$f" "$bk/legacy-$(basename "$f")")
  done
fi
# A logical dump, not just the volume tar: a hot volume export of a running PostgreSQL is not a
# consistent backup, and the cold export in step 4 is the one that is.
ql_info "pg_dump of the hermes database"
(umask 077 && podman exec "$DB" pg_dump -U hermes -d hermes -Fc >"$bk/hermes-pg.dump.partial") \
  || ql_die "pg_dump failed; not continuing without a logical backup of the database"
mv -f "$bk/hermes-pg.dump.partial" "$bk/hermes-pg.dump"
if (umask 077 && podman exec "$DB" pg_dumpall -U hermes --roles-only >"$bk/roles.sql.partial"); then
  mv -f "$bk/roles.sql.partial" "$bk/roles.sql"
else
  rm -f -- "$bk/roles.sql.partial"
  ql_warn "pg_dumpall --roles-only failed; the role definitions are not in the backup"
fi
for spec in "${LEGACY_VOLUMES[@]}"; do ql_backup_volume "${spec%%:*}" "$bk" >/dev/null; done
{
  printf '%s\n' "$PRE_SNAPSHOT"
  printf 'legacy_image=%s (%s)\n' "$legacy_image" "${legacy_image_id:0:12}"
  printf 'legacy_health_body=%s\n' "$legacy_version"
  printf 'legacy_agent_writable_layer_bytes=%s\n' "${rw:-unknown}"
  for vol in "${!VOL_ID_BEFORE[@]}"; do printf 'volume=%s identity=%s\n' "$vol" "${VOL_ID_BEFORE[$vol]}"; done
} >"$bk/precheck.txt"
# On the capture path the rollback copy is written now, while the legacy stack still runs: a
# container whose create command cannot be replayed is refused here, before any downtime, and
# hermes-agent's writable layer is committed so a rollback gets the container it lost.
if [[ $STRATEGY == capture ]]; then app_legacy_capture "$bk" "${LEGACY_CONTAINERS[@]}"; fi
app_checksums "$bk"
state_set STRATEGY "$STRATEGY"
state_set STATUS prepared
state_set BACKUP "$bk"
state_set SUFFIX "$suffix"
state_set LEGACY_PORT_GATEWAY "$GW_PORT"
for vol in "${!VOL_ID_BEFORE[@]}"; do state_set "IDENTITY_$vol" "${VOL_ID_BEFORE[$vol]}"; done
ql_info "hot backup: $bk"
if [[ $mode == prepare ]]; then
  ql_info "prepared. Run the cutover with the same options minus --prepare-only"
  exit 0
fi

# =============================================================================================
# 4. stop + cold exports + retire (downtime starts here and is measured)
# =============================================================================================
app_confirm MIGRATE "$yes" "the cutover stops Hermes for several minutes and starts it from $HERMES_IMAGE instead of $legacy_image"
ql_info "step 4/5: stopping the legacy stack, cold exports, retiring the containers ($STRATEGY)"
state_set STATUS cutover
DOWN_FROM=$(now_s)
podman stop -t 60 "$AGENT" >/dev/null || ql_die "could not stop $AGENT"
podman stop -t 60 "$CACHE" "$DB" >/dev/null || ql_die "could not stop $CACHE / $DB"
for c in "${LEGACY_CONTAINERS[@]}"; do ! running "$c" || ql_die "$c is still running"; done
for spec in "${LEGACY_VOLUMES[@]}"; do ql_backup_volume "${spec%%:*}" "$bk" >/dev/null; done
app_legacy_retire "$STRATEGY" "$suffix" "$bk" "${LEGACY_CONTAINERS[@]}"
app_checksums "$bk"
ql_wait_until 60 "the published ports to be released" bash -c \
  "! ss -ltnH 'sport = :$GW_PORT' 2>/dev/null | grep -q ." || ql_warn "port $GW_PORT is still bound; the install may fail"
if ((reapply_policy)); then
  ql_warn "--reapply-config-policy: hermes-provision.service will apply the WOOWTECH config policy to the adopted /opt/data again, reverting anything changed in the dashboard since the compose deploy.sh ran it"
else
  stamp_config_policy || ql_die "could not stamp .woow-policy-v1 on $DATA_VOLUME; run with --reapply-config-policy if that is what you want"
fi

# =============================================================================================
# 5. install (adopts the three volumes by name), prove it, smoke, compare
# =============================================================================================
ql_info "step 5/5: scripts/install.sh"
failed=0
"$REPO/scripts/install.sh" --accept-defaults --no-build --no-smoke "${no_llm[@]}" || failed=1
DOWN_TO=$(now_s)
if ((!failed)); then
  # The proof: same mountpoint, same inode, same CreatedAt. A .volume rendered with the default
  # name would have produced a brand new, empty hermes-data here, and this is what catches it.
  for vol in "${!VOL_ID_BEFORE[@]}"; do
    got=$(app_volume_identity "$vol") || { ql_warn "volume $vol disappeared"; failed=1; continue; }
    if [[ $got == "${VOL_ID_BEFORE[$vol]}" ]]; then
      ql_info "adopted $vol in place: mountpoint|CreatedAt|inode unchanged ($got)"
    else
      ql_warn "volume $vol is NOT the one the legacy stack used: before [${VOL_ID_BEFORE[$vol]}] after [$got]"
      failed=1
    fi
  done
  for spec in "${LEGACY_VOLUMES[@]}"; do
    IFS=: read -r vol dest ctr _ <<<"$spec"
    grep -qx "$vol|$dest" < <(mounts_of "$ctr") || { ql_warn "the new $ctr does not mount $vol at $dest"; failed=1; }
  done
fi
if ((failed == 0)) && ((align_db)); then
  # The value goes in over stdin and psql reads it from a variable, so it is in neither this
  # host's process list nor the server log (\password-style quoting via :'pw').
  align_sql='ALTER ROLE hermes WITH PASSWORD :'"'"'pw'"'"';'
  if printf '%s' "$(app_secret_read hermes-postgres-password)" | podman exec -i "$DB" \
      sh -c 'read -r p; psql -U hermes -d hermes -q -v pw="$p" -c "$0"' "$align_sql" >/dev/null 2>&1; then
    ql_info "the hermes role's password now matches the hermes-postgres-password secret"
  else
    ql_warn "--align-db-password: ALTER ROLE failed; the cluster keeps the legacy password"
  fi
fi
((failed)) || "$REPO/tests/smoke.sh" || failed=1
if ((failed)); then
  if ((auto_rollback)); then
    ql_warn "the cutover failed; rolling back automatically (--no-auto-rollback keeps it for inspection)"
    yes=1 rollback
    ql_die "migration failed and was rolled back; the legacy stack runs again. Logs: journalctl --user -u $MAIN_UNIT"
  fi
  ql_die "the cutover failed; the new units are left in place. Inspect, then run: $0 --rollback"
fi
POST_SNAPSHOT=$(snapshot)
{ printf '\n--- after ---\n'; printf '%s\n' "$POST_SNAPSHOT"; } >>"$bk/precheck.txt"
app_checksums "$bk"
ql_info "before: $(tr '\n' ' ' <<<"$PRE_SNAPSHOT")"
ql_info "after:  $(tr '\n' ' ' <<<"$POST_SNAPSHOT")"
for k in db_tables db_databases redis_keys; do
  a=$(sed -n "s/^$k=//p" <<<"$PRE_SNAPSHOT") b=$(sed -n "s/^$k=//p" <<<"$POST_SNAPSHOT")
  [[ $a == "$b" ]] || ql_warn "$k changed across the cutover: $a -> $b (compare with $bk/precheck.txt)"
done
ql_info "data_files under /opt/data is expected to differ: the new image provisions config and skills on first start"

downtime=$((DOWN_TO - DOWN_FROM))
state_set DOWNTIME_S "$downtime"
state_set DONE_AT "$(date -Is)"
state_set STATUS "done"
ql_info "measured downtime: ${downtime}s (from 'podman stop $AGENT' to the Quadlet stack answering)"
if [[ $STRATEGY == capture ]]; then
  ql_info "migration complete. The legacy containers were captured into $bk/legacy-container and removed. Roll back with:"
else
  ql_info "migration complete. The legacy containers *-legacy-$suffix are kept (stopped) for rollback:"
fi
ql_info "  $0 --rollback"
ql_warn "do NOT remove the network $LEGACY_NETWORK during the soak: despite its generic name it is this stack's compose network and the rollback needs it"
ql_info "after the soak period, clean up as described in README ('After the soak')"
