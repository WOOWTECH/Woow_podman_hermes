#!/usr/bin/env bash
# scripts/backup.sh: back up the Hermes agent state and the parity database.
#
#   scripts/backup.sh [--hot]
#
#   --hot   do not stop the agent first. Faster, but the SQLite databases in the volume (state.db,
#           kanban.db, response_store.db, projects.db) may be mid-write, so the copy can be
#           inconsistent. The default stops the agent for the export.
#
# Prints the backup directory on stdout:
#   ~/.local/share/woow-backups/hermes/backup-<timestamp>/
#     hermes-data-<ts>.tar          the agent volume (/opt/data)
#     hermes-postgres.sql           pg_dump of the parity database (custom format)
#     SHA256SUMS
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 077
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

hot=0
while (($#)); do
  case $1 in
    --hot) hot=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"
podman volume exists hermes-data || ql_die "volume hermes-data does not exist"

dest=$(app_new_backup_dir backup)
was_running=$(systemctl --user is-active hermes-agent.service 2>/dev/null || true)
if ((hot == 0)) && [[ $was_running == active ]]; then
  systemctl --user stop hermes-agent.service
  start_again() { systemctl --user start hermes-agent.service || ql_warn "could not start hermes-agent.service again"; }
  # a hook, not `trap ... EXIT`, which would replace the handler ql_lock armed
  ql_cleanup restart start_again
else
  ((hot == 0)) || ql_warn "--hot: the SQLite databases may be mid-write in this copy"
fi
ql_backup_volume hermes-data "$dest" >/dev/null
if [[ $(podman inspect --format '{{.State.Health.Status}}' hermes-postgresql 2>/dev/null) == healthy ]]; then
  podman exec hermes-postgresql pg_dump -U hermes --format=custom hermes >"$dest/hermes-postgres.sql" \
    || ql_warn "pg_dump failed; the archive has no database dump"
  [[ -s $dest/hermes-postgres.sql ]] || rm -f "$dest/hermes-postgres.sql"
else
  ql_warn "hermes-postgresql is not healthy; the archive has no database dump"
fi
printf '%s\n' "$HERMES_IMAGE_TAG" >"$dest/IMAGE_TAG"
if ((hot == 0)) && [[ $was_running == active ]]; then
  ql_cleanup_clear restart
  start_again
  app_wait_healthy hermes-agent 420 hermes-agent.service
fi
app_checksums "$dest"
ql_info "backup complete: $dest"
printf '%s\n' "$dest"
