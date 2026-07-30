# Changelog

All notable changes to the WoowTech Hermes Agent deployment package.

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
