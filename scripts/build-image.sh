#!/usr/bin/env bash
# scripts/build-image.sh: build the Hermes agent image from container/Containerfile.
#
#   scripts/build-image.sh [--target slim|full] [--force]
#
#   --target   slim (default) is the upstream base plus exactly what the old deploy.sh did to the
#              running container: tmux, the hermes CLI symlink, the skill trims, ddgs, OfficeCLI, the
#              MCP OAuth iss patches, the superpowers seed and the TUI ownership fix. full adds the
#              old 7-layer toolchain, which the podman deployment never actually ran.
#   --force    rebuild even when the tag exists; the previous image is kept as <tag>-prev
#
# The build fails loudly where deploy.sh used to fail silently: a moved patch anchor, a changed
# download or a missing tool ends the build instead of shipping an unpatched image.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

target='' force=0
while (($#)); do
  case $1 in
    --target) (($# >= 2)) || ql_die "--target needs slim or full"; target=$2; shift ;;
    --force) force=1 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
if [[ -z $target ]]; then
  if [[ -f $ENV_FILE ]]; then ql_env_load; target=$(ql_env_get WOOW_HERMES_IMAGE_TARGET slim); else target=slim; fi
fi
ql_assert_match WOOW_HERMES_IMAGE_TARGET "$target" 'slim|full'

if podman image exists "$HERMES_IMAGE"; then
  if ((force == 0)); then
    ql_info "$HERMES_IMAGE is already present (use --force to rebuild)"
    exit 0
  fi
  podman tag "$HERMES_IMAGE" "$HERMES_IMAGE-prev" && ql_info "kept the previous image as $HERMES_IMAGE-prev"
fi
cpus=''
[[ -f $ENV_FILE ]] && cpus=$(ql_env_get WOOW_HERMES_BUILD_CPUS '')
args=()
[[ -z $cpus ]] || args+=(--cpuset-cpus "$cpus")
ql_info "building $HERMES_IMAGE (target $target) from the pinned base; this takes 5-15 minutes"
nice -n 10 podman build --format=docker --target "$target" "${args[@]}" \
  --build-arg "HERMES_BASE=$HERMES_BASE" \
  --build-arg "WOOW_IMAGE_VERSION=$HERMES_IMAGE_TAG" \
  -t "$HERMES_IMAGE" -f "$REPO/container/Containerfile" "$REPO/container" \
  || ql_die "podman build failed; nothing was changed"
ql_info "built $HERMES_IMAGE"
