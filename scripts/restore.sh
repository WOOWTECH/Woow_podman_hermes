#!/usr/bin/env bash
# scripts/restore.sh: restore a Hermes backup made by scripts/backup.sh.
#
#   scripts/restore.sh --archive DIR_OR_TAR --confirm-restore hermes
#
# Pass the backup directory (both the agent volume and the database dump are restored) or a single
# hermes-data-*.tar (only the agent volume). The agent is stopped, a pre-restore copy is taken, the
# volume is emptied and re-imported, and the stack is started and smoke-checked again.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 077
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

archive='' confirm=''
while (($#)); do
  case $1 in
    --archive) (($# >= 2)) || ql_die "--archive needs a path"; archive=$2; shift ;;
    --confirm-restore) (($# >= 2)) || ql_die "--confirm-restore needs the word $APP"; confirm=$2; shift ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ -n $archive && $confirm == "$APP" ]] || ql_die "usage: scripts/restore.sh --archive DIR_OR_TAR --confirm-restore $APP"
archive=$(realpath -- "$archive")
ql_require_rootless
app_lock

dump=''
if [[ -d $archive ]]; then
  (cd "$archive" && [[ ! -f SHA256SUMS ]] || sha256sum -c --quiet SHA256SUMS) || ql_die "checksum mismatch in $archive"
  tar=$(find "$archive" -maxdepth 1 -name 'hermes-data-*.tar' | sort | tail -n1)
  [[ -n $tar ]] || ql_die "no hermes-data-*.tar in $archive"
  [[ -f $archive/hermes-postgres.sql ]] && dump=$archive/hermes-postgres.sql
elif [[ -f $archive ]]; then
  tar=$archive
else
  ql_die "not found: $archive"
fi

pre=$(app_new_backup_dir pre-restore)
systemctl --user stop hermes-agent.service || true
ql_backup_volume hermes-data "$pre" >/dev/null
app_checksums "$pre"
ql_info "pre-restore copy of the current data: $pre"
mp=$(podman volume inspect --format '{{.Mountpoint}}' hermes-data)
[[ $mp == /* && $mp != / ]] || ql_die "unexpected mountpoint for hermes-data"
podman unshare find "$mp" -mindepth 1 -delete
podman volume import hermes-data "$tar" || ql_die "podman volume import failed; the previous data is in $pre"
if [[ -n $dump ]]; then
  if [[ $(podman inspect --format '{{.State.Health.Status}}' hermes-postgresql 2>/dev/null) == healthy ]]; then
    podman exec -i hermes-postgresql pg_restore -U hermes --clean --if-exists --exit-on-error --single-transaction -d hermes <"$dump" \
      || ql_die "pg_restore failed; the agent volume was restored, the database was not"
    ql_info "restored the parity database"
  else
    ql_warn "hermes-postgresql is not healthy; skipped the database dump"
  fi
fi
systemctl --user start hermes-agent.service
app_wait_healthy hermes-agent 420 hermes-agent.service
"$REPO/tests/smoke.sh" --quick || ql_die "restored, but the quick smoke check failed"
ql_info "restore complete (previous data kept in $pre)"
