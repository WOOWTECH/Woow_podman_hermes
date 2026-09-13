#!/usr/bin/env bash
# tests/rollback-model.sh: pins the rollback model, the writable-layer decision and the adoption
# proof that scripts/migrate-legacy.sh relies on (STANDARD 7a). The helpers it exercises live in
# scripts/legacy-common.sh - app_legacy_rw_bytes, app_legacy_commit_wanted, app_legacy_capture,
# app_legacy_retire, app_legacy_restore and app_volume_identity.
#
#   tests/rollback-model.sh [name-filter]
#
# podman and systemctl are the doubles in tests/shims, placed first on PATH; every test gets its own
# HOME and shim state. No container is created and the real user manager is never touched.
#
# Hermes is the stack that needs the --commit half of the capture path. Its compose-era
# deploy/podman/deploy.sh mutated the RUNNING hermes-agent with podman exec (apt-get tmux, uv pip
# install ddgs into the agent venv, an OfficeCLI download, /usr/local/bin symlinks, rm -rf of skill
# packs under /opt/hermes, two Python patches). On woowtechopenclaw that container measures
# 42 672 686 bytes / 844 files of writable layer, so capture-then-remove without --commit would hand
# a rollback a container missing every one of those changes. The fixtures below carry the measured
# sizes of all three live containers.
#
# All three hermes containers are `unless-stopped` on woowtechopenclaw, so that host takes the
# rename path today; the capture path is pinned here rather than by that host.
#
# Every test runs in its own subshell on purpose (isolated HOME, shim state, env), so the
# "modified in a subshell" notes do not apply here:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hermes-rollback-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
calls() { cat "$SHIM_STATE/calls"; }
ncalls() { grep -cF -- "$1" "$SHIM_STATE/calls" || true; }
OUT=''
expect_ok() { OUT=$( ("$@") 2>&1) || die_t "expected success of: $*"$'\n'"$OUT"; }
expect_fail() { if OUT=$( ("$@") 2>&1); then die_t "expected failure of: $*"$'\n'"$OUT"; fi; }

# ---- fixtures ---------------------------------------------------------------------------
# mk_hermes <container> <policy> [rw bytes]: one of the three live containers of woowtechopenclaw,
# as podman-compose left it. The CreateCommand is a `podman run` carrying -d and NO --restart
# (compose keeps the policy on the container object only), and the writable-layer sizes are the ones
# measured on that host with `podman inspect --size`.
mk_hermes() {
  local name=$1 policy=$2 rw=${3:-} image d vol dest
  case $name in
    hermes-agent) image=docker.io/nousresearch/hermes-agent:latest; vol=podman_hermes-data; dest=/opt/data; rw=${rw:-42672686} ;;
    hermes-postgresql) image=docker.io/library/postgres:15; vol=podman_postgres-data; dest=/var/lib/postgresql/data; rw=${rw:-1087119} ;;
    hermes-redis) image=docker.io/library/redis:7-alpine; vol=podman_redis-data; dest=/data; rw=${rw:-11376} ;;
    *) die_t "mk_hermes: unknown container $name" ;;
  esac
  d=$SHIM_STATE/containers/$name
  mkdir -p "$d" "$SHIM_STATE/image-ids"
  printf '%s' "$policy" >"$d/policy"
  printf '0' >"$d/retries"
  printf 'cid-%s' "$name" >"$d/id"
  printf '%s' "$image" >"$d/image"
  printf 'imgid-%s' "$name" >"$d/image_id"
  printf 'imgid-%s' "$name" >"$SHIM_STATE/image-ids/${image//[\/:@]/_}"
  printf 'bridge' >"$d/netmode"
  printf 'false' >"$d/autoremove"
  # the compose project really is called "podman": the compose file lives in deploy/podman/
  printf 'podman' >"$d/project"
  printf '%s' "${name#hermes-}" >"$d/service"
  printf '%s' "$rw" >"$d/sizerw"
  printf 'volume|%s|/vol/%s|%s|true|rprivate\n' "$vol" "$vol" "$dest" >"$d/mounts"
  printf 'podman_default|%s cid-%s |10.89.2.7|aa:bb:cc:dd:ee:07\n' "$name" "$name" >"$d/networks"
  : >"$d/ports"
  [[ $name != hermes-agent ]] || printf '8642/tcp|0.0.0.0:18642 \n9119/tcp|0.0.0.0:19119 \n8644/tcp|0.0.0.0:18644 \n' >"$d/ports"
  printf 'io.podman.compose.project=podman\n' >"$d/labels"
  : >"$d/label"
  printf '%s\0' /usr/bin/podman run "--name=$name" -d \
    --label io.podman.compose.project=podman \
    -v "$vol:$dest" --net podman_default "$image" >"$d/createcommand.argv0"
}
mk_stack() { mk_hermes hermes-agent "$1"; mk_hermes hermes-postgresql "$1"; mk_hermes hermes-redis "$1"; }
STACK=(hermes-agent hermes-postgresql hermes-redis)
# mk_api_created <name> <policy>: created through the podman API (docker-compose over the socket,
# podman play): the CreateCommand is empty, so nothing can be replayed.
mk_api_created() {
  mk_hermes "$1" "$2"
  : >"$SHIM_STATE/containers/$1/createcommand.argv0"
}
enable_restart_unit() { # what woowtechopenclaw looks like
  mkdir -p "$SHIM_STATE/units/podman-restart.service"
  echo enabled >"$SHIM_STATE/units/podman-restart.service/UnitFileState"
}
# mk_volume <name>: a real directory plus the mountpoint|CreatedAt row the shim's volume inspect
# returns, so app_volume_identity can stat it for an inode.
mk_volume() {
  local v=$1 mp=$T/vols/$1
  mkdir -p "$mp" "$SHIM_STATE/vol-owner" "$SHIM_STATE/volumes/$v"
  printf '%s|2026-08-28 08:31:22.941209879 +0800 CST' "$mp" >"$SHIM_STATE/vol-owner/$v"
}

# set_project <container> <value>: change the compose project a container claims to belong to.
# Both files matter: `project` is what the shim returns for the capture's multi-field template, and
# `labels` is what it returns for ANY {{...Config.Labels...}} format (the double returns the whole
# labels file rather than indexing one key), which is what app_check_not_foreign asks for.
set_project() {
  printf '%s' "$2" >"$SHIM_STATE/containers/$1/project"
  printf '%s' "$2" >"$SHIM_STATE/containers/$1/labels"
}

# ---- the toypark shape: rename, and nothing else ------------------------------------------
t_disabled_restart_unit_keeps_the_rename_path() {
  mk_stack unless-stopped
  eq "$(ql_rollback_strategy "${STACK[@]}" 2>/dev/null)" rename "strategy on a toypark-like host"
  expect_ok app_legacy_retire rename 20260914 "$T/bk" "${STACK[@]}"
  has "$OUT" "renamed hermes-agent -> hermes-agent-legacy-20260914"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed on the rename path"
  eq "$(ncalls 'podman commit')" 0 "nothing is committed on the rename path"
  [[ ! -d $T/bk/legacy-container ]] || die_t "the rename path must not write a capture"
  expect_ok app_legacy_restore 20260914 "$T/bk" "${STACK[@]}"
  for c in "${STACK[@]}"; do podman container exists "$c" || die_t "the rollback did not bring $c back"; done
  eq "$(ncalls 'podman create')" 0 "a renamed container is not recreated"
}

t_the_openclaw_stack_is_unless_stopped_so_even_that_host_renames() {
  # All three hermes containers are unless-stopped, and podman-restart.service's filter compares the
  # policy string exactly, so an enabled restart unit does not make them dangerous.
  enable_restart_unit
  mk_stack unless-stopped
  eq "$(ql_rollback_strategy "${STACK[@]}" 2>/dev/null)" rename "unless-stopped is not matched by the restart filter"
}

t_one_always_container_moves_the_whole_stack_to_capture() {
  # The set is rolled back together, so one `always` container decides for all three.
  enable_restart_unit
  mk_hermes hermes-agent always
  mk_hermes hermes-postgresql unless-stopped
  mk_hermes hermes-redis unless-stopped
  eq "$(ql_rollback_strategy "${STACK[@]}" 2>/dev/null)" capture "one always container is enough"
}

# ---- the capture path -----------------------------------------------------------------------
t_the_capture_path_removes_and_the_rollback_recreates_all_three() {
  enable_restart_unit
  mk_stack always
  eq "$(ql_rollback_strategy "${STACK[@]}" 2>/dev/null)" capture "strategy on an openclaw-like host"
  expect_ok app_legacy_capture "$T/bk" "${STACK[@]}"
  for c in "${STACK[@]}"; do
    [[ -s $T/bk/legacy-container/$c/meta ]] || die_t "no capture of $c"
    eq "$(sed -n 's/^RECREATABLE=//p' "$T/bk/legacy-container/$c/meta")" 1 "$c is recreatable"
    eq "$(sed -n 's/^RESTART_POLICY=//p' "$T/bk/legacy-container/$c/meta")" always "$c policy recorded"
  done
  # capturing is read-only: the legacy stack is still serving at this point
  eq "$(ncalls 'podman rm ')" 0 "the capture removes nothing"
  eq "$(ncalls 'podman rename')" 0 "the capture renames nothing"
  expect_ok app_legacy_retire capture "" "$T/bk" "${STACK[@]}"
  for c in "${STACK[@]}"; do podman container exists "$c" && die_t "$c was not removed"; done
  expect_ok app_legacy_restore "" "$T/bk" "${STACK[@]}"
  for c in "${STACK[@]}"; do
    podman container exists "$c" || die_t "the rollback did not recreate $c"
    eq "$(ql_container_restart_policy "$c")" always "$c comes back with its original policy"
  done
  return 0
}

t_the_capture_path_never_removes_the_volumes() {
  enable_restart_unit
  mk_stack always
  expect_ok app_legacy_capture "$T/bk" "${STACK[@]}"
  expect_ok app_legacy_retire capture 20260914 "$T/bk" "${STACK[@]}"
  hasnt "$(calls)" "podman rm -v" "rm -v would delete the anonymous volumes the capture expects back"
  hasnt "$(calls)" "podman rm --volumes" "rm --volumes would delete the anonymous volumes"
  hasnt "$(calls)" "volume rm" "the migration never removes a volume"
}

t_capture_refuses_a_container_the_library_cannot_replay() {
  # A container created through the podman API (docker-compose over the socket, podman play) has an
  # empty CreateCommand. For hermes-agent the refusal comes one step earlier than the RECREATABLE
  # check in app_legacy_capture: --commit succeeds, and then ql_capture_container cannot find the
  # image argument to rewrite, so it dies there. Either way the capture refuses and nothing is
  # removed, which is what has to hold - discovered in the prepare phase, before any downtime.
  enable_restart_unit
  mk_api_created hermes-agent always
  expect_fail app_legacy_capture "$T/bk" hermes-agent
  has "$OUT" "created through the API"
  eq "$(ncalls 'podman rm ')" 0 "a refused capture removes nothing"
  # and because no usable rollback copy was written, retiring would refuse too
  expect_fail app_legacy_retire capture "" "$T/bk" hermes-agent
  has "$OUT" "no rollback copy of hermes-agent"
}

t_capture_refuses_an_unreplayable_database_too() {
  # hermes-postgresql is committed on size alone, so it takes the same path; hermes-redis is not
  # committed and is stopped by app_legacy_capture's own RECREATABLE check instead. Both refuse.
  enable_restart_unit
  mk_api_created hermes-redis always
  expect_fail app_legacy_capture "$T/bk" hermes-redis
  has "$OUT" "podman API"
  eq "$(ncalls 'podman rm ')" 0 "a refused capture removes nothing"
}

t_retire_refuses_to_remove_without_a_capture() {
  enable_restart_unit
  mk_stack always
  expect_fail app_legacy_retire capture 20260914 "$T/bk" "${STACK[@]}"
  has "$OUT" "no rollback copy of hermes-agent"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed without a capture"
}

t_capture_is_idempotent_between_prepare_only_and_the_cutover() {
  enable_restart_unit
  mk_stack always
  expect_ok app_legacy_capture "$T/bk" "${STACK[@]}"   # --prepare-only
  local first
  first=$(ncalls 'podman commit')
  expect_ok app_legacy_capture "$T/bk" "${STACK[@]}"   # the cutover reuses the same backup dir
  has "$OUT" "already in"
  eq "$(ncalls 'podman commit')" "$first" "a second capture re-commits nothing"
}

# ---- the writable-layer decision: the reason hermes needs --commit --------------------------
t_the_measured_writable_layers_are_what_the_live_host_reports() {
  # podman inspect --size is the measurement. `podman diff hermes-agent` prints an empty object on
  # woowtechopenclaw while SizeRw is 42 672 686, so it is NOT a substitute.
  mk_stack unless-stopped
  eq "$(app_legacy_rw_bytes hermes-agent)" 42672686 "hermes-agent writable layer"
  eq "$(app_legacy_rw_bytes hermes-postgresql)" 1087119 "hermes-postgresql writable layer"
  eq "$(app_legacy_rw_bytes hermes-redis)" 11376 "hermes-redis writable layer"
  grep -q 'podman inspect --size' "$REPO/scripts/legacy-common.sh" \
    || die_t "app_legacy_rw_bytes no longer asks podman for SizeRw"
}

t_hermes_agent_is_committed_because_its_own_deploy_script_mutated_it() {
  # Declared in scripts/common.sh, so it holds even if the writable layer were small: the reason is
  # what deploy.sh did, not how big the result is.
  mk_hermes hermes-agent always 4096
  expect_ok app_legacy_commit_wanted hermes-agent
  has "$OUT" "writes into its own container"
  grep -q "^LEGACY_COMMIT_ALWAYS='hermes-agent'" "$REPO/scripts/common.sh" \
    || die_t "scripts/common.sh no longer declares hermes-agent as a self-mutating container"
}

t_the_capture_of_hermes_agent_commits_and_the_rollback_starts_from_that_image() {
  enable_restart_unit
  mk_stack always
  expect_ok app_legacy_capture "$T/bk" hermes-agent
  eq "$(ncalls 'podman commit')" 1 "hermes-agent is committed once"
  local committed
  committed=$(sed -n 's/^COMMIT_IMAGE=//p' "$T/bk/legacy-container/hermes-agent/meta")
  [[ -n $committed ]] || die_t "the capture recorded no committed image"
  expect_ok app_legacy_retire capture "" "$T/bk" hermes-agent
  expect_ok app_legacy_restore "" "$T/bk" hermes-agent
  has "$OUT" "recreated hermes-agent"
  # the recreated container runs the committed image, not the upstream one it was created from
  eq "$(podman inspect --format '{{.Config.Image}}' hermes-agent)" "$committed" "the recreated image"
}

t_hermes_postgresql_is_committed_on_size_alone() {
  # 1 087 119 bytes, just over the 1 MiB threshold. It is not in LEGACY_COMMIT_ALWAYS: the
  # measurement is what decides, so the threshold is doing real work here.
  mk_hermes hermes-postgresql always
  expect_ok app_legacy_commit_wanted hermes-postgresql
  has "$OUT" "1087119 bytes"
}

t_hermes_redis_is_not_committed() {
  mk_hermes hermes-redis always
  expect_fail app_legacy_commit_wanted hermes-redis
  has "$OUT" "nothing worth committing"
}

t_an_unmeasurable_writable_layer_warns_instead_of_committing_silently() {
  expect_fail app_legacy_commit_wanted hermes-redis   # no such container: SizeRw is unknown
  has "$OUT" "cannot measure the writable layer"
}

# ---- the adoption proof ----------------------------------------------------------------------
t_volume_identity_is_mountpoint_createdat_and_inode() {
  mk_volume podman_hermes-data
  local id
  id=$(app_volume_identity podman_hermes-data) || die_t "app_volume_identity failed"
  has "$id" "$T/vols/podman_hermes-data" "the mountpoint"
  has "$id" "2026-08-28 08:31:22.941209879 +0800 CST" "the CreatedAt"
  eq "${id##*|}" "$(stat -c %i "$T/vols/podman_hermes-data")" "the inode"
}

t_volume_identity_changes_when_the_volume_is_not_the_same_one() {
  # The whole point: a unit rendered with the DEFAULT name would make a new, empty hermes-data
  # instead of adopting podman_hermes-data, and the migration has to notice.
  mk_volume podman_hermes-data
  mk_volume hermes-data
  [[ $(app_volume_identity podman_hermes-data) != $(app_volume_identity hermes-data) ]] \
    || die_t "two different volumes produced the same identity; the proof cannot fail"
}

t_volume_identity_fails_loudly_for_a_volume_that_is_gone() {
  expect_fail app_volume_identity podman_hermes-data
}

# ---- the per-app lock, as quadlet-lib 1.5.0 defines it ---------------------------------------
# Up to 1.4.0 the lock was an flock on a descriptor opened with `exec {fd}>`, which bash does not
# mark close-on-exec. Rootless podman leaves children behind by design - conmon, slirp4netns,
# rootlessport, the catatonit pause process - and every one of them inherited that descriptor and
# held the flock for as long as the container lived. The next install, upgrade, uninstall or
# --rollback then died with "another install/upgrade/uninstall is running". Reproduced live on
# toypark1234, where /proc named conmon and slirp4netns as the two holders, and worked around here
# with an app_unlocked wrapper that closed the descriptor for one command.
#
# 1.5.0 deletes the descriptor instead. The lock is the DIRECTORY <state>/<app>/lock.d holding an
# owner record of boot id, pid and that pid's start time, and "held" means that owner is still
# alive: a crashed lock is taken over, not waited on. QL_LOCK_FD survives as an always-empty
# variable so that scripts written against <= 1.4.0 still parse under `set -u`, which makes every
# app_unlocked wrapper a no-op. The wrapper is therefore gone, and what follows pins the property
# it was standing in for instead of pinning the wrapper.

t_the_lock_keeps_no_descriptor_for_a_child_to_inherit() {
  local dir rec f n=0
  ql_lock hermes
  eq "${QL_LOCK_FD:-}" '' "QL_LOCK_FD (1.5.0 keeps it only so <= 1.4.0 callers still parse)"
  dir=$(_ql_state_dir hermes)/lock.d
  [[ -d $dir ]] || die_t "ql_lock did not create the lock directory $dir"
  read -r rec <"$dir/owner" || die_t "the lock directory carries no owner record"
  eq "$rec" "$(_ql_owner_record)" "the owner record of the lock this shell holds"
  for f in /proc/self/fd/*; do
    if [[ $(readlink -- "$f" 2>/dev/null) == "$dir"* ]]; then n=$((n + 1)); fi
  done
  eq "$n" 0 "descriptors in this shell pointing at the lock"
  # ... and the same seen from an ordinary child, which is what conmon is
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  eq "$(bash -c 'n=0
    for f in /proc/self/fd/*; do
      if [[ $(readlink -- "$f" 2>/dev/null) == "$1"* ]]; then n=$((n + 1)); fi
    done
    printf %s "$n"' _ "$dir")" 0 "lock descriptors an ordinary child inherits"
  return 0
}

t_a_rollback_can_take_the_lock_after_an_earlier_run_left_processes_behind() {
  # The user-visible property app_unlocked was faking. A run takes the lock, leaves a process
  # running that outlives it - conmon's stand-in, and the reason the old descriptor leaked - and
  # exits normally. The rollback is this shell, and it must be able to take the same lock while
  # that process is still alive. Under 1.4.0 it could not: the flock was still held.
  local lingerer
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  bash -c '
    . "$1/scripts/lib/quadlet-lib.sh"
    ql_lock hermes
    sleep 30 &
    printf "%s" "$!" >"$2"
  ' _ "$REPO" "$T/lingerer.pid" || die_t "the first run could not take the lock"
  lingerer=$(cat "$T/lingerer.pid")
  kill -0 "$lingerer" 2>/dev/null || die_t "the fixture is wrong: the lingering child is already gone"
  ql_lock hermes
  eq "$(head -n1 "$(_ql_state_dir hermes)/lock.d/owner")" "$(_ql_owner_record)" \
    "the owner record after the rollback took the lock"
  kill -0 "$lingerer" 2>/dev/null \
    || die_t "the lingering child died first; the test proved nothing"
  kill -9 "$lingerer" 2>/dev/null || true
  return 0
}

t_a_crashed_run_does_not_block_the_lock_for_ever() {
  # The same thing with no chance to tidy up: SIGKILL, so no EXIT trap runs and the lock directory
  # is left behind while a child of the dead run is still alive. Ownership is decided by the owner
  # record, not by the directory, so the next run takes the lock over and says so.
  local lingerer dir err
  dir=$(_ql_state_dir hermes)/lock.d
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  bash -c '
    . "$1/scripts/lib/quadlet-lib.sh"
    ql_lock hermes
    sleep 30 &
    printf "%s" "$!" >"$2"
    kill -9 $$
  ' _ "$REPO" "$T/crashed.pid" || true
  lingerer=$(cat "$T/crashed.pid" 2>/dev/null) || die_t "the fixture never started the lingering child"
  kill -0 "$lingerer" 2>/dev/null || die_t "the fixture is wrong: the lingering child is already gone"
  [[ -d $dir ]] || die_t "the fixture is wrong: the killed run still tidied its own lock away"
  err=$T/takeover.err
  ql_lock hermes 2>"$err" # a ql_die here would end the test, which is exactly the 1.4.0 behaviour
  has "$(cat "$err")" "taking over the lock left behind by pid" "the takeover warning"
  eq "$(head -n1 "$dir/owner")" "$(_ql_owner_record)" "the owner record after the takeover"
  kill -9 "$lingerer" 2>/dev/null || true
  return 0
}

t_a_second_live_run_is_still_refused() {
  # Dropping app_unlocked must not turn the lock into a no-op. While the owner is ALIVE the lock
  # is still exclusive and a second run dies, rather than cutting over on top of the first.
  local holder dir n=0
  dir=$(_ql_state_dir hermes)/lock.d
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  bash -c '. "$1/scripts/lib/quadlet-lib.sh"; ql_lock hermes; sleep 30' _ "$REPO" &
  holder=$!
  while ((n++ < 200)) && [[ ! -s $dir/owner ]]; do sleep 0.05; done
  [[ -s $dir/owner ]] || { kill -9 "$holder" 2>/dev/null; die_t "the holder never took the lock"; }
  # a fresh process with no QL_LOCK_HELD to inherit: it must be refused outright
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  expect_fail env -u QL_LOCK_HELD bash -c '. "$1/scripts/lib/quadlet-lib.sh"; ql_lock hermes' _ "$REPO"
  has "$OUT" "another install/upgrade/uninstall of hermes is running"
  kill -9 "$holder" 2>/dev/null || true
  return 0
}

t_a_child_script_reuses_the_lock_its_caller_holds() {
  # 1.5.0 exports QL_LOCK_HELD, so a wrapper can hold the lock and still call install.sh: the
  # nested ql_lock keeps the caller's lock instead of dying on it. That is the library contract
  # which replaces every local "skip ql_lock when the wrapper already holds it" hack.
  ql_lock hermes
  [[ -n ${QL_LOCK_HELD:-} ]] || die_t "ql_lock did not publish QL_LOCK_HELD for child scripts"
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  expect_ok bash -c '. "$1/scripts/lib/quadlet-lib.sh"; ql_lock hermes' _ "$REPO"
  has "$OUT" "keeping the lock held by the calling script"
  [[ -d $(_ql_state_dir hermes)/lock.d ]] || die_t "the child released the lock its caller holds"
  return 0
}

t_no_1_4_0_lock_workaround_survives_in_the_scripts() {
  # app_unlocked closed a descriptor 1.5.0 never opens, and WOOW_QL_LOCK_HELD skipped a nested
  # ql_lock the library now resolves itself - and would silently stop install.sh locking at all
  # whenever that variable is stale in the environment. Neither may come back.
  local hit
  hit=$(grep -rnE 'app_unlocked|QL_LOCK_FD|WOOW_QL_LOCK_HELD' "$REPO/scripts" --include='*.sh' \
    | grep -v '/lib/quadlet-lib\.sh:') || true
  [[ -z $hit ]] || die_t "a quadlet-lib 1.4.0 lock workaround is back:"$'\n'"$hit"
  return 0
}

# ---- the script really goes through these helpers ------------------------------------------
t_migrate_legacy_asks_the_host_instead_of_refusing() {
  local code fn
  code=$(grep -vE '^[[:space:]]*#' "$REPO/scripts/migrate-legacy.sh")
  grep -q 'is-enabled podman-restart.service' <<<"$code" \
    && die_t "scripts/migrate-legacy.sh still refuses on podman-restart.service by itself"
  for fn in ql_rollback_strategy app_legacy_capture app_legacy_retire app_legacy_restore app_volume_identity; do
    grep -q "$fn" <<<"$code" || die_t "scripts/migrate-legacy.sh never calls $fn"
  done
  return 0
}

t_the_capture_and_the_image_build_happen_before_any_downtime() {
  # Both are prepare-phase work: a container the library cannot replay, and a build that fails, must
  # be discovered while the legacy stack is still serving.
  local cap build stop
  # shellcheck disable=SC2016 # literal call-site text, not an expansion
  cap=$(grep -n 'app_legacy_capture "\$bk"' "$REPO/scripts/migrate-legacy.sh" | head -n1 | cut -d: -f1)
  build=$(grep -n 'build-image.sh' "$REPO/scripts/migrate-legacy.sh" | head -n1 | cut -d: -f1)
  stop=$(grep -n 'podman stop' "$REPO/scripts/migrate-legacy.sh" | head -n1 | cut -d: -f1)
  [[ -n $cap && -n $build && -n $stop ]] || die_t "could not find the capture ($cap), the build ($build) or the stop ($stop)"
  ((cap < stop)) || die_t "the capture (line $cap) is taken after the stop (line $stop): that is downtime spent on a check"
  ((build < stop)) || die_t "the image build (line $build) runs after the stop (line $stop): that is downtime spent on a build"
}

# ---- the compose name collision, handled deliberately ---------------------------------------
t_the_quadlet_network_is_not_the_compose_one() {
  # hermes' compose project is literally called "podman" (the compose file lives in deploy/podman/),
  # so its network is podman_default. Adopting that name would make scripts/uninstall.sh --purge
  # delete the legacy stack's network, and every "remove the stray podman_default" cleanup a
  # rollback-killer.
  local name
  name=$(sed -n 's/^NetworkName=//p' "$REPO/quadlet/hermes.network")
  eq "$name" hermes "quadlet/hermes.network"
  [[ $name != podman_default ]] || die_t "the repo adopted the compose network name"
  grep -q 'podman_default' "$REPO/quadlet/hermes.network" \
    || die_t "quadlet/hermes.network no longer warns that podman_default belongs to this stack"
}

t_the_migration_never_removes_the_compose_network() {
  local code
  code=$(grep -vE '^[[:space:]]*#|ql_(info|warn|die) ' "$REPO/scripts/migrate-legacy.sh")
  grep -qE 'network (rm|prune)' <<<"$code" && die_t "the migration removes a network"
  grep -q 'uninstall.sh' <<<"$code" && die_t "the migration calls uninstall.sh, which with --purge would remove the network"
  # shellcheck disable=SC2016 # literal call-site text, not an expansion
  local plain='ql_uninstall_units "\$APP"$'
  grep -qE "$plain" <<<"$code" \
    || die_t "the rollback must call ql_uninstall_units without --purge, so the volumes and networks survive"
  return 0
}

# ---- the volume units are what makes adoption possible ---------------------------------------
t_the_volume_units_render_their_names_from_the_env() {
  local f key
  for f in hermes-data:WOOW_HERMES_DATA_VOLUME hermes-postgres-data:WOOW_HERMES_POSTGRES_VOLUME \
           hermes-redis-data:WOOW_HERMES_REDIS_VOLUME; do
    key=${f#*:}
    grep -qx "VolumeName=@@$key@@" "$REPO/quadlet/${f%%:*}.volume" \
      || die_t "quadlet/${f%%:*}.volume does not render VolumeName from $key"
    grep -qx "$key" "$REPO/quadlet/render-vars" || die_t "$key is not in quadlet/render-vars"
    grep -q "^$key=" "$REPO/config/hermes.env.example" || die_t "$key has no default in config/hermes.env.example"
  done
  # and the migration points all three at the compose-era names
  for key in podman_hermes-data podman_postgres-data podman_redis-data; do
    grep -q "$key" "$REPO/scripts/migrate-legacy.sh" || die_t "the migration does not adopt $key"
  done
  return 0
}

# ---- the adopted /opt/data already carries the compose-era config policy --------------------
t_the_migration_stamps_the_config_policy_before_the_new_agent_starts() {
  # woow-provision applies the WOOWTECH config policy (a sed over config.yaml) unless
  # /opt/data/.woow-policy-v1 exists. The compose deploy.sh already ran that policy on this very
  # volume and the dashboard may have changed settings since, so the migration stamps it. The stamp
  # must be written while the volume is idle - after the stop, before install.sh.
  local code stamp install_line stop needle
  code=$(grep -vE '^[[:space:]]*#|ql_(info|warn|die) ' "$REPO/scripts/migrate-legacy.sh")
  grep -q 'stamp_config_policy' <<<"$code" || die_t "the migration never stamps .woow-policy-v1"
  grep -q 'woow-policy-v1' "$REPO/container/rootfs/usr/local/bin/woow-provision" \
    || die_t "woow-provision no longer uses the stamp the migration writes"
  stamp=$(grep -n '^  stamp_config_policy ||' "$REPO/scripts/migrate-legacy.sh" | head -n1 | cut -d: -f1)
  stop=$(grep -n 'podman stop' "$REPO/scripts/migrate-legacy.sh" | head -n1 | cut -d: -f1)
  # shellcheck disable=SC2016 # literal call-site text, not an expansion
  needle='^"\$REPO/scripts/install\.sh" --accept-defaults'
  install_line=$(grep -nE "$needle" "$REPO/scripts/migrate-legacy.sh" | head -n1 | cut -d: -f1)
  [[ -n $stamp && -n $stop && -n $install_line ]] || die_t "could not find the stamp ($stamp), the stop ($stop) or the install ($install_line)"
  ((stop < stamp && stamp < install_line)) \
    || die_t "the stamp (line $stamp) must sit between the stop (line $stop) and the install (line $install_line)"
}

# ---- a same-named container that is not ours ------------------------------------------------
t_a_container_from_another_compose_project_is_refused() {
  # The migration retires containers by name, so a hermes-agent belonging to something else must
  # stop the run rather than be captured, renamed and replaced.
  mk_hermes hermes-agent unless-stopped
  set_project hermes-agent someone_elses_project
  expect_fail app_check_not_foreign hermes-agent podman
  has "$OUT" "someone_elses_project"
  expect_ok app_check_not_foreign hermes-agent someone_elses_project
}

t_a_container_with_no_compose_label_is_warned_about_not_refused() {
  mk_hermes hermes-agent unless-stopped
  set_project hermes-agent ""
  expect_ok app_check_not_foreign hermes-agent podman
  has "$OUT" "no compose project label"
}

t_the_compose_project_really_is_called_podman() {
  # Not a typo: the compose file lives in deploy/podman/, so podman-compose named the project after
  # that directory. Anything that "corrects" this to hermes stops the migration from recognising
  # the containers it is supposed to retire.
  mk_hermes hermes-agent unless-stopped
  eq "$(cat "$SHIM_STATE/containers/hermes-agent/project")" podman "the fixture's project label"
  grep -q '^LEGACY_PROJECT=podman$' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "LEGACY_PROJECT is not 'podman'"
  local code
  code=$(grep -vE '^[[:space:]]*#|ql_(info|warn|die) ' "$REPO/scripts/migrate-legacy.sh")
  grep -q 'app_check_not_foreign' <<<"$code" || die_t "the migration never checks the compose project label"
  return 0
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run" "$T/bk" "$T/vols"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run USER=tester TMPDIR=$T
    export PATH="$SHIMS:$PATH" QL_POLL_INTERVAL=0.05 QL_LOG_PREFIX=rollback-model
    unset QL_DRY_RUN QL_STATE_ROOT QL_QUADLET_DIR QL_CONFIG_ROOT
    : >"$SHIM_STATE/calls"
    [[ $(command -v podman) == "$SHIMS/podman" && $(command -v systemctl) == "$SHIMS/systemctl" ]] \
      || die_t "the shims are not first on PATH; refusing to run"
    # shellcheck source=../scripts/lib/quadlet-lib.sh
    . "$REPO/scripts/lib/quadlet-lib.sh"
    # shellcheck source=../scripts/common.sh
    . "$REPO/scripts/common.sh"
    # shellcheck source=../scripts/legacy-common.sh
    . "$REPO/scripts/legacy-common.sh"
    "$t"
  ) >"$log" 2>&1
  rc=$?
  if ((rc == 0)); then
    npass=$((npass + 1))
    printf 'ok    %s\n' "$t"
  else
    nfail=$((nfail + 1))
    FAILED+=("$t")
    printf 'FAIL  %s\n' "$t"
    tail -n 25 "$log" | sed 's/^/      | /'
  fi
}

for t in $(declare -F | sed -n 's/^declare -f \(t_.*\)$/\1/p'); do run "$t"; done
printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
