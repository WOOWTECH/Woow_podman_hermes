#!/usr/bin/env bash
# tests/resource-recreate.sh: a network or volume removed behind systemd's back is recreated by
# scripts/install.sh (and so by scripts/upgrade.sh, which runs it).
#
#   tests/resource-recreate.sh [name-filter]
#
# Found on the 0.21.0 deploy: the user's podman objects were removed externally (a
# `podman system reset`-like event). hermes-network.service is a RemainAfterExit oneshot, so it
# stayed "active (exited)"; install.sh restarts only units whose files changed, did not recreate
# the `hermes` network, and hermes-postgres / hermes-redis failed with "unable to find network with
# name or ID hermes". hermes_ensure_resources (scripts/hermes-helpers.sh) marks such a unit and the
# three containers for restart before ql_apply_units runs.
#
# podman and systemctl are the doubles in tests/shims, first on PATH; every test gets its own HOME
# and shim state. No container is created and the real user manager is never touched.
#
# Each test runs in its own subshell on purpose:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hermes-resource-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
restarts() { grep -E '^systemctl --user restart ' "$SHIM_STATE/calls" || true; }

UNITS=(hermes-network.service hermes-data-volume.service hermes-postgres-data-volume.service
  hermes-redis-data-volume.service hermes-postgres.service hermes-redis.service hermes-agent.service)
VOLUMES=(hermes-data hermes-postgres-data hermes-redis-data)

# installed <state>: the stack as install.sh left it - the rendered units installed and recorded in
# the manifest, every unit <state>, the network and the three volumes present.
installed() {
  local u v
  local -a RENDER_ARGS=()
  mkdir -p "$T/src" "$T/out"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$T/src/"
  QL_ENV_MODE_CHECK=0 ql_env_load "$REPO/config/hermes.env.example"
  render_args "$REPO/config/hermes.env.example"
  ql_render "$T/src" "$REPO/config/hermes.env.example" "$REPO/quadlet/render-vars" "$T/out" "${RENDER_ARGS[@]}"
  ql_install_files "$T/out" "$APP" --prune >/dev/null
  rm -f "$(app_state_dir)/pending-restart"
  for u in "${UNITS[@]}"; do mkdir -p "$SHIM_STATE/units/$u" && echo "$1" >"$SHIM_STATE/units/$u/active"; done
  mkdir -p "$SHIM_STATE/networks" && : >"$SHIM_STATE/networks/hermes"
  for v in "${VOLUMES[@]}"; do mkdir -p "$SHIM_STATE/volumes/$v"; done
  : >"$SHIM_STATE/calls"
}
# what install.sh step 6 runs, in its order
apply() {
  hermes_ensure_resources "$T/out"
  ql_apply_units "$APP" hermes-postgres.service hermes-redis.service
  ql_apply_units "$APP" hermes-agent.service
}

# ---- the bug ------------------------------------------------------------------------------------
t_without_the_fix_the_stale_network_unit_is_left_alone() {
  # The negative control: the library alone sees nothing to do, which is exactly what happened.
  installed active
  rm -f "$SHIM_STATE/networks/hermes"
  ql_apply_units "$APP" hermes-postgres.service hermes-redis.service >/dev/null 2>&1
  [[ -z $(restarts) ]] || die_t "ql_apply_units alone restarted something; the reproduction is stale:"$'\n'"$(restarts)"
}

t_a_removed_network_is_recreated_and_the_containers_restarted() {
  installed active
  rm -f "$SHIM_STATE/networks/hermes"
  local out r
  out=$(apply 2>&1) || die_t "apply failed: $out"
  has "$out" "podman network hermes is gone although hermes-network.service is active"
  r=$(restarts)
  has "$r" hermes-network.service "restarts"
  has "$r" hermes-postgres.service "restarts"
  has "$r" hermes-redis.service "restarts"
  has "$r" hermes-agent.service "restarts"
  hasnt "$r" hermes-data-volume.service "restarts (the volumes are there)"
  # the network unit is restarted in the first call, before (or with) the containers that need it
  head -n1 <<<"$r" | grep -q hermes-network.service || die_t "the network is not in the first restart: $r"
  [[ ! -s $(app_state_dir)/pending-restart ]] || die_t "units left pending: $(cat "$(app_state_dir)/pending-restart")"
}

t_a_removed_volume_is_recreated_with_a_loud_warning() {
  installed active
  rm -rf "$SHIM_STATE/volumes/hermes-redis-data"
  local out r
  out=$(apply 2>&1) || die_t "apply failed: $out"
  has "$out" "podman volume hermes-redis-data is gone"
  has "$out" "recreated EMPTY"
  r=$(restarts)
  has "$r" hermes-redis-data-volume.service "restarts"
  has "$r" hermes-redis.service "restarts"
  hasnt "$r" hermes-network.service "restarts (the network is there)"
}

t_after_a_full_reset_everything_comes_back() {
  installed active
  rm -rf "$SHIM_STATE/networks/hermes" "$SHIM_STATE/volumes"/*
  local r
  apply >/dev/null 2>&1 || die_t "apply failed"
  r=$(restarts)
  for u in "${UNITS[@]}"; do has "$r" "$u" "restarts"; done
}

# ---- and nothing else changes -------------------------------------------------------------------
t_a_healthy_stack_restarts_nothing() {
  installed active
  local out
  out=$(apply 2>&1) || die_t "apply failed: $out"
  [[ -z $(restarts) ]] || die_t "a healthy stack was restarted: $(restarts)"
  hasnt "$out" "is gone"
}

t_a_fresh_install_is_not_reported() {
  # Nothing exists yet and no unit is active: starting the containers creates the objects.
  installed inactive
  rm -rf "$SHIM_STATE/networks/hermes" "$SHIM_STATE/volumes"/*
  local out
  out=$(hermes_ensure_resources "$T/out" 2>&1) || die_t "failed: $out"
  hasnt "$out" "is gone"
  [[ ! -s $(app_state_dir)/pending-restart ]] || die_t "a fresh install marked units: $(cat "$(app_state_dir)/pending-restart")"
}

t_a_dry_run_reports_and_marks_nothing() {
  installed active
  rm -f "$SHIM_STATE/networks/hermes"
  local out
  out=$(QL_DRY_RUN=1 hermes_ensure_resources "$T/out" 2>&1) || die_t "failed: $out"
  has "$out" "[dry-run] would restart hermes-network.service"
  [[ ! -s $(app_state_dir)/pending-restart ]] || die_t "a dry run marked units"
}

t_install_runs_the_check_before_any_unit_is_applied() {
  local check first dry
  # shellcheck disable=SC2016 # the literal call-site text
  check=$(grep -n '^hermes_ensure_resources "\$WORK/out"$' "$REPO/scripts/install.sh" | cut -d: -f1)
  first=$(grep -n '^ql_apply_units ' "$REPO/scripts/install.sh" | head -n1 | cut -d: -f1)
  dry=$(grep -n 'dry-run complete' "$REPO/scripts/install.sh" | cut -d: -f1)
  [[ -n $check && -n $first && -n $dry ]] || die_t "cannot find the call ($check), the first apply ($first) or the dry-run exit ($dry)"
  ((check < dry && dry < first)) || die_t "hermes_ensure_resources (line $check) must run before the dry-run exit ($dry) and the first ql_apply_units ($first)"
  grep -q 'scripts/install.sh" --no-smoke' "$REPO/scripts/upgrade.sh" || die_t "upgrade.sh no longer goes through install.sh"
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run USER=tester TMPDIR=$T
    export PATH="$SHIMS:$PATH" QL_POLL_INTERVAL=0.05 QL_LOG_PREFIX=resource-recreate
    unset QL_DRY_RUN QL_STATE_ROOT QL_QUADLET_DIR QL_CONFIG_ROOT
    : >"$SHIM_STATE/calls"
    [[ $(command -v podman) == "$SHIMS/podman" && $(command -v systemctl) == "$SHIMS/systemctl" ]] \
      || die_t "the shims are not first on PATH; refusing to run"
    # shellcheck source=../scripts/lib/quadlet-lib.sh
    . "$REPO/scripts/lib/quadlet-lib.sh"
    # shellcheck source=../scripts/common.sh
    . "$REPO/scripts/common.sh"
    # shellcheck source=../scripts/hermes-helpers.sh
    . "$REPO/scripts/hermes-helpers.sh"
    # shellcheck source=../scripts/render-args.sh
    . "$REPO/scripts/render-args.sh"
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
