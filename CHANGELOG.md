# Changelog

All notable changes to the WoowTech Hermes Agent deployment package.

## [Unreleased]

### Changed
- **Omnigent plugin pin** in the READMEs moved from `6c86ebb` to `4f2bec4`. Omnigent sessions now see
  the profile's MCP servers and skills, and slash commands no longer run twice or show a false
  delivery error. The plugin version string is still `0.1.0-rc.16`, so the pin is what tells them apart.
- **Omnigent plugin pin** moved again, from `4f2bec4` to `d5dd277`. `4f2bec4` let a background review in
  an Omnigent session change the profile's skills without a main ledger entry; sessions now run with
  background review off.

## [0.23.1-quadlet] - 2026-11-06

New image tag `v0.22.5-woow4` (`woow-provision` only).

### Fixed
- **`hermes-provision.service` failed when it started with the container**, with "config.yaml missing
  after gateway start" although the file was there. It dropped to the hermes user before stage2 had
  remapped that user to `HERMES_UID`, so the whole run stayed uid 10000 and could not enter
  `/opt/data`. Every restart that hit this window failed the unit, and `upgrade.sh` then rolled back:
  the first real upgrade from `v0.22.5-woow2` to `woow3` failed this way. Present since 0.21.0-quadlet.
  `woow-provision` now waits for a healthy gateway first. A failure during a rollback can still be
  reported until the rolled-back image has this fix.

## [0.23.0-quadlet] - 2026-11-06

Phase 3 of the alignment with the Home Assistant add-on (`Woow_ha_hermes_add_on` @ `d4cde45`): the
optional Omnigent plugin, an OpenAI-compatible gateway (LiteLLM) as a provider with its models listed
in ACP/Paseo, and `upgrade.sh`/`install.sh` fixes. Same upstream base (Hermes v0.22.5); new image tag
`v0.22.5-woow3` (one line in `03-woow-dotenv`).

### Security
- **Omnigent grants shell-equivalent access, and the docs say so first.** README *Omnigent* (both
  languages) carries HA's warnings: every Omnigent server account that can use the host can run Hermes
  as the container's `hermes` user with its files (provider keys, config, sessions, the Omnigent login
  token) and network; pair with a dedicated non-admin account; unlinking does not revoke the grant on
  the server; backups of `hermes-data` include the login token and the host identity.
- **No Podman security option is relaxed for Omnigent.** Measured on this stack: the plugin's
  Bubblewrap probe passes in rootless Podman, but Omnigent's own sandbox (a fresh `/proc` in a new PID
  namespace) fails with `Can't mount proc on /proc` unless `--security-opt unmask=/proc/*` (or
  `unmask=ALL` / `systempaths=unconfined`) unmasks `/proc` for the whole container; `seccomp=unconfined`
  and `label=disable` do not help. Hermes 0.22 Omnigent conversations fail without direct execution
  whether or not Bubblewrap works (`profile_mismatch`), so the unmask buys nothing and is not offered.
  Hermes conversations use the plugin's direct-execution mode with the container as the sandbox
  (rootless, memory/CPU limits, no host mount but `hermes-data`; not a network boundary), as
  Woow_podman_opendesign 4.1.2 does for Codex.
- `scripts/omnigent.sh pair` needs `--allow-direct-hermes` and a typed `direct` (or `--yes`), reads the
  password without echo (or `--password-stdin`) and hands it to the plugin on stdin: never an argument,
  never printed, never stored by the script. Only codes and the verification summary are printed.
- `LITELLM_API_KEY` joins the provider keys allowed in `hermes.env` (`ENV_CREDENTIAL_ALLOW`); like the
  others it cannot be passed with `--set`.

### Added
- **Omnigent, optional** (`WOOWTECH/hermes-omnigent-plugin` `0.1.0-rc.16` @ `6c86ebb`, Omnigent 0.20.0),
  installed by the user from the dashboard as on HA; nothing is bundled. `scripts/omnigent.sh`:
  `pair` (direct execution; the pairing panel does not show that checkbox here because the probe
  passes), and `status`, `catalog`, `verify [--model]`, `acceptance [--chat]`, `disconnect` through the
  plugin's own CLI, all as the `hermes` user inside the container. README: requirements (0.6–0.7 GB,
  egress, tmux 3.5a), install, pairing, removal and the test scope.
- **OpenAI-compatible gateway such as LiteLLM** (README): a `providers:` entry with `key_env`, a
  `models:` list and `discover_models: false`, plus `model.provider: custom:<name>`, makes ACP (and so
  Paseo's model picker and Omnigent's catalog) list exactly the declared models; the `hermes config set`
  commands are documented. No new env knob: the HA add-on has no equivalent and plain config does it.
- `LITELLM_API_KEY` in `hermes.env`; `03-woow-dotenv` copies it into `/opt/data/.env` like the other
  provider keys. The gateway reads `key_env` from its environment, but Omnigent's direct-execution
  sessions start their own gateway from a scrubbed environment and see only `/opt/data/.env`
  (without the copy their first call answered 401).
- `scripts/upgrade.sh --no-llm`, `--set KEY=VALUE` (repeatable) and `--rebuild`, passed to `install.sh`.
  A host whose provider is set up in the dashboard could install with `--no-llm` but not upgrade.
- Tests: `tests/install-flags.sh` (CI, shims): upgrade's pass-through, the provider-key check, and the
  `--set` warning on a real `install.sh` run; `tests/image-test.sh` B3 checks the LiteLLM key copy.

### Changed
- `install.sh` no longer requires `MINIMAX_API_KEY` specifically: any of `MINIMAX_API_KEY`,
  `OPENROUTER_API_KEY` or `LITELLM_API_KEY` will do, and the error names `--no-llm` (also for
  `upgrade.sh`) and the dashboard/`config.yaml` alternative.

### Fixed
- **`install.sh --set` no longer warns that `hermes.env` lacks the key it is setting** (ported from
  Woow_podman_opendesign 4.2.1): an existing file gets the `--set` values before the missing-keys check,
  and a key that is still missing is still reported.

### Upgrade
`git pull && scripts/upgrade.sh` (add `--no-llm` if `hermes.env` has no provider key). It builds
`v0.22.5-woow3` and keeps `v0.22.5-woow2` for a rollback; no data migration. `install.sh` warns that
`hermes.env` lacks `LITELLM_API_KEY`; add the line (empty is fine). Omnigent and the LiteLLM provider
are opt-in: see the README.

## [0.22.0-quadlet] - 2026-11-06

Phase 2 of the alignment with the Home Assistant add-on (`Woow_ha_hermes_add_on` @ `d4cde45`): the
Paseo host adapter, the origin settings it needs, and a fix for a stack whose podman network was removed
behind systemd's back. Same upstream base (Hermes v0.22.5); new image tag `v0.22.5-woow2`.

### Security
- **The Paseo plugin accepts browser requests only from exact, operator-declared origins.** The adapter
  compares the request `Origin` with `HERMES_DASHBOARD_PUBLIC_URL` and, optionally, one more origin
  (`HERMES_PASEO_EXTRA_ORIGIN`). A public URL that is unset or not an exact origin answers
  `503 INVALID_DASHBOARD_ORIGIN` instead of guessing (adapter 0.1.4-rc.9, as in HA 0.1.14).
  `install.sh` refuses an extra origin with a path, credentials, a wildcard or a non-http(s) scheme,
  an extra origin next to a public URL that is not an exact origin, a public URL with credentials, a
  query or a fragment, and `HERMES_PASEO_INGRESS_ORIGIN` set by hand; it never prints a rejected value.
- **`/opt/data/.env` can no longer override the origins `hermes.env` declares.** `.env` wins over the
  environment, so a `HERMES_DASHBOARD_PUBLIC_URL` written there (`hermes dashboard register` does) or
  an empty `HERMES_PASEO_INGRESS_ORIGIN` would silently move the OAuth callback and the Paseo origin
  check. `03-woow-dotenv` strips `HERMES_DASHBOARD_PUBLIC_URL`, `HERMES_BASE_URL` and `HERMES_PASEO_*`.
- `podman exec hermes-agent hermes ...` still drops from root to the hermes user: the adapter's wrapper
  replaces only the venv entry point that upstream's `/opt/hermes/bin/hermes` shim execs. The build
  proves the shim and `libexec/hermes` are upstream's, and `tests/image-test.sh` P1 proves the drop.
- The wrapper refuses to start the dashboard as root.

### Added
- **Paseo host adapter** (`container/vendor/paseo`, the reviewed `host/` directory of
  `WOOWTECH/hermes-paseo-plugin` 0.1.4-rc.9 @ `1101a5d`, byte-identical to the HA add-on's copy):
  `dashboard_control.py`, `profile_lifecycle.py`, `resource_limits.py` in
  `/opt/hermes-paseo-dashboard-control/`, and the `hermes` wrapper as `/opt/hermes/.venv/bin/hermes`.
  An enabled Paseo plugin can reload the supervised dashboard and stops its daemon before a native
  disable or removal. The plugin itself is not bundled: install it from the dashboard's **Plugins**
  page (README, *Paseo*). Paseo needs Node.js 22.19+ (the image has 26.12.1; the build checks it) and
  egress to GitHub, npm and the Paseo relay on first use.
- `HERMES_PASEO_EXTRA_ORIGIN` in `hermes.env`: an optional second exact origin, typically the loopback
  `http://127.0.0.1:19119` when the public URL is an HTTPS tunnel. The boot hook
  `cont-init.d/04-woow-paseo-origin` validates it with HA's `paseo_origin.py` and hands it to the
  adapter as `HERMES_PASEO_INGRESS_ORIGIN`; a malformed value stops the boot, as on HA.
- Tests: `tests/test-paseo-vendor.py`, `tests/test-paseo-origin.py` (ported from HA; the origin cases
  also run through `install.sh`'s validator), `tests/resource-recreate.sh`, origin cases in
  `tests/dryrun.local.sh`, Paseo anchors in `tests/patch-anchors.sh`, and `tests/image-test.sh` P1-P6
  (privilege drop, adapter routes, accepted and refused origins, loopback and tunnel-shaped logins with
  an HTTPS public URL, `INVALID_DASHBOARD_ORIGIN`, a boot stopped by a bad extra origin).

### Fixed
- **`install.sh` recreates a network or volume that was removed outside systemd.** After a
  `podman system reset`-like event `hermes-network.service` stayed "active (exited)", `install.sh`
  restarted only units whose files changed, and PostgreSQL and Redis failed with "unable to find
  network with name or ID hermes". `install.sh` (and so `upgrade.sh`) now restarts any active
  `-network`/`-volume` unit whose podman object is missing, and the three containers with it. A volume
  recreated this way is empty, and `install.sh` says so loudly.

### Documentation
- README / README_zh-TW: *Public URL and HTTPS* (what an HTTPS public URL changes and what it does not:
  the loopback dashboard keeps working, sessions are per origin) and *Paseo* (requirements, install and
  enable steps, errors).

### Upgrade
`git pull && scripts/upgrade.sh`. It builds `v0.22.5-woow2` and keeps `v0.22.5-woow1` for a rollback;
no data migration. `install.sh` warns that `hermes.env` lacks `HERMES_PASEO_EXTRA_ORIGIN`; add the
line (empty is fine). To use Paseo through a tunnel, set `HERMES_DASHBOARD_PUBLIC_URL` and
`HERMES_BASE_URL` to the tunnel's `https://` origin first.

## [0.21.0-quadlet] - 2026-11-06

Hermes Agent **v0.22.5**, aligned with the Home Assistant add-on (`Woow_ha_hermes_add_on` @ `d4cde45`):
the same base, patches and provisioning defaults, without what only exists there (Ingress, the
Supervisor token boundary, Paseo). New image tag `v0.22.5-woow1`.

### Security
- **Unattended dangerous commands are refused.** Approvals run with upstream's defaults
  (`approvals.mode: smart`, `cron_mode` / `unattended_mode: deny`), so a dangerous command from a cron
  job, the OpenAI-compatible API or a webhook is blocked; `tests/test-approval-gate.py` proves it in the
  image. The `sed` in `woow-provision` that was meant to switch approvals off and cron to `yolo` is
  removed rather than made to work: it never matched the v2026.8.31 template and does not match the
  config v0.22.5 generates either, so this changes no running host. An existing `config.yaml` keeps
  what it says.
- **The MCP OAuth issuer check is no longer relaxed.** `iss-callback.py` and `iss-permissive.py` are
  dropped: v0.22.5 carries the RFC 9207 `iss` natively, and `upstream-contract.py` proves its state and
  issuer handling during the build. A server that returns a different issuer must fix its metadata;
  reconnect the integration afterwards.
- **Dashboard sessions are signed with a persistent secret,** the new podman secret
  `hermes-dashboard-session-secret` (`HERMES_DASHBOARD_BASIC_AUTH_SECRET`), so a restart no longer logs
  everyone out. `install.sh` and `migrate-legacy.sh` create it; `--rotate-secrets` rotates it with the
  other three; `tests/smoke.sh` A10 scans for it.
- **`/opt/data/.env` no longer carries a copy of a managed secret** (`API_SERVER_KEY`, `WEBHOOK_SECRET`,
  `HERMES_DASHBOARD_BASIC_AUTH_*`): `.env` wins over the environment, so a stale copy would override the
  podman secret. The boot hook strips them.
- `podman exec hermes-agent hermes ...` runs as the hermes user again: the unit no longer overrides
  `PATH`, which hid upstream's `/opt/hermes/bin` privilege-drop shim and left root-owned files behind.
- `HERMES_DASHBOARD_INSECURE` is gone from the unit (v0.22.5 no longer reads it).

### Fixed
- `hermes-provision.service` no longer fails on v0.22.5: it enabled the `moa` and `homeassistant`
  toolsets, which v0.22.5 removed (Home Assistant is a catalog plugin, MoA a model preset).

### Added
- `scoped-prompt-gc.py` (from the HA add-on): deleting a session reclaims only the system prompts that
  session and its delegate children referenced, instead of every unreferenced prompt in the store.
  Applied and verified against reviewed source hashes at build time.
- `agent-browser` baked into the image from upstream's hash-checked package pin, and provisioning
  defaults written only while a key is empty: `browser.backend off` (the built-in agent-browser on
  the image's Chromium), `web.search_backend ddgs`, `web.extract_backend parallel` (ddgs cannot
  extract), and `platforms.webhook.enabled` / `.extra.port` for the dashboard's Webhooks page.
- `cont-init.d/03-woow-dotenv` replaces the `.env` rewrite: a provider key from `hermes.env` is written
  only when its value changed since the last start, so a key edited in the dashboard survives a
  restart. `GITHUB_TOKEN` is copied too.
- Image ENV as in the HA add-on: `HERMES_DASHBOARD_PORT`, `HERMES_WRITE_SAFE_ROOT=/opt/data`, and the
  S6 grace times (`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`: a failed boot hook stops the container instead of
  starting it half-provisioned).
- Tests: `tests/test-config-contract.py`, `tests/test-scoped-prompt-gc.py`,
  `tests/test-scoped-prompt-gc-patch.py` (CI); `tests/image-test.sh`, `tests/test-approval-gate.py`,
  `tests/run-scoped-prompt-gc-image.py` (local, need the built image). `tests/patch-anchors.sh` now
  checks the scoped-GC pin and the upstream contracts. `container/patches/PROVENANCE` records every
  file taken from the HA add-on with its hash.

### Changed
- Base `docker.io/nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f33...` (was `v2026.8.31`).
- The TUI runs from the root-owned image tree: the `ui-tui` chown, `cont-init.d/016-fix-tui-perms`,
  `HERMES_TUI_DIR=/opt/data/ui-tui` and the copy into the volume are gone (the stale copy is removed on
  the first boot). `PLAYWRIGHT_BROWSERS_PATH` is the image's own again.
- `HERMES_UID` / `HERMES_GID` stay at **1000** (v0.22.5 defaults to 10000). Volumes carried over from
  the compose stack are owned by 1000, and v0.22.5's targeted ownership repair would leave most of such
  a volume unreadable to 10000: the gateway then fails at boot. Fresh volumes work the same.
- Generic settings moved from the unit into the image ENV; the unit keeps the permissive ones
  (`GATEWAY_ALLOW_ALL_USERS`, `API_SERVER_CORS_ORIGINS`) visible.

### Upgrade
`git pull && scripts/upgrade.sh`. The upgrade builds `v0.22.5-woow1`, creates the session secret, and
keeps `v2026.8.31-woow1` for a rollback. v0.22.5 migrates its SQLite schema forward on first start, so
a rollback also needs `scripts/restore.sh` with the pre-upgrade archive.

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
