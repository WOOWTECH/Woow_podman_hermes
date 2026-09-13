# Woow Hermes Agent on rootless Podman (Quadlet + systemd)

**English** · [繁體中文](README_zh-TW.md)

The [Hermes Agent](https://github.com/NousResearch/hermes-agent) stack — gateway, dashboard with the
chat TUI, and webhook receiver — as rootless Podman
[Quadlet](https://docs.podman.io/en/v4.9.3/markdown/podman-systemd.unit.5.html) units under
`systemd --user`, from an **immutable image** built in this repo.

> **Docker or podman-compose users:** the compose deployment (`deploy/podman/`) was removed. The last
> compose version is kept at the tag
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_hermes/tree/compose-final)
> (`git clone -b compose-final https://github.com/WOOWTECH/Woow_podman_hermes.git`). It is not
> maintained: it has no boot recovery on rootless podman, its dashboard password defaults to `admin`,
> and it depends on `deploy.sh` mutating the running container. For Kubernetes use
> [Woow_k3s_hermes](https://github.com/WOOWTECH/Woow_k3s_hermes).

## Why this release exists

The old deployment ran `deploy.sh` **against the running container**: it apt-installed tmux, pip-installed
`ddgs`, downloaded OfficeCLI, patched the MCP OAuth code inside `/opt/hermes`, and copied skills in — mostly
with `2>/dev/null`, so failures were invisible, and all of it was lost whenever the container was
recreated. On the live host `podman diff hermes-agent` returned **zero** lines, so nobody could tell
whether the MCP OAuth patches were actually applied.

Everything that touched the image now happens at build time in `container/Containerfile`, where a moved
patch anchor or a changed download **fails the build**. Everything that touches the data volume happens in
in-image provisioning scripts: at boot (`cont-init.d/020-woow-provision`) and once after the gateway is
healthy (`hermes-provision.service` → `/usr/local/bin/woow-provision`).

## What gets installed

| Item | Name | Notes |
|---|---|---|
| Agent | `hermes-agent` (unit `hermes-agent.service`) | `localhost/woow-hermes-agent:<tag>`, built here, `Pull=never`. Gateway 8642, dashboard 9119, webhook 8644, published on 127.0.0.1 by default. |
| Database | `hermes-postgresql` (unit `hermes-postgres.service`) | `postgres:15.19` by digest, **no host port**. |
| Cache | `hermes-redis` (unit `hermes-redis.service`) | `redis:7.4.11-alpine` by digest, **no host port**. |
| Provisioning | `hermes-provision.service` | oneshot, `WantedBy=hermes-agent.service`: waits for `/health`, applies the WOOWTECH config policy **once** (stamped), enables the tools and plugins, and fixes the model routes. |
| Network | `hermes` | private bridge. |
| Volumes | `hermes-data`, `hermes-postgres-data`, `hermes-redis-data` | the agent's state (SQLite, sessions, skills, memories) is in `hermes-data`. |
| Settings | `~/.config/hermes/hermes.env` (0600) | provider keys and the public URL. |
| Credentials | podman secrets `hermes-api-server-key`, `hermes-webhook-secret`, `hermes-dashboard-password`, `hermes-postgres-password` | generated at install; there is no `admin`/`admin` default any more. |

> **PostgreSQL and Redis are parity services.** Nothing in this repo (or in the compose file before it)
> gives the agent a connection string for either, and on the live host their volumes were empty while
> the agent kept its state in SQLite under `/opt/data`. They are installed for parity with the k3s
> chart and wired as `Wants=`, so they can never keep the agent from starting. If you do not need
> them, say so in an issue and they can be dropped.

## Requirements

- Linux with systemd and cgroup v2. Tested on Ubuntu 24.04.
- Podman 4.9 or newer, rootless, plus `curl` and `git`.
- A normal login session for the user who owns the containers, and linger (install.sh enables it).
- About 8 GB of disk for the build (the upstream base alone is ~2.8 GB) and as much RAM as
  `WOOW_HERMES_MEMORY` says (default 6g; 3g is enough for a small host).
- Free ports 18642, 19119 and 18644 by default. The database and the cache publish nothing, so a
  PostgreSQL or Redis already on `127.0.0.1:5432` / `6379` is not a conflict.

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_hermes.git
cd Woow_podman_hermes
scripts/install.sh                     # first run: creates ~/.config/hermes/hermes.env and stops for review
nano ~/.config/hermes/hermes.env       # MINIMAX_API_KEY and the public dashboard URL
scripts/install.sh                     # build the image, render, validate, start, provision, smoke
```

The first run builds `localhost/woow-hermes-agent:$(sed -n 's/^HERMES_IMAGE_TAG=//p' scripts/common.sh)`;
that takes 5-15 minutes. `WOOW_HERMES_BUILD_CPUS` (plus `nice`) keeps it from starving co-located stacks.

| Option | Effect |
|---|---|
| `--no-llm` | Install without a provider key (platform checks only). |
| `--accept-defaults` | On the first run, keep going with the example settings. |
| `--set KEY=VALUE` | Store a setting first (repeatable), e.g. `--set WOOW_HERMES_MEMORY=3g`. |
| `--no-build` / `--rebuild` | Skip the build (the tag must exist) / rebuild it (the old image is kept as `<tag>-prev`). |
| `--rotate-secrets` | New API key, webhook secret and dashboard password, then restart the agent. Every API client, webhook sender and saved login has to be updated. |
| `--dry-run` | Render and validate, show what would change, touch nothing. |

Re-running `install.sh` is safe: with nothing changed it restarts nothing.

## Configure

Edit `~/.config/hermes/hermes.env`, then run `scripts/install.sh` again.

| Key | Default | Meaning |
|---|---|---|
| `HERMES_DASHBOARD_PUBLIC_URL` / `HERMES_BASE_URL` | `http://localhost:19119` | The URL the dashboard is opened from; MCP OAuth callbacks use it. Both lines must be identical. |
| `MINIMAX_API_KEY` | empty | Required unless you install with `--no-llm`. |
| `OPENROUTER_API_KEY`, `GITHUB_TOKEN`, `MCP_*` | empty | Optional provider and MCP keys. |
| `WOOW_HERMES_BIND` | `127.0.0.1` | Address the three ports are published on; `all` covers IPv4 and IPv6. |
| `WOOW_HERMES_PORT_GATEWAY` / `_DASHBOARD` / `_WEBHOOK` | `18642` / `19119` / `18644` | Host ports. |
| `WOOW_HERMES_MEMORY` / `WOOW_HERMES_CPUS` | `6g` / `3` | Limits for the agent container. |
| `WOOW_HERMES_IMAGE_TARGET` | `slim` | `full` adds the old 7-layer toolchain (see below). |
| `WOOW_HERMES_BUILD_CPUS` | empty | `--cpuset-cpus` for the build, e.g. `0-2`. |

The provider keys are the one exception to "no credentials in the env file": they are user-supplied
and often empty, which podman secrets cannot express. Everything generated lives in a podman secret:

```bash
podman secret inspect --showsecret --format '{{.SecretData}}' hermes-dashboard-password   # private terminal
podman secret inspect --showsecret --format '{{.SecretData}}' hermes-api-server-key
```

Hermes itself copies the provider keys into the data volume (`/opt/data/.env`, 0600, and OpenRouter
into the model routes in `config.yaml`). That is how the dashboard TUI reads them; it was true before
this release too.

## The image

`container/Containerfile` has two targets:

- **`slim` (default)** — the pinned upstream base plus exactly what `deploy.sh` used to do to the
  running container: tmux, the `hermes` CLI symlink, the removal of unused binaries and skill packs,
  `ddgs` (pinned), OfficeCLI (pinned and checksummed), the two MCP OAuth `iss` patches, the pinned
  superpowers skills seed, and the TUI ownership fix. The last build step asserts that each of them is
  really there.
- **`full`** — `slim` plus the toolchain from the old `docker/Dockerfile.hermes-agent` (pandoc, texlive,
  CJK fonts, yq, gh, cloudflared, ...). The podman deployment never ran it; gcloud, Playwright, httpie
  and yt-dlp are not ported yet. Opt in with `WOOW_HERMES_IMAGE_TARGET=full`.

```bash
scripts/build-image.sh                 # build the tag if it is missing
scripts/build-image.sh --force         # rebuild; the previous image is kept as <tag>-prev
tests/patch-anchors.sh                 # check the MCP OAuth anchors against the pinned upstream tag
```

Upgrading the upstream base means bumping `HERMES_BASE` **and** `HERMES_IMAGE_TAG` in
`scripts/common.sh` and the `Image=` line in `quadlet/hermes-agent.container`; CI checks that the three
agree. The base is pinned at `v2026.8.31`, where every `iss-callback.py` anchor still exists; upstream
`v2026.9.7` forwards `iss` itself, so moving to it means dropping that patch.

## Verify

```bash
tests/smoke.sh           # units, health, ports, dashboard and gateway auth, the baked-in tools,
                         # immutability (podman diff), provisioning stamps, secret hygiene
tests/smoke.sh --quick   # units, health, ports and /health only
```

The dashboard is at `http://127.0.0.1:19119/` (user `admin`); from elsewhere use
`ssh -L 19119:127.0.0.1:19119 <host>` or a tunnel. The gateway speaks the OpenAI API at
`http://127.0.0.1:18642/v1` with `Authorization: Bearer <hermes-api-server-key>`.

## Upgrade

```bash
git pull
scripts/upgrade.sh
```

Backup, unit snapshot, build, `install.sh`, smoke. On failure the previous units come back, and with
them the previous image tag. The agent migrates its SQLite schema forward, so a rollback across a
schema change also needs `scripts/restore.sh` with the pre-upgrade archive.

## Backup and restore

```bash
scripts/backup.sh                      # stops the agent, exports hermes-data, dumps the parity database
scripts/backup.sh --hot                # without stopping (SQLite may be mid-write)
scripts/restore.sh --archive ~/.local/share/woow-backups/hermes/backup-<ts> --confirm-restore hermes
```

## Uninstall

```bash
scripts/uninstall.sh                             # remove the units; keep the volumes, secrets, settings
scripts/uninstall.sh --purge                     # also delete them, after a final backup
scripts/uninstall.sh --purge --purge-images      # and remove the locally built agent images
```

`--purge` is the only command that deletes data.

## Migrating the podman-compose deployment

The compose stack used generic volume names (`podman_hermes-data`, ...), so this is a **copy**
migration, not an in-place adoption.

1. **Build the image first:** `scripts/build-image.sh`. The base moves from a `main` build to the
   pinned `v2026.8.31` release.
2. **Stop the old stack and copy the volumes:**
   ```bash
   podman stop hermes-agent hermes-postgresql hermes-redis
   podman volume export podman_hermes-data -o hermes-data.tar          # ~1.2 GB
   podman volume create hermes-data && podman volume import hermes-data hermes-data.tar
   ```
   Do the same for `podman_postgres-data` → `hermes-postgres-data` and `podman_redis-data` →
   `hermes-redis-data`. The old volumes stay untouched, which is your rollback.
3. **Mark the config policy as already applied** (the old `deploy.sh` did it), so provisioning does not
   re-run the `sed` policy over a config you have since changed:
   ```bash
   mp=$(podman volume inspect --format '{{.Mountpoint}}' hermes-data)
   podman unshare touch "$mp/.woow-policy-v1" && podman unshare chown 1000:1000 "$mp/.woow-policy-v1"
   ```
4. **Import the secrets from the old `.env`,** piped, never echoed, so API clients and webhook senders
   keep working:
   ```bash
   grep '^API_SERVER_KEY=' .env | cut -d= -f2- | tr -d '\n' | podman secret create hermes-api-server-key -
   ```
   Do the same for `WEBHOOK_SECRET` → `hermes-webhook-secret`, `DASHBOARD_PASSWORD` →
   `hermes-dashboard-password` and `POSTGRES_PASSWORD` → `hermes-postgres-password` (that one must
   match the initialised cluster). Move `MINIMAX_API_KEY`, `OPENROUTER_API_KEY`, `GITHUB_TOKEN` and
   `HERMES_DASHBOARD_PUBLIC_URL` into `~/.config/hermes/hermes.env`.
5. **Rename the legacy containers** (`podman rename hermes-agent hermes-agent-legacy-$(date +%Y%m%d)`,
   and the same for the other two) so Quadlet cannot replace them, then `scripts/install.sh` and
   `tests/smoke.sh`.
6. **Announce the behaviour changes:** the three ports are now on 127.0.0.1 unless you set
   `WOOW_HERMES_BIND=all`, and the dashboard password is whatever you imported (no `admin`).

## Security posture

This release keeps the agent's existing (permissive) policy — approvals off, `cron_mode: yolo`,
auto-accept, `GATEWAY_ALLOW_ALL_USERS=true`, `API_SERVER_CORS_ORIGINS=*`, `HERMES_DASHBOARD_INSECURE=1`
— because changing it would change behaviour people depend on. What it adds is loopback-only
publishing, generated credentials instead of `admin`/`admin`, and a dashboard that a stranger on the
LAN can no longer reach. Reviewing that policy deserves its own issue.

## Files

```
container/Containerfile            the image: slim (parity) and full targets
container/patches/                 the MCP OAuth iss patches (they fail the build if an anchor moves)
container/rootfs/                  in-image provisioning: cont-init hooks and /usr/local/bin/woow-provision
container/fix-model-routes.py      idempotent model-route fix, run by woow-provision
quadlet/                           units with @@VAR@@ tokens; quadlet/render-vars is the whitelist
systemd/hermes-provision.service   the oneshot that runs woow-provision after the gateway is healthy
config/hermes.env.example          template for ~/.config/hermes/hermes.env
config/golden-config.yaml          reference config (not applied automatically)
scripts/                           build-image, install, upgrade, uninstall, backup, restore
scripts/lib/                       vendored quadlet-lib (do not edit; CI checks its hash)
tests/dryrun.sh                    render + Quadlet 4.9.3 dry-run + systemd-analyze verify (CI and local)
tests/patch-anchors.sh             the patch anchors against the pinned upstream tag
tests/smoke.sh                     post-install checks on a host
tests/lint-repo.sh                 credential scan, image pin parity, no live-mutation (CI)
docs/odoo-posting.md               the Odoo cron notes that used to live in deploy/podman/SKILL.md
```

## Troubleshooting

| Symptom | Check |
|---|---|
| The build fails on a patch anchor | Upstream moved the code: run `tests/patch-anchors.sh`, then update `container/patches/` or the pinned base. |
| The dashboard says "No API key configured" | The TUI reads `/opt/data/.env`, which the boot hook writes from the env file. Set `MINIMAX_API_KEY` and restart `hermes-agent.service`. |
| `hermes-provision.service` failed | `journalctl --user -u hermes-provision.service -n 100`. It waits up to 5 minutes for `/health`; the agent must be healthy first. |
| The TUI looks stale after an upgrade | The boot hook re-syncs `/opt/data/ui-tui` when the image version changes; check `/opt/data/.woow-image-version`. |
| A tool that `deploy.sh` used to install is missing | Add it to `container/Containerfile` and rebuild. Nothing is installed into the running container any more, by design. |
| Units gone after logout or reboot | `loginctl show-user $USER -p Linger` must say `yes`. |
