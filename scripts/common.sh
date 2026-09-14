# shellcheck shell=bash disable=SC2034 # the settings are read by the scripts that source this file
# scripts/common.sh: settings and helpers shared by this repo's scripts. Sourced after
# scripts/lib/quadlet-lib.sh (which is vendored and must not be edited). This file is repo-owned;
# the helpers below the settings block are the same in Woow_podman_emqx, Woow_podman_hermes,
# Woow_podman_odoo and Woow_podman_opendesign.

# ---- per-repo settings ------------------------------------------------------------------------
APP=hermes
PODMAN_MIN=4.9
ENV_EXAMPLE=$REPO/config/$APP.env.example
ENV_FILE=$HOME/.config/$APP/$APP.env
BACKUP_ROOT=$HOME/.local/share/woow-backups/$APP
# container:unit pairs the units create (legacy-collision guard)
CONTAINERS=("hermes-agent:hermes-agent.service" "hermes-postgresql:hermes-postgres.service" "hermes-redis:hermes-redis.service")
# env keys allowed to carry user-supplied credentials (ERE on the whole key; empty = none)
ENV_CREDENTIAL_ALLOW='(MINIMAX_API_KEY|OPENROUTER_API_KEY|GITHUB_TOKEN|MCP_[A-Z0-9_]+)'
# scripts/migrate-legacy.sh, capture path (STANDARD 7a): containers whose own deploy or upgrade
# script writes into the running container, so a capture must commit the writable layer first.
# The compose-era deploy/podman/deploy.sh apt-installed tmux, uv-installed ddgs into the agent venv,
# downloaded OfficeCLI, symlinked into /usr/local/bin, deleted skill packs under /opt/hermes and
# patched Python sources there - all with `podman exec` against hermes-agent. The live container on
# woowtechopenclaw measures 42 672 686 bytes / 844 files of writable layer as a result, so a capture
# without --commit would hand a rollback a container missing every one of those changes.
LEGACY_COMMIT_ALWAYS='hermes-agent'
# ...and the measured writable-layer size above which any container is committed anyway. The live
# hermes-postgresql is 1 087 119 bytes, just over this, and is committed for that reason alone.
LEGACY_COMMIT_RW_BYTES=1048576
# the agent image: one tag per base + patch set, so an upgrade keeps the previous image for rollback.
# tests/dryrun.local.sh checks both against quadlet/hermes-agent.container and container/Containerfile.
HERMES_IMAGE_TAG=v2026.8.31-woow1
HERMES_BASE=docker.io/nousresearch/hermes-agent:v2026.8.31@sha256:64923faeae267792bf9bf87fe3b4c4869e35004e360c7df01730ad801b74d524
HERMES_IMAGE=localhost/woow-hermes-agent:$HERMES_IMAGE_TAG
# ------------------------------------------------------------------------------------------------
export QL_APP=$APP

app_state_dir() { printf '%s/%s' "${QL_STATE_ROOT:-$HOME/.local/state/woow-quadlet}" "$APP"; }

# app_env_keys <file>: the KEY names a KEY=VALUE file defines
app_env_keys() { sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$1"; }

# app_is_credential_key <KEY>: names whose values are credentials
app_is_credential_key() { [[ $1 =~ (PASSWORD|PASSWD|SECRET|TOKEN|_KEY)$ ]]; }

# app_apply_sets KEY=VALUE...: store per-host settings (install.sh --set) in the env file. Only keys
# the example defines are accepted, and never credentials (they would end up in argv and history).
app_apply_sets() {
  local kv k
  for kv in "$@"; do
    [[ $kv == *=* ]] || ql_die "--set $kv: expected KEY=VALUE"
    k=${kv%%=*}
    [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || ql_die "--set $kv: invalid key"
    app_env_keys "$ENV_EXAMPLE" | grep -qxF -- "$k" || ql_die "--set $k: not a setting in ${ENV_EXAMPLE##*/}"
    if app_is_credential_key "$k"; then
      ql_die "--set $k: put credentials into $ENV_FILE with an editor, not on the command line"
    fi
    if [[ ! -f $ENV_FILE && ${QL_DRY_RUN:-0} == 1 ]]; then
      ql_info "[dry-run] would set $k in $ENV_FILE"
      continue
    fi
    ql_env_set "$ENV_FILE" "$k" "${kv#*=}"
    ql_info "set $k in $ENV_FILE"
  done
}

# app_env_load: load the env file (the example when --dry-run runs before the file exists) into
# QL_ENV. Sets RENDER_ENV to the file that was loaded.
app_env_load() {
  if [[ -f $ENV_FILE ]]; then
    ql_env_load "$ENV_FILE"
    RENDER_ENV=$ENV_FILE
  else
    QL_ENV_MODE_CHECK=0 ql_env_load "$ENV_EXAMPLE"
    RENDER_ENV=$ENV_EXAMPLE
  fi
}

# app_env_overlay KEY=VALUE...: apply --set values to QL_ENV as well, so a --dry-run (which does not
# write the env file) renders what a real run would.
app_env_overlay() {
  local kv
  for kv in "$@"; do QL_ENV[${kv%%=*}]=${kv#*=}; done
}

# app_refuse_env_secrets: generated credentials live in podman secrets, never in the env file.
app_refuse_env_secrets() {
  local k
  for k in "${QL_ENV_KEYS[@]}"; do
    app_is_credential_key "$k" || continue
    [[ -n ${QL_ENV[$k]} ]] || continue
    if [[ -n $ENV_CREDENTIAL_ALLOW && $k =~ ^($ENV_CREDENTIAL_ALLOW)$ ]]; then continue; fi
    ql_die "$ENV_FILE sets $k. Generated credentials live in podman secrets (see README, Secrets); remove the line and run again"
  done
}

# The env file is not a unit, so Quadlet cannot see that it changed. Remember a hash of the lines
# the container reads (comments and the WOOW_* installer knobs are left out: their effect already
# shows up in the rendered units) and restart the container when it differs.
_app_env_sha_file() { printf '%s/applied-env.sha256' "$(app_state_dir)"; }
_app_env_sha() {
  local s
  s=$({ grep -vE '^(WOOW_|#|[[:space:]]*$)' "$ENV_FILE" || true; } | sha256sum) && printf '%s' "${s%% *}"
}
app_env_changed() {
  local want
  [[ -f $ENV_FILE ]] || return 1
  want=$(cat "$(_app_env_sha_file)" 2>/dev/null || true)
  [[ $(_app_env_sha) != "$want" ]]
}
app_env_record() {
  [[ ${QL_DRY_RUN:-0} == 1 || ! -f $ENV_FILE ]] && return 0
  mkdir -p "$(app_state_dir)" && printf '%s\n' "$(_app_env_sha)" >"$(_app_env_sha_file)"
}

# app_secret_read <name>: print a podman secret's value on stdout. Capture it; never echo it.
app_secret_read() { podman secret inspect --showsecret --format '{{.SecretData}}' "$1" 2>/dev/null; }

# SECRET_HYGIENE_MIN_LEN: floor below which a raw substring hit is not trusted as a real leak (see
# app_secret_leak_status). install.sh never generates anything shorter than 32 chars; the only way a
# secret this repo checks is shorter is scripts/migrate-legacy.sh carry(), which imports whatever
# length the legacy .env happened to hold. Keep this in sync with the comment at that call site.
SECRET_HYGIENE_MIN_LEN=16

# app_secret_leak_status <secret> <haystack...>: is <secret> a leak, given it was found (or not) in
# one or more haystacks (journal text, container logs, ...)?
#   clean   <secret> is empty, or none of the haystacks contain it
#   warn    a haystack contains it, but <secret> is shorter than SECRET_HYGIENE_MIN_LEN chars - a raw
#           substring search this short has a real chance of an accidental hit against ordinary text
#           (container labels, MCP server names, config keys: anything with short alnum runs), so
#           this is not trustworthy evidence of a leak on its own. Confirmed real case: the 8-char
#           dashboard password migrate-legacy.sh carried over from a legacy .env was, by coincidence,
#           a literal substring of both the io.woowtech.hermes.base image label and the
#           woowtech_odoo_mcp MCP server name - neither of which had anything to do with the secret.
#   fail    a haystack contains it and <secret> is at least SECRET_HYGIENE_MIN_LEN chars - at that
#           length an accidental collision against real-world text is astronomically unlikely, so a
#           hit is trusted as an actual leak.
app_secret_leak_status() {
  local secret=$1 hay
  shift
  [[ -n $secret ]] || { printf 'clean'; return 0; }
  for hay in "$@"; do
    if [[ $hay == *"$secret"* ]]; then
      if ((${#secret} >= SECRET_HYGIENE_MIN_LEN)); then printf 'fail'; else printf 'warn'; fi
      return 0
    fi
  done
  printf 'clean'
}

# app_guard_containers: a same-named container that Quadlet does not manage would be deleted by
# `podman run --replace`; refuse, and print the rename command.
app_guard_containers() {
  local c
  for c in "${CONTAINERS[@]}"; do ql_check_container_collision "${c%%:*}" "${c#*:}"; done
}

# app_wait_healthy <container> <timeout_s> <unit>: health gate that points at the logs on failure
app_wait_healthy() {
  ql_wait_container_healthy "$1" "$2" || ql_die "$1 did not become healthy; see: journalctl --user -u $3 -n 100"
}

# app_local_host <bind>: the address this host uses to reach a port published on <bind>
app_local_host() {
  case $1 in all | 0.0.0.0 | '') printf '127.0.0.1' ;; *) printf '%s' "$1" ;; esac
}

# app_confirm <word> <yes 0|1> <what>: require typing <word> unless --yes (or --dry-run)
app_confirm() {
  local word=$1 yes=$2 what=$3 answer
  ((yes)) && return 0
  [[ ${QL_DRY_RUN:-0} == 1 ]] && return 0
  [[ -t 0 ]] || ql_die "$what; add --yes to confirm non-interactively"
  read -r -p "Type '$word' to confirm ($what): " answer
  [[ $answer == "$word" ]] || ql_die "aborted; nothing was changed"
}

# app_new_backup_dir <label>: create a private directory under $BACKUP_ROOT and print its path
app_new_backup_dir() {
  local d i=2
  (umask 077 && mkdir -p -- "$BACKUP_ROOT") || ql_die "cannot create $BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"
  d=$BACKUP_ROOT/$1-$(date +%Y%m%d-%H%M%S)
  while [[ -e $d ]]; do d=$BACKUP_ROOT/$1-$(date +%Y%m%d-%H%M%S)-$i; i=$((i + 1)); done
  (umask 077 && mkdir -- "$d") || ql_die "cannot create $d"
  printf '%s' "$d"
}

# app_checksums <dir>: SHA256SUMS for every file in <dir> (relative paths)
app_checksums() {
  (cd -- "$1" && umask 077 && find . -type f ! -name 'SHA256SUMS*' -printf '%P\0' | LC_ALL=C sort -z \
    | xargs -0 -r sha256sum -- >SHA256SUMS.partial && mv -f SHA256SUMS.partial SHA256SUMS) \
    || ql_die "cannot write checksums in $1"
}

# app_snapshot <dir>: save every installed file of the app plus its manifest (upgrade rollback)
app_snapshot() {
  local dir=$1 mf
  mf="$(app_state_dir)/manifest"
  (umask 077 && mkdir -p -- "$dir") || ql_die "cannot create $dir"
  if [[ ! -f $mf ]]; then
    ql_warn "$APP has no installed files recorded; nothing to snapshot"
    return 0
  fi
  cp -p -- "$mf" "$dir/manifest"
  awk '{ sub(/^[^ ]+  /, ""); print }' "$mf" >"$dir/files.list"
  (umask 077 && tar -cPf "$dir/files.tar" -T "$dir/files.list") || ql_die "cannot snapshot the installed files"
  ql_info "saved the installed units in $dir"
}

# app_snapshot_restore <dir>: put the snapshot back (files and manifest), remove files that a failed
# run added, daemon-reload. Returns 1 when there is nothing to restore.
app_snapshot_restore() {
  local dir=$1 mf p
  mf="$(app_state_dir)/manifest"
  [[ -f $dir/manifest && -f $dir/files.tar ]] || { ql_warn "no snapshot in $dir"; return 1; }
  if [[ -f $mf ]]; then
    while read -r _ p; do
      [[ -n $p ]] || continue
      grep -qxF -- "$p" "$dir/files.list" || rm -f -- "$p"
    done <"$mf"
  fi
  tar -xPf "$dir/files.tar" || return 1
  cp -p -- "$dir/manifest" "$mf" || return 1
  rm -f -- "$(app_state_dir)/pending-restart"
  systemctl --user daemon-reload
}
