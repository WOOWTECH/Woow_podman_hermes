# Changelog

All notable changes to the WoowTech Hermes Agent deployment package.

## [0.20.0-quadlet] - 2026-09-12 (BREAKING)

Quadlet + systemd is now the only deployment in this repo, and the image is immutable.

### Added
- **Quadlet units** (`quadlet/`) for rootless podman 4.9+: `hermes-agent`, `hermes-postgres`,
  `hermes-redis`, the `hermes` network and the three volumes. They start at boot through linger and
  are restarted when a container crashes. The compose stack had no boot recovery on rootless podman.
- **`container/Containerfile`** with a `slim` (default) and a `full` target. Everything the old
  `deploy/podman/deploy.sh` did to the *running* container — tmux, the `hermes` CLI symlink, the
  skill trims, `ddgs`, OfficeCLI, the two MCP OAuth `iss` patches, the superpowers skills seed, the
  TUI ownership fix — is now a build step that **fails the build** when an anchor moves or a download
  changes. `Pull=never`; `scripts/build-image.sh` builds it under `nice` and `--cpuset-cpus`.
- **In-image provisioning:** `cont-init.d/020-woow-provision` at boot (re-syncs the TUI and
  `/opt/data/.env` when the image version changes) and `systemd/hermes-provision.service` after the
  gateway is healthy (applies the config policy once, behind a stamp, then fixes the model routes).
- **Generated credentials in podman secrets:** `hermes-api-server-key`, `hermes-webhook-secret`,
  `hermes-dashboard-password` (type=env) and `hermes-postgres-password` (type=mount, read through
  `POSTGRES_PASSWORD_FILE`). `scripts/install.sh --rotate-secrets` rotates the first three.
- **Scripts:** `install.sh`, `upgrade.sh` (unit snapshot and rollback on failure), `uninstall.sh`
  (`--purge` is the only way to delete data; `--purge-images` as well), `backup.sh` (cold by default,
  `--hot` available), `restore.sh`.
- **Tests and CI:** `tests/dryrun.sh` (Quadlet 4.9.3 dry-run plus `systemd-analyze verify`),
  `tests/smoke.sh`, `tests/lint-repo.sh`, `tests/patch-anchors.sh`, and `.github/workflows/quadlet-ci.yml`.

### Changed (BREAKING)
- **Ports bind `127.0.0.1`** by default: gateway 18642, dashboard 19119, webhook 18644. Set
  `WOOW_HERMES_BIND=all` to go back to every interface. PostgreSQL and Redis publish no host port.
- **The dashboard password is generated.** There is no `admin` / `admin` default any more.
- **Volume names changed** (`podman_hermes-data` → `hermes-data`, and likewise for the database and
  the cache), so migrating is a copy, not an in-place adoption. See the README, "Migrating the
  podman-compose deployment".
- **The upstream base is pinned by digest** at `v2026.8.31` (it was a floating `main` build), and
  PostgreSQL 15.19 / Redis 7.4.11-alpine are pinned by digest too.
- **Settings moved** from `deploy/podman/.env` to `~/.config/hermes/hermes.env` (0600), which holds
  only user-supplied provider keys and the `WOOW_*` installer knobs.

### Removed
- `deploy/podman/` (`podman-compose.yml`, `deploy.sh`, `.env.example`, `README.md`) and `docker/`.
  The last compose version stays on the `compose-final` tag. Kubernetes users have `Woow_k3s_hermes`.
- `config/deploy-and-test.sh` and `config/post-deploy-setup.sh` (k3s-only; they live in
  `Woow_k3s_hermes`), `config/apply-env-fingerprint-patch.py` (it targeted the removed
  `hermes-webui`), and the root `.env.example` (k3s).
- `deploy/podman/SKILL.md` → `docs/odoo-posting.md`; `config/fix-model-routes.py` → `container/`.

### Migration
`scripts/build-image.sh`, stop the compose stack, copy each volume, stamp `.woow-policy-v1`, import
the old `API_SERVER_KEY` / `WEBHOOK_SECRET` / `DASHBOARD_PASSWORD` / `POSTGRES_PASSWORD` into podman
secrets, rename the legacy containers, then `scripts/install.sh`. Full steps are in the README.

## [0.17.0] - 2026-07-30

### BREAKING: single-container architecture

### Removed
- `hermes-webui` service (image `ghcr.io/nesquena/hermes-webui:latest`, port `18787`) from `deploy/podman/podman-compose.yml`
- `WEBUI_PASSWORD` from `deploy/podman/.env.example`
- `deploy/podman/apply_branding.py` + `deploy/podman/icons/` (webui-only branding assets)
- `branding/` (all sub-directories: `apporo/`, `woowtech/`, `template-icons/`) — apply_branding scripts patched WebUI internals; obsolete
- deploy.sh: dropped steps that installed the agent source into WebUI venv, waited for WebUI healthy, patched WebUI branding, and enabled skills via WebUI API

### Changed
- Dashboard TUI (port `19119`) is now the ONLY chat surface — runs in `hermes-agent` container with full CLI tool access (ffmpeg / edge-tts / rclone / playwright / node / hermes)
- Port map is now `19119` (Dashboard) + `18642` (Gateway); `18787` no longer exposed
- README (EN + zh-TW) rewritten to reflect single-container architecture

### Preserved
- `hermes-data` named volume (agent-only mount; nothing lost)
- PostgreSQL data, Redis data

### Migration
From v0.16.x: `podman-compose down && git pull && podman-compose up -d`. `.env` `WEBUI_PASSWORD` line can be deleted. Existing CF tunnel WebUI hostname route (`*-hermes.woowtech.io` → `:18787`) should be removed from the CF dashboard; keep the Dashboard hostname route.

### Rationale
Dashboard TUI (xterm.js REPL of `hermes chat` inside hermes-agent) is a superset of WebUI chat: same LLM + skills + MCP AND full CLI tool access. WebUI had almost no video/CLI tools (base image ships only `python3+pip+curl+officecli`), forcing a container-choice problem for any video-pipeline/CLI-heavy work. Single-container removes the split.

## [0.15.1] - 2026-07-13

### Changed
- Restructured GitHub repo: clean layout with `deploy/`, `config/`, `docker/`, `branding/`, `tests/`
- Added bilingual README (English + Traditional Chinese) with Mermaid architecture diagrams
- Removed OpenClaw content pollution from k3s/podman branches

## [0.15.0] - 2026-07-12

### Fixed
- Model routing: added `@openai-api:*` routes for WebUI model picker compatibility
- Synced model list with WebUI picker (added gpt-5.5-pro, gpt-5.4-nano, removed gpt-5.5-mini)

### Added
- `.env` fingerprint sync patch for K3s/Podman deployments
- Playwright-based E2E test suite (10/10 pass)

## [0.14.0] - 2026-06

### Added
- Multi-instance deployment with `deploy-instance.sh`
- White-label branding system (WoowTech + Apporo templates)
- Golden config/settings templates (`golden-config.yaml`, `golden-settings.json`)
- Cloudflare Tunnel initialization script
- Instance registry (`instances.json`)

## [0.13.0] - 2026-05

### Added
- Custom Docker image with 47 CLI tools + Playwright + Chromium 148
- 7-round enterprise test suite (infrastructure, API, security, resilience, integration, LLM, WebUI)
- API contract documentation (46 verified endpoints)
- Podman compose deployment option
- 907-line Chinese user manual (25 chapters)

## [0.12.0] - 2026-04

### Added
- Initial Hermes Agent deployment on K3s Kubernetes
- Basic deploy.sh for single-instance deployment
- PostgreSQL + Redis stack
