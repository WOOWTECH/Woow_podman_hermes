#!/usr/bin/env bash
# tests/install-flags.sh: the install flags scripts/upgrade.sh passes on, the provider-key check, and
# the env-file warning for keys a --set adds in the same run.
#
#   tests/install-flags.sh [name-filter]
#
# - scripts/upgrade.sh --no-llm / --set / --rebuild reach scripts/install.sh. Before 0.23.0 upgrade.sh
#   took only --no-backup, so a host whose provider lives in the dashboard (no key in hermes.env)
#   could install with --no-llm but never upgrade.
# - hermes_check_env accepts any provider key hermes.env carries (MiniMax, OpenRouter, LiteLLM), and
#   its error names --no-llm and the dashboard alternative.
# - install.sh --set KEY=... on an env file that lacks KEY does not warn that the file lacks KEY
#   (ported from Woow_podman_opendesign 4.2.1); a key that is still missing is still reported.
# - scripts/omnigent.sh pair refuses without the consent flag, and the password never is an argument.
#
# podman and systemctl are the doubles in tests/shims, first on PATH; every test gets its own HOME,
# shim state and copy of the repo. No container is created and the real user manager is never touched.
#
# Each test runs in its own subshell on purpose:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hermes-install-flags.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }

# repo_copy: a copy of the checkout whose install.sh, backup.sh and smoke.sh only record their
# arguments, so upgrade.sh runs for real around them.
repo_copy() {
  local r=$T/repo f
  mkdir -p "$r"
  (cd "$REPO" && tar --exclude=.git -cf - .) | (cd "$r" && tar -xf -)
  for f in scripts/install.sh scripts/backup.sh tests/smoke.sh; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >>"%s/recorded"\n%s\n' \
      "$f" "$T" "$([[ $f == scripts/backup.sh ]] && echo 'echo /dev/null/backup' || echo 'exit 0')" >"$r/$f"
    chmod +x "$r/$f"
  done
}
env_file() { # env_file: the example as an installed hermes.env, mode 0600
  mkdir -p "$HOME/.config/hermes" && chmod 700 "$HOME/.config/hermes"
  install -m 600 "$REPO/config/hermes.env.example" "$HOME/.config/hermes/hermes.env"
}
recorded() { grep -F "$1" "$T/recorded" || true; }

# ---- upgrade.sh passes the install flags on ------------------------------------------------------
t_upgrade_passes_no_llm_set_and_rebuild_to_install() {
  repo_copy && env_file
  local out
  out=$("$T/repo/scripts/upgrade.sh" --no-backup --no-llm --set WOOW_HERMES_MEMORY=4g --set=WOOW_HERMES_CPUS=2 --rebuild 2>&1) \
    || die_t "upgrade.sh failed: $out"
  [[ $(recorded scripts/install.sh) == 'scripts/install.sh --no-smoke --no-llm --set WOOW_HERMES_MEMORY=4g --set WOOW_HERMES_CPUS=2 --rebuild' ]] \
    || die_t "install.sh got: $(recorded scripts/install.sh)"
  has "$(recorded tests/smoke.sh)" 'tests/smoke.sh'
  has "$out" 'upgrade complete'
}

t_upgrade_without_flags_still_passes_only_no_smoke() {
  repo_copy && env_file
  "$T/repo/scripts/upgrade.sh" --no-backup >/dev/null 2>&1 || die_t "upgrade.sh failed"
  [[ $(recorded scripts/install.sh) == 'scripts/install.sh --no-smoke' ]] || die_t "install.sh got: $(recorded scripts/install.sh)"
}

t_upgrade_backs_up_before_install() {
  repo_copy && env_file
  "$T/repo/scripts/upgrade.sh" --no-llm >/dev/null 2>&1 || die_t "upgrade.sh failed"
  [[ $(head -n1 "$T/recorded") == 'scripts/backup.sh '* ]] || die_t "the backup did not run first: $(cat "$T/recorded")"
}

t_upgrade_refuses_an_unknown_option_and_a_bare_set() {
  repo_copy && env_file
  local out
  if out=$("$T/repo/scripts/upgrade.sh" --no-backup --accept-defaults 2>&1); then die_t "an unknown option was accepted"; fi
  has "$out" 'unknown option --accept-defaults'
  if out=$("$T/repo/scripts/upgrade.sh" --no-backup --set 2>&1); then die_t "--set without a value was accepted"; fi
  has "$out" '--set needs KEY=VALUE'
  [[ ! -e $T/recorded ]] || ! grep -q 'scripts/install.sh' "$T/recorded" || die_t "install.sh ran after a refused option"
}

# ---- the provider-key check ----------------------------------------------------------------------
check_env_with() { # check_env_with <no_llm> [KEY=VALUE...]: hermes_check_env on the example plus these lines
  local no_llm=$1 f=$T/check.env
  shift
  cp "$REPO/config/hermes.env.example" "$f"
  local kv
  for kv in "$@"; do sed -i "s|^${kv%%=*}=.*|$kv|" "$f"; done
  ( QL_ENV_MODE_CHECK=0 ql_env_load "$f" && hermes_check_env "$no_llm" ) 2>&1
}

t_a_litellm_key_alone_is_enough() {
  check_env_with 0 LITELLM_API_KEY=sk-dummy-value >/dev/null || die_t "a LiteLLM key alone was refused: $(check_env_with 0 LITELLM_API_KEY=sk-dummy-value)"
}

t_an_openrouter_key_alone_is_enough() {
  check_env_with 0 OPENROUTER_API_KEY=sk-or-dummy-value >/dev/null || die_t "an OpenRouter key alone was refused"
}

t_no_key_names_no_llm_and_the_dashboard() {
  local out
  if out=$(check_env_with 0); then die_t "no provider key was accepted"; fi
  has "$out" '--no-llm'
  has "$out" 'dashboard'
  has "$out" 'LITELLM_API_KEY'
}

t_no_llm_needs_no_key() {
  check_env_with 1 >/dev/null || die_t "--no-llm still wanted a key: $(check_env_with 1)"
}

t_the_litellm_key_is_an_allowed_credential_and_is_merged_into_dotenv() {
  local f=$T/cred.env
  cp "$REPO/config/hermes.env.example" "$f"
  sed -i 's|^LITELLM_API_KEY=.*|LITELLM_API_KEY=sk-dummy-value|' "$f"
  ( QL_ENV_MODE_CHECK=0 ql_env_load "$f" && app_refuse_env_secrets ) >/dev/null 2>&1 || die_t "app_refuse_env_secrets refused LITELLM_API_KEY"
  grep -qE '^for key in .*\bLITELLM_API_KEY\b.*; do$' "$REPO/container/rootfs/etc/cont-init.d/03-woow-dotenv" \
    || die_t "03-woow-dotenv does not copy LITELLM_API_KEY into /opt/data/.env"
}

# ---- install.sh --set and the "lacks keys" warning -------------------------------------------------
# install_with_sets: install.sh for real on the shims, on an env file without WOOW_HERMES_MEMORY and
# WOOW_HERMES_BUILD_CPUS, with --set WOOW_HERMES_MEMORY=4g.
install_with_sets() {
  env_file
  sed -i '/^WOOW_HERMES_MEMORY=/d; /^WOOW_HERMES_BUILD_CPUS=/d' "$HOME/.config/hermes/hermes.env"
  mkdir -p "$T/linger" && : >"$T/linger/$USER"
  QL_LINGER_DIR=$T/linger SHIM_IMAGES_ALL=1 SHIM_DEFAULT_HEALTHY=1 \
    "$REPO/scripts/install.sh" --no-build --no-start --no-llm --set WOOW_HERMES_MEMORY=4g 2>&1
}

t_install_set_does_not_report_the_key_it_adds() {
  local out
  out=$(install_with_sets) || die_t "install.sh failed: $out"
  has "$out" 'set WOOW_HERMES_MEMORY in'
  has "$out" 'lacks keys' "a still-missing key must still be reported"
  local line
  line=$(grep -F 'lacks keys' <<<"$out")
  hasnt "$line" 'WOOW_HERMES_MEMORY' "the warning"
  has "$line" 'WOOW_HERMES_BUILD_CPUS' "the warning"
  grep -qx 'WOOW_HERMES_MEMORY=4g' "$HOME/.config/hermes/hermes.env" || die_t "the --set value was not stored"
  has "$out" 'installed; not started'
}

t_install_set_is_applied_once() {
  local out
  out=$(install_with_sets) || die_t "install.sh failed: $out"
  [[ $(grep -c 'set WOOW_HERMES_MEMORY in' <<<"$out") == 1 ]] || die_t "the --set was applied more than once:"$'\n'"$out"
}

# ---- scripts/omnigent.sh ------------------------------------------------------------------------
# fake_podman: a podman that records its argv and stdin and says the container runs the plugin.
fake_podman() {
  mkdir -p "$T/bin"
  cat >"$T/bin/podman" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/argv"
case \$1 in
  inspect) echo true ;;
  exec) [[ " \$* " != *' -i '* ]] || cat >>"$T/stdin" ;;
esac
exit 0
EOF
  chmod +x "$T/bin/podman"
  export PATH="$T/bin:$PATH"
}

t_omnigent_pair_needs_the_explicit_consent_and_a_safe_url() {
  fake_podman
  local o=$REPO/scripts/omnigent.sh out
  if out=$("$o" pair --server https://o.example.com --user u </dev/null 2>&1); then die_t "pair without consent ran"; fi
  has "$out" '--allow-direct-hermes'
  if out=$("$o" pair --server http://o.example.com --user u --allow-direct-hermes --yes </dev/null 2>&1); then die_t "a remote http server was accepted"; fi
  has "$out" 'https://'
  if out=$("$o" pair --server https://o.example.com --user u --allow-direct-hermes </dev/null 2>&1); then die_t "pair ran with no terminal and no --yes"; fi
  has "$out" 'shell in the container' "the warning"
  [[ ! -e $T/stdin ]] || die_t "something reached the container after a refusal"
}

t_omnigent_password_travels_on_stdin_only() {
  fake_podman
  local out marker=not-a-real-pass-value
  out=$(printf '%s\n' "$marker" | "$REPO/scripts/omnigent.sh" pair --server https://o.example.com --user u --allow-direct-hermes --yes --password-stdin 2>&1) \
    || die_t "pair failed: $out"
  grep -qxF "$marker" "$T/stdin" || die_t "the password did not reach the plugin on stdin"
  ! grep -qF "$marker" "$T/argv" || die_t "the password is in podman's arguments"
  hasnt "$out" "$marker"
  has "$(cat "$T/argv")" 'exec -i -u hermes'
  has "$(cat "$T/argv")" 'allowDirectHermes=True'
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
    export PATH="$SHIMS:$PATH" QL_POLL_INTERVAL=0.05 QL_LOG_PREFIX=install-flags
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
