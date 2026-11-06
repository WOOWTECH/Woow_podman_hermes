#!/usr/bin/env bash
# scripts/omnigent.sh: operate the optional Omnigent plugin (WOOWTECH/hermes-omnigent-plugin) of the
# running hermes-agent from the host. The plugin is installed by the user from the dashboard
# (README, "Omnigent"); this script installs nothing.
#
#   scripts/omnigent.sh pair --server URL --user NAME --allow-direct-hermes [--password-stdin] [--yes]
#   scripts/omnigent.sh status | catalog | verify [--model ID] | acceptance [--chat] | disconnect
#
#   pair         a fresh Omnigent login WITH the plugin's "allow Hermes direct execution" consent. On
#                this stack the plugin's pairing panel does not offer that checkbox (its Bubblewrap
#                probe passes in rootless Podman), and Hermes 0.22 Omnigent conversations work only
#                in direct execution (README, "Omnigent"). The password is read from the terminal
#                without echo (or from stdin with --password-stdin) and handed to the plugin on stdin;
#                it is never an argument, never printed and never stored by this script.
#   the others   the plugin's own CLI (python -m hermes_omnigent.cli ...), as the hermes user
#
#   HERMES_AGENT_CONTAINER=NAME   the container to talk to (default hermes-agent)
#
# Every action runs as the hermes service account inside the container (podman exec -u hermes), as
# the plugin requires; nothing is written on the host.
set -euo pipefail
C=${HERMES_AGENT_CONTAINER:-hermes-agent}
PLUGIN=/opt/data/plugins/hermes-omnigent
PY=/opt/hermes/.venv/bin/python

die() { printf 'omnigent: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0"; }

in_plugin() { # in_plugin [podman exec flags...] -- <python args...>
  local -a flags=()
  while (($#)) && [[ $1 != -- ]]; do flags+=("$1"); shift; done
  shift
  podman exec "${flags[@]}" -u hermes -w "$PLUGIN" -e HOME=/opt/data -e HERMES_HOME=/opt/data "$C" "$PY" -I "$@"
}

preflight() {
  podman container exists "$C" || die "container $C does not exist"
  [[ $(podman inspect --format '{{.State.Running}}' "$C") == true ]] || die "container $C is not running"
  podman exec -u hermes "$C" test -f "$PLUGIN/plugin.yaml" \
    || die "the Omnigent plugin is not installed in $C: install WOOWTECH/hermes-omnigent-plugin from the dashboard's Plugins page first (README, Omnigent)"
}

# The plugin's own CLI never takes a password; -I keeps the caller's environment out of sys.path.
CLI='import runpy, sys; sys.path.insert(0, "."); sys.argv[0] = "hermes_omnigent.cli"; runpy.run_module("hermes_omnigent.cli", run_name="__main__")'

# pair: the same runtime call the dashboard's /pair API ends in (runtime.initialize, under the
# runtime lock), with allowDirectHermes=True. Only codes and the verification summary are printed.
PAIR='
import json, sys
sys.path.insert(0, ".")
from hermes_omnigent.runtime import get_runtime
server, user = sys.argv[1], sys.argv[2]
password = sys.stdin.readline().rstrip("\n")
runtime = get_runtime()
try:
    with runtime.lock():
        result = runtime.initialize(server, user, password, allowDirectHermes=True)
except Exception as error:
    result = {"ok": False, "error": getattr(error, "code", "OPERATION_FAILED")}
password = None
keep = ("engine", "ok", "reason", "reply", "model", "url")
summary = {"ok": result.get("ok"), "error": result.get("error"),
           "verification": {name: {k: v.get(k) for k in keep if k in v}
                            for name, v in (result.get("verification") or {}).items() if isinstance(v, dict)}}
print(json.dumps({k: v for k, v in summary.items() if v is not None}, ensure_ascii=False, indent=2))
sys.exit(0 if result.get("ok") else 1)
'

action=${1:-}
[[ -n $action ]] || { usage; exit 2; }
shift
case $action in
  -h | --help) usage; exit 0 ;;
  status | catalog | disconnect)
    (($# == 0)) || die "$action takes no options"
    preflight
    in_plugin -- -c "$CLI" "$action" ;;
  verify)
    model=()
    while (($#)); do
      case $1 in
        --model) (($# >= 2)) || die "--model needs an id"; model=(--model "$2"); shift ;;
        *) die "unknown option $1" ;;
      esac
      shift
    done
    preflight
    in_plugin -- -c "$CLI" verify --engine hermes "${model[@]}" ;;
  acceptance)
    chat=()
    while (($#)); do
      case $1 in
        --chat) chat=(--chat) ;;
        *) die "unknown option $1" ;;
      esac
      shift
    done
    preflight
    in_plugin -- -c "$CLI" acceptance "${chat[@]}" ;;
  pair)
    server='' user='' direct=0 stdin=0 yes=0
    while (($#)); do
      case $1 in
        --server) (($# >= 2)) || die "--server needs a URL"; server=$2; shift ;;
        --user) (($# >= 2)) || die "--user needs a name"; user=$2; shift ;;
        --allow-direct-hermes) direct=1 ;;
        --password-stdin) stdin=1 ;;
        --yes) yes=1 ;;
        *) die "unknown option $1" ;;
      esac
      shift
    done
    [[ -n $server && -n $user ]] || die "pair needs --server URL and --user NAME"
    ((direct)) || die "pair needs --allow-direct-hermes: on this stack Hermes Omnigent conversations work only in direct execution (README, Omnigent). Pair from the dashboard to try the default mode."
    [[ $server =~ ^https:// || $server =~ ^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$) ]] \
      || die "the server must be an https:// URL (http only on loopback)"
    preflight
    if ((yes == 0)); then
      cat >&2 <<'EOF'
Direct execution: Hermes conversations started from this Omnigent server run WITHOUT Bubblewrap, as
the hermes user of this container, with its files (/opt/data: provider keys, config, sessions) and
its network. Every account that can use this host on the Omnigent server gets that access, which is
equivalent to a shell in the container. Use a dedicated, non-admin Omnigent account for this host.
Disconnecting later does not revoke the grant on the server side, and backups of /opt/data include
the Omnigent login token and the host identity.
EOF
      [[ -t 0 ]] || die "not a terminal: pass --yes to confirm non-interactively"
      read -r -p 'Type "direct" to continue: ' answer
      [[ $answer == direct ]] || die "not confirmed; nothing was changed"
    fi
    if ((stdin)); then
      IFS= read -r password || true
    else
      [[ -t 0 ]] || die "not a terminal: use --password-stdin"
      IFS= read -r -s -p "Omnigent password for $user: " password
      printf '\n' >&2
    fi
    [[ -n $password ]] || die "empty password"
    rc=0
    printf '%s\n' "$password" | in_plugin -i -- -c "$PAIR" "$server" "$user" || rc=$?
    password=''
    exit "$rc" ;;
  *) die "unknown action $action (see --help)" ;;
esac
