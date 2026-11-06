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
in-image provisioning scripts: at boot (`cont-init.d/020-woow-provision`, `cont-init.d/03-woow-dotenv`)
and after the gateway is healthy (`hermes-provision.service` → `/usr/local/bin/woow-provision`).

The image and its provisioning follow the
[Home Assistant add-on](https://github.com/WOOWTECH/Woow_ha_hermes_add_on) (Hermes v0.22.5): the same
upstream base, patches, defaults and Paseo host adapter, without what only exists there (Ingress, the
Supervisor token boundary). `container/patches/PROVENANCE` lists what was taken from it, with hashes.

## What gets installed

| Item | Name | Notes |
|---|---|---|
| Agent | `hermes-agent` (unit `hermes-agent.service`) | `localhost/woow-hermes-agent:<tag>`, built here, `Pull=never`. Gateway 8642, dashboard 9119, webhook 8644, published on 127.0.0.1 by default. |
| Database | `hermes-postgresql` (unit `hermes-postgres.service`) | `postgres:15.19` by digest, **no host port**. |
| Cache | `hermes-redis` (unit `hermes-redis.service`) | `redis:7.4.11-alpine` by digest, **no host port**. |
| Provisioning | `hermes-provision.service` | oneshot, `WantedBy=hermes-agent.service`: waits for `/health`, enables the WOOWTECH tools and plugins **once** (stamped), fixes the model routes, and writes the web/browser/webhook defaults where a key is still empty. |
| Network | `hermes` | private bridge. |
| Volumes | `hermes-data`, `hermes-postgres-data`, `hermes-redis-data` | the agent's state (SQLite, sessions, skills, memories) is in `hermes-data`. |
| Settings | `~/.config/hermes/hermes.env` (0600) | provider keys and the public URL. |
| Credentials | podman secrets `hermes-api-server-key`, `hermes-webhook-secret`, `hermes-dashboard-password`, `hermes-dashboard-session-secret`, `hermes-postgres-password` | generated at install; there is no `admin`/`admin` default any more. The session secret signs dashboard logins, so a restart does not log anyone out. |

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
nano ~/.config/hermes/hermes.env       # a provider key (or use --no-llm) and the public dashboard URL
scripts/install.sh                     # build the image, render, validate, start, provision, smoke
```

The first run builds `localhost/woow-hermes-agent:$(sed -n 's/^HERMES_IMAGE_TAG=//p' scripts/common.sh)`;
that takes 5-15 minutes. `WOOW_HERMES_BUILD_CPUS` (plus `nice`) keeps it from starving co-located stacks.

| Option | Effect |
|---|---|
| `--no-llm` | Install without a provider key in `hermes.env` (platform only, or the provider is configured in the dashboard / `config.yaml`). |
| `--accept-defaults` | On the first run, keep going with the example settings. |
| `--set KEY=VALUE` | Store a setting first (repeatable), e.g. `--set WOOW_HERMES_MEMORY=3g`. |
| `--no-build` / `--rebuild` | Skip the build (the tag must exist) / rebuild it (the old image is kept as `<tag>-prev`). |
| `--rotate-secrets` | New API key, webhook secret, dashboard password and session secret, then restart the agent. Every API client, webhook sender and saved login has to be updated. |
| `--dry-run` | Render and validate, show what would change, touch nothing. |

Re-running `install.sh` is safe: with nothing changed it restarts nothing.

## Configure

Edit `~/.config/hermes/hermes.env`, then run `scripts/install.sh` again.

| Key | Default | Meaning |
|---|---|---|
| `HERMES_DASHBOARD_PUBLIC_URL` / `HERMES_BASE_URL` | `http://localhost:19119` | The exact origin the dashboard is opened from (behind a tunnel: its `https://` origin, no path). MCP OAuth callbacks go there and the Paseo plugin accepts browser requests only from it. Both lines must be identical. See [Public URL and HTTPS](#public-url-and-https). |
| `HERMES_PASEO_EXTRA_ORIGIN` | empty | Optional second exact origin for Paseo, e.g. `http://127.0.0.1:19119` when the public URL is a tunnel. See [Paseo](#paseo). |
| `MINIMAX_API_KEY`, `OPENROUTER_API_KEY`, `LITELLM_API_KEY` | empty | Provider keys. `install.sh` wants at least one of them, unless you run it (or `upgrade.sh`) with `--no-llm` because the provider is configured in the dashboard or `config.yaml`. `LITELLM_API_KEY` is the key of an [OpenAI-compatible gateway](#openai-compatible-gateway-such-as-litellm). |
| `GITHUB_TOKEN`, `MCP_*` | empty | Optional GitHub and MCP keys. |
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
into the model routes in `config.yaml`). That is how the dashboard TUI reads them. The boot hook
`03-woow-dotenv` writes `MINIMAX_API_KEY`, `OPENROUTER_API_KEY`, `LITELLM_API_KEY` and `GITHUB_TOKEN` there **only when
their value in `hermes.env` changed** since the last start, so a key edited in the dashboard is kept
across restarts (0.20.0 rewrote the file on every boot). An empty value in `hermes.env` leaves the
file alone; delete a key in the dashboard. The secrets the unit manages are stripped from that file,
because a copy there would override the podman secret.

### OpenAI-compatible gateway such as LiteLLM

Hermes can use any OpenAI-compatible endpoint (LiteLLM, vLLM, a company gateway) as a named provider.
Declared this way, **every model you list appears in the dashboard, in ACP clients and in Paseo's
model picker**, and in Omnigent's model list; a bare `model.base_url` shows only the current model.

1. Put the key into `hermes.env` and apply it (a new environment value needs a container restart,
   which `install.sh` does when the file changed):

   ```bash
   # ~/.config/hermes/hermes.env
   LITELLM_API_KEY=sk-...
   ```
   ```bash
   scripts/install.sh            # or scripts/upgrade.sh; add --no-llm if this is your only provider
   ```

2. Declare the provider and its models (`config.yaml` in the data volume; no restart needed, the next
   session and the running gateway pick it up):

   ```bash
   podman exec hermes-agent hermes config set providers.litellm.name LiteLLM
   podman exec hermes-agent hermes config set providers.litellm.base_url https://litellm.example.com/v1
   podman exec hermes-agent hermes config set providers.litellm.key_env LITELLM_API_KEY
   podman exec hermes-agent hermes config set providers.litellm.models '["deepseek/deepseek-v4.1-flash","z-ai/glm-5.3-flash"]'
   podman exec hermes-agent hermes config set providers.litellm.discover_models false
   podman exec hermes-agent hermes config set model.provider custom:litellm
   podman exec hermes-agent hermes config set model.default deepseek/deepseek-v4.1-flash
   ```

   which is this in `config.yaml`:

   ```yaml
   model:
     provider: custom:litellm
     default: deepseek/deepseek-v4.1-flash
   providers:
     litellm:
       name: LiteLLM
       base_url: https://litellm.example.com/v1
       key_env: LITELLM_API_KEY
       models: [deepseek/deepseek-v4.1-flash, z-ai/glm-5.3-flash]
       discover_models: false
   ```

- The base URL ends in `/v1`. `key_env` names the variable; the key itself never goes into
  `config.yaml`.
- `discover_models: false` keeps the list to the models you declared. Without it Hermes also asks the
  gateway's `/models` and lists **everything** the key can use (85 models on the gateway this was
  tested against), with your declared ones first.
- ACP and Paseo show the models as `custom:litellm:<model>` (display name: the bare model id). The
  current one comes from `model.provider` + `model.default`; switching in Paseo or ACP uses the
  prefixed id. Run `hermes config unset model.base_url` if an old OpenRouter `base_url` is still there.
- Tested on `v0.22.5-woow3` against a LiteLLM gateway: ACP `session/new` listed exactly the two models,
  and a prompt through each answered (`stopReason: end_turn`); Omnigent's catalog listed the same two
  and verified a conversation with each.

### Public URL and HTTPS

Set `HERMES_DASHBOARD_PUBLIC_URL` (and `HERMES_BASE_URL`, same value) to the **origin the browser
uses**. Behind a Cloudflare tunnel or another HTTPS reverse proxy that is its `https://` origin, for
example `https://hermes.example.com`: scheme, host, a port only when it is not 443, no path, no
trailing slash. `install.sh` refuses a public URL with credentials, a query or a fragment, and warns
when it is plain `http` on a non-loopback host or not an exact origin (a path prefix works for OAuth
but not for Paseo).

The loopback dashboard keeps working when the public URL is an HTTPS origin (`tests/image-test.sh`
P4): the dashboard binds `0.0.0.0` inside the container, so v0.22.5 accepts any `Host`; its cookies
follow the scheme of each request, not the public URL; and the login has no Origin check. So
`http://127.0.0.1:19119` (or `ssh -L`) and `https://hermes.example.com` both log in, as separate
sessions. What the public URL does change: MCP OAuth callbacks always go to it, and the Paseo plugin
only accepts it (plus `HERMES_PASEO_EXTRA_ORIGIN`). `localhost` and `127.0.0.1` are different origins.

The dashboard's own login is then the only gate in front of the agent: anyone who can reach the tunnel
can try the password. Keep `hermes-dashboard-password` long (the generated one is), and consider an
access policy in front of the tunnel.

### Paseo

The image carries the Paseo host adapter from the HA add-on (`container/vendor/paseo`, the reviewed
`host/` directory of [hermes-paseo-plugin](https://github.com/WOOWTECH/hermes-paseo-plugin)
`0.1.4-rc.9`, hashes in `PROVENANCE.json`). It lets an enabled Paseo plugin reload the dashboard and
stop its daemon before the plugin is disabled or removed. The plugin itself is **not** bundled: you
install it from the dashboard, and nothing is installed or enabled by an upgrade.

Requirements:

- An HTTPS public URL for use from other machines (Paseo pairing and model logins open in the
  browser). The adapter accepts `http` origins, as on Home Assistant's LAN, but a plain-http origin
  on a non-loopback host gets a warning from `install.sh`.
- Egress from the agent container to GitHub (the plugin source), the npm registry (the Paseo runtime,
  downloaded on first use into `/opt/data`, about a minute) and the official Paseo relay and web app
  (`app.paseo.sh`).
- Node.js 22.19+ (the plugin's `engines`): the image's Node is v26.12.1, and the build checks it.

Steps after `install.sh` (or `upgrade.sh`):

1. Open the dashboard **from the public URL** (or from `HERMES_PASEO_EXTRA_ORIGIN`) and log in.
2. **Plugins** → *Git URL or owner/repo*: `WOOWTECH/hermes-paseo-plugin`. Install the current release
   (`0.1.4-rc.9`; when scripting the Plugins API, the ref must be the full commit SHA
   `1101a5da63178e08bd0fdf849db8e2a5de4d6ef1`, not a tag) and enable it. The source is public; no
   GitHub token is needed. Review the source and the permissions note before confirming the caution prompt.
3. Open **Paseo**. The first start downloads the runtime; wait until the page says it is running.
   Hermes v0.22.5 loads a new plugin's backend on first use, so **Reload dashboard** is only needed
   when the page keeps saying the plugin API is not loaded.
4. Generate the pairing link, **Open Paseo**, and **Connect** in the official app. The pairing link
   grants access: do not post it anywhere. On a new device add a project first
   (**Add project → New directory**, parent `/opt/data`).
5. **New workspace**, pick the project, the Hermes provider, a logged-in model, then **Create**.

Disable or remove the plugin from the dashboard's Plugins page (the adapter stops the Paseo daemon
first), or `/paseo stop` before removing it from the CLI. State, pairing and conversations live in
`/opt/data`. A `503 INVALID_DASHBOARD_ORIGIN` means the public URL (or the extra origin) is not an
exact origin; `ORIGIN_DENIED` means the browser's origin is neither of them. Fix `hermes.env` and run
`scripts/install.sh` again; never turn the origin check off.

### Omnigent

The [Omnigent plugin](https://github.com/WOOWTECH/hermes-omnigent-plugin) (`0.1.0-rc.16`, Omnigent
`0.20.0`) connects this Hermes to an Omnigent server, so Omnigent conversations can run on this host.
As on Home Assistant it is **optional**: not bundled, not installed or enabled by an upgrade.

> **Security.** Every account that can use this host on the Omnigent server gets **the equivalent of a
> shell in the agent container**: Hermes runs those conversations as the container's `hermes` user,
> with its files (`/opt/data`: provider keys in `.env`, `config.yaml`, sessions, the Omnigent login
> token) and its network. Pair with a **dedicated, non-admin** Omnigent account used only for this
> host, and decide who on the server may use it. **Unlinking does not revoke the grant on the
> server**: it clears the local login, and the host's registration and history stay there (offline). Backups of
> `hermes-data` include the plugin's private runtime (about 0.6 GB), the Omnigent login token and the
> host identity: keep them as secrets.

What it needs, measured on this stack:

- About **0.6–0.7 GB** in `/opt/data/omnigent-plugin` (a private uv, Python 3.12 and Omnigent 0.20.0;
  25–35 s to install). Egress to GitHub (plugin source), PyPI (Omnigent), `deb.debian.org`
  (Bubblewrap, unpacked into the plugin directory) and the Omnigent server.
- tmux ≥ 3.3: the image has 3.5a.
- **Direct execution.** Hermes 0.22 conversations started by Omnigent work only with the plugin's
  *allow Hermes direct execution* consent (`sandbox=none`), as on Home Assistant. Without it the
  conversation's Hermes cannot reach a gateway and the plugin reports `REQUIRED_TERMINAL_EXITED`
  (`Gateway inaccessible: profile_mismatch`), with or without a working Bubblewrap. The container is
  the sandbox, as in Woow_podman_opendesign: rootless (container root is an unprivileged host uid),
  memory and CPU limits, no host mount but the `hermes-data` volume. It is not a network boundary:
  conversations have the container's egress and can reach `hermes-postgresql` and `hermes-redis` on
  the `hermes` network.
- **No Podman security option.** Bubblewrap in rootless Podman can create the user namespace the
  plugin's probe checks, so the pairing panel does **not** stop at `SANDBOX_NAMESPACE_UNAVAILABLE` and
  does not show the direct-execution checkbox. Omnigent's own Bubblewrap sandbox (a fresh `/proc` in
  a new PID namespace) fails here with `Can't mount proc on /proc: Operation not permitted` because
  Podman masks parts of `/proc`; only `--security-opt unmask=/proc/*` (or `unmask=ALL` /
  `systempaths=unconfined`) fixes that, for every process in the container. It would not help Hermes
  (see above), so the stack does not set it.

Install and pair:

1. Configure a working model first (for example the [LiteLLM recipe](#openai-compatible-gateway-such-as-litellm)).
   The key must be in `hermes.env` (or entered in the dashboard): Omnigent's conversations read
   `/opt/data/.env`, not the container environment.
2. Dashboard → **Plugins** → *Git URL or owner/repo*: `WOOWTECH/hermes-omnigent-plugin`, install and
   enable. Hermes warns `custom (unreviewed) source`, the usual note for anything outside its
   catalog; if the page also shows a caution about running processes, review it as for Paseo. Pinned
   from the CLI (full commit SHA, not a tag):
   `podman exec hermes-agent hermes plugins install WOOWTECH/hermes-omnigent-plugin --ref 6c86ebb4455083d50e3fed9f6d6a25c2dff56e9e --enable`
   (on 2026-11-06 this CLI install printed nothing beyond that note, so `--force` was not needed).
3. Pair from the host, because the panel has no direct-execution checkbox here:

   ```bash
   scripts/omnigent.sh pair --server https://omnigent.example.com --user hermes-host-1 --allow-direct-hermes
   ```

   It repeats the warning above, asks you to type `direct`, reads the password without echo and hands
   it to the plugin on stdin. The plugin installs its runtime, connects, and answers only when a real
   Hermes conversation replied (`"reply": "OMNIGENT_CONNECTION_OK"`).
4. `scripts/omnigent.sh status`, `catalog` (the Hermes models Omnigent will offer), `verify [--model ID]`,
   `acceptance --chat`. The pairing survives a restart of `hermes-agent` (the host reconnects in
   about 20 s). A new login, or disabling and re-enabling the plugin, needs `pair` again.

Remove: `scripts/omnigent.sh disconnect` (or **Unlink** in the plugin's settings), then remove the
plugin on the Plugins page. Removal keeps `/opt/data/omnigent-plugin`; restart `hermes-agent`, then
delete that directory (`podman exec -u hermes hermes-agent rm -rf /opt/data/omnigent-plugin`).

Tested on 2026-11-06 with `v0.22.5-woow3` against a local Omnigent 0.20.0 server (accounts auth) and
LiteLLM: install, pairing, `catalog` with both models, `verify` with each, `acceptance --chat`, a
restart, unlink. Not tested: the browser panels (Plugins page, pairing panel), a remote HTTPS Omnigent
server, Claude Code / Codex / Pi engines (not in the image), Paseo's own model picker (the ACP list it
is fed from was tested).

## The image

`container/Containerfile` has two targets:

- **`slim` (default)** — the pinned upstream base plus what `deploy.sh` used to do to the running
  container: tmux, the `hermes` CLI symlink, the removal of unused binaries and skill packs, `ddgs`
  (pinned), OfficeCLI (pinned and checksummed) and the pinned superpowers skills seed; plus, as in the
  HA add-on, `agent-browser` from upstream's hash-checked package pin and two build-time patches:
  `upstream-contract.py` (proves the native dashboard login and MCP OAuth state/issuer handling and the
  unattended approval path) and `scoped-prompt-gc.py` (deleting a session reclaims only the system
  prompts that session referenced, not every unreferenced one). The last build step asserts that each
  of them is really there.
- **`full`** — `slim` plus the toolchain from the old `docker/Dockerfile.hermes-agent` (pandoc, texlive,
  CJK fonts, yq, gh, cloudflared, ...). The podman deployment never ran it; gcloud, Playwright, httpie
  and yt-dlp are not ported yet. Opt in with `WOOW_HERMES_IMAGE_TARGET=full`.

```bash
scripts/build-image.sh                 # build the tag if it is missing
scripts/build-image.sh --force         # rebuild; the previous image is kept as <tag>-prev
tests/patch-anchors.sh                 # check the patches and contracts against the pinned upstream tag
tests/image-test.sh                    # boot the built image in throwaway containers (local, ~5 min)
```

Upgrading the upstream base means bumping `HERMES_BASE` **and** `HERMES_IMAGE_TAG` in
`scripts/common.sh` and the `Image=` line in `quadlet/hermes-agent.container`; CI checks that the three
agree. The tag is `<upstream tag>-woow<N>`. The base is pinned at `v0.22.5` by digest. It forwards the
RFC 9207 `iss` through its own dashboard OAuth flow, so the old `iss-callback.py` / `iss-permissive.py`
patches are gone and the MCP SDK's issuer check is no longer relaxed: an OAuth server that returns a
different issuer has to fix its metadata, and the integration has to be reconnected after that.

`tests/image-test.sh [IMAGE]` boots the image without publishing a port — on a fresh volume, on a
volume owned by uid 1000 as the compose stack left it, and with an HTTPS public URL — and checks s6,
the dashboard, provisioning, the `.env` merge, that a login survives a restart, the approval gate, the
scoped prompt GC, and the Paseo adapter (privilege drop, origins, loopback and tunnel logins, the
`INVALID_DASHBOARD_ORIGIN` answer). CI cannot build the image, so run it before a release. Set
`IMAGE_TEST_PREFIX` so its container and volume names cannot collide with anything else on the host.

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
scripts/upgrade.sh                       # [--no-llm] [--set KEY=VALUE]... [--rebuild] [--no-backup]
```

Backup, unit snapshot, build, `install.sh`, smoke. `--no-llm`, `--set` and `--rebuild` are passed to
`install.sh`: use `--no-llm` when `hermes.env` has no provider key because the provider is set up in
the dashboard or `config.yaml`. On failure the previous units come back, and with
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

`scripts/migrate-legacy.sh` does this end to end, with a rollback.

```bash
scripts/migrate-legacy.sh --dry-run        # every check, plus which rollback shape this host needs
scripts/migrate-legacy.sh --prepare-only   # env file, secrets, the image build, the hot backup
scripts/migrate-legacy.sh --yes            # the cutover
scripts/migrate-legacy.sh --status         # what it recorded
```

**The three volumes are adopted where they are.** `quadlet/*.volume` renders `VolumeName=` from
`WOOW_HERMES_DATA_VOLUME`, `WOOW_HERMES_POSTGRES_VOLUME` and `WOOW_HERMES_REDIS_VOLUME`, and the
migration sets those to the compose-era names `podman_hermes-data`, `podman_postgres-data` and
`podman_redis-data`. The 1.3 GB of agent state is never copied, and the adoption is **proved** after
the install: each volume's mountpoint, `CreatedAt` and inode are compared with the values read
before the cutover. A unit left on the default name would have produced a brand new, empty
`hermes-data` here, and that comparison is what catches it. A fresh install keeps the defaults.

What it refuses rather than guesses: a missing, stopped or already-Quadlet-managed container; a
volume mounted somewhere other than where this repo expects it; a second running container writing
to one of them; an agent that does not publish all three ports; ports published on more than one
address; a port held by something that is not the legacy stack; a PostgreSQL major that differs from
the pin (an adopted cluster cannot change major version in place); a database that does not answer
`pg_isready`; an empty `HERMES_DASHBOARD_PUBLIC_URL`; units already installed; and `hermes.network`
named after the compose project (see below).

Everything expensive happens **before** any downtime: the env file, the secrets, the image build
(5–15 minutes plus the base pull), the pinned `postgres` and `redis` pulls, a `pg_dump -Fc` of the
`hermes` database plus `pg_dumpall --roles-only`, hot exports of all three volumes, `podman inspect`,
the compose files, and — on the capture path — the rollback copy. `--prepare-only` stops there. The
cutover then stops the stack, takes cold exports, retires the containers, stamps the config policy
(below), installs, proves the adoption, runs `tests/smoke.sh`, compares with the pre-cutover
snapshot and prints the **measured downtime**.

### Three things change on purpose

* **The image.** The compose stack ran `docker.io/nousresearch/hermes-agent:latest` and then mutated
  the running container with `podman exec`: `deploy/podman/deploy.sh` apt-installed tmux, uv-installed
  `ddgs` into the agent venv, downloaded OfficeCLI, symlinked into `/usr/local/bin`, `rm -rf`'d skill
  packs under `/opt/hermes` and patched two Python sources there. The Quadlet stack runs
  `localhost/woow-hermes-agent:<tag>`, built from a digest-pinned base with all of that baked in. The
  script reports both images and names the change in the confirmation prompt. Nothing is read back
  out of the old container — those 42 MB of writable layer are reproduced by the build, not copied.
* **The secrets are carried over,** not regenerated: the API key, the webhook secret and the
  dashboard password come from the legacy container's environment, so API clients, webhook senders
  and saved logins keep working. `--rotate-secrets` generates new ones instead and breaks all three.
  The database password is seeded from the legacy container too, because PostgreSQL reads
  `POSTGRES_PASSWORD_FILE` only at initdb: on an adopted cluster the recorded secret has to be the
  password the cluster already has. `--align-db-password` additionally runs `ALTER ROLE`.
* **The config policy is stamped, not re-applied.** `hermes-provision.service` enables the WOOWTECH
  tools and plugins unless `/opt/data/.woow-policy-v1` exists. `deploy.sh` already did that on this
  very volume and the dashboard may have changed settings since, so the migration writes the stamp
  while the volume is idle. `--reapply-config-policy` skips the stamp and lets provisioning run it
  again. (The `sed` approval policy that used to come with it is gone; see Security posture.)

Ports keep whatever the compose stack published, including `0.0.0.0`. Set `WOOW_HERMES_BIND=127.0.0.1`
in `~/.config/hermes/hermes.env` and re-run `scripts/install.sh` to close them off afterwards.

### The compose project is called `podman`, and so is its network

The compose file lives in `deploy/podman/`, so podman-compose derived the project name **`podman`**:
its volumes are `podman_*` and its network is **`podman_default`**. That name reads like podman's own
default network and belongs to no app — **on `woowtechopenclaw` it IS the hermes stack's network.**
Deleting it as a stray leftover breaks the legacy stack and every rollback that depends on it.

The volumes are adopted because they hold data. A network holds none, so `quadlet/hermes.network`
creates a fresh `hermes` and leaves `podman_default` alone. That is deliberate: adopting the name
would put `podman_default` inside this app's manifest, and `scripts/uninstall.sh --purge` would then
delete it. The migration refuses to run if `quadlet/hermes.network` is ever renamed to it,
`tests/dryrun.sh` checks that no rendered unit carries it, and the cutover warns not to remove it
during the soak.

### Rollback shape (STANDARD 7a)

Keeping a rollback by renaming the legacy containers and leaving them stopped only works while
nothing starts them again. The user unit `podman-restart.service` runs
`podman start --all --filter restart-policy=always` at boot. `ql_rollback_strategy` asks this host
whether that unit is enabled and whether any legacy container's policy is exactly `always`:

| answer | what the cutover does | what `--rollback` does |
|---|---|---|
| `rename` | `podman rename <name> <name>-legacy-<suffix>`, left stopped | renames them back and starts them |
| `capture` | `ql_capture_container` into the backup, then a plain `podman rm` (never `rm -v`) | `ql_recreate_container` rebuilds them with their original restart policy, then starts them |

On `woowtechopenclaw` all three hermes containers are `unless-stopped`, which that filter does not
match, so that host takes the rename path today. The capture path still matters here, and it is the
one that needs **`--commit`**: `hermes-agent`'s writable layer is **42 672 686 bytes across 844
files** — precisely the changes `deploy.sh` made — so capture-then-remove without a commit would hand
a rollback a container missing every one of them. `scripts/common.sh` declares `hermes-agent` in
`LEGACY_COMMIT_ALWAYS` for that reason, and any container over `LEGACY_COMMIT_RW_BYTES` (1 MiB) is
committed on its measurement alone — which is how `hermes-postgresql` (1 087 119 bytes) is treated.
The size comes from `podman inspect --size` (`.SizeRw`); **`podman diff` prints an empty object for
the live `hermes-agent` and is not a substitute.** `tests/rollback-model.sh` pins all of it.

### Rollback

```bash
scripts/migrate-legacy.sh --rollback
```

It stops and removes the Quadlet units (**the three volumes, `podman_default` and the secrets are
kept**), brings the legacy containers back in whichever shape the cutover used, starts the database
and the cache first and then the agent, and waits for `/health`. No data restore is involved: the
volumes were adopted in place and never rewritten. The `pg_dump` and the cold exports in the backup
directory are only for a damaged database — `pg_restore -c -d hermes` from inside the container.

Note that the legacy stack has **no systemd unit** and its policy is `unless-stopped`, which
`podman-restart.service` does not match: it does not come back by itself after a reboot. That was
true before the migration too — Quadlet is the fix for it.

### After the soak

Remove `hermes-*-legacy-<suffix>` (rename path) or the `legacy-container/` directory in the backup
and any `localhost/woow-legacy/hermes-agent:*` image a commit produced (capture path); archive the
backup directory; and only then consider `podman_default`. Keep the compose checkout until then.

## Security posture

Approvals run with **upstream's defaults**: `approvals.mode: smart`, and `approvals.cron_mode` /
`approvals.unattended_mode: deny`, so a dangerous command from a cron job, the OpenAI-compatible API
or a webhook — where nobody is there to approve it — is refused (`tests/test-approval-gate.py` proves
it in the image). 0.20.0 carried a `sed` that was meant to switch approvals off and cron to `yolo`; it
never matched the config template, so it never took effect, and it is removed rather than made to
work (the same decision as the HA add-on). An existing `config.yaml` keeps whatever it says; change
these in the dashboard (**Config**).

Still permissive, and visible in `quadlet/hermes-agent.container`: `GATEWAY_ALLOW_ALL_USERS=true` and
`API_SERVER_CORS_ORIGINS=*`. `HERMES_DASHBOARD_INSECURE` is gone (v0.22.5 no longer reads it). What
the stack adds is loopback-only publishing, generated credentials instead of `admin`/`admin`, a
dashboard that a stranger on the LAN can no longer reach, and stable session signing.

The agent runs as container uid **1000** (`HERMES_UID`), not v0.22.5's default 10000: volumes carried
over from the compose stack are owned by 1000, and stage2's targeted ownership repair would leave most
of such a volume unreadable to 10000 (the gateway then fails at boot). A fresh volume works with either;
keeping one value keeps a rollback to 0.20.0 working too.

## Files

```
container/Containerfile            the image: slim (parity) and full targets
container/patches/                 build-time patches shared with the HA add-on, and their PROVENANCE
container/vendor/paseo/            the Paseo host adapter and hermes entry point (from the HA add-on)
container/rootfs/                  in-image provisioning: cont-init hooks and /usr/local/bin/woow-provision
container/fix-model-routes.py      idempotent model-route fix, run by woow-provision
quadlet/                           units with @@VAR@@ tokens; quadlet/render-vars is the whitelist
systemd/hermes-provision.service   the oneshot that runs woow-provision after the gateway is healthy
config/hermes.env.example          template for ~/.config/hermes/hermes.env
config/golden-config.yaml          reference config (not applied automatically)
scripts/                           build-image, install, upgrade, uninstall, backup, restore,
                                   migrate-legacy, omnigent (the optional Omnigent plugin)
scripts/legacy-common.sh           the rename-vs-capture rollback helpers, the writable-layer
                                   decision and the volume adoption proof
scripts/lib/                       vendored quadlet-lib (do not edit; CI checks its hash)
tests/dryrun.sh                    render + Quadlet 4.9.3 dry-run + systemd-analyze verify (CI and local)
tests/patch-anchors.sh             the patches and contracts against the pinned upstream tag (CI)
tests/test-config-contract.py      the image/unit/provisioning contract, statically (CI)
tests/test-scoped-prompt-gc*.py    the scoped prompt GC on upstream excerpts (CI)
tests/image-test.sh                boots the built image in throwaway containers (local)
tests/test-approval-gate.py        the unattended approval gate, inside the image (run by image-test)
tests/run-scoped-prompt-gc-image.py  the scoped prompt GC against the image's SessionDB (run by image-test)
tests/smoke.sh                     post-install checks on a host
tests/lint-repo.sh                 credential scan, image pin parity, no live-mutation (CI)
tests/provisioning-test.sh         fix-model-routes.py exit codes against real config shapes (CI)
tests/rollback-model.sh            the rollback model, the writable-layer decision and the
                                   adoption proof, against tests/shims (CI)
tests/resource-recreate.sh         a network/volume removed behind systemd's back is recreated (CI)
tests/install-flags.sh             upgrade.sh's install flags, the provider-key check, --set warnings (CI)
tests/test-paseo-vendor.py         the Paseo adapter pins and packaging (CI)
tests/test-paseo-origin.py         the extra Paseo origin validation, boot hook and install.sh (CI)
tests/shims/                       podman and systemctl doubles; no container is ever created
docs/odoo-posting.md               the Odoo cron notes that used to live in deploy/podman/SKILL.md
docs/migration-rehearsal-toypark1234.md   output of the end-to-end rehearsal of the migration
```

## Troubleshooting

| Symptom | Check |
|---|---|
| The build fails on a patch anchor | Upstream moved the code: run `tests/patch-anchors.sh`, then update `container/patches/` or the pinned base. |
| The dashboard says "No API key configured" | The TUI reads `/opt/data/.env`, which the boot hook merges from the env file. Set `MINIMAX_API_KEY` and restart `hermes-agent.service`. |
| A key changed in `hermes.env` is not used | The dashboard's copy in `/opt/data/.env` wins until the `hermes.env` value changes again; edit it in the dashboard, or change it in `hermes.env` and restart. |
| An MCP OAuth sign-in fails with an issuer mismatch | v0.22.5 keeps the SDK's RFC 9207 check. Fix the server's issuer metadata, then reconnect the integration. |
| `hermes-provision.service` failed | `journalctl --user -u hermes-provision.service -n 100`. It waits up to 5 minutes for `/health`; the agent must be healthy first. |
| The TUI looks stale after an upgrade | The TUI runs from the image (`/opt/hermes/ui-tui`), so a new image is a new TUI; reload the page. `/opt/data/.woow-image-version` shows which image last booted the volume. |
| A tool that `deploy.sh` used to install is missing | Add it to `container/Containerfile` and rebuild. Nothing is installed into the running container any more, by design. |
| Units gone after logout or reboot | `loginctl show-user $USER -p Linger` must say `yes`. |
| `install.sh` or `upgrade.sh` stops with "no LLM provider key" | Put a key into `hermes.env`, or pass `--no-llm` when the provider is configured in the dashboard or `config.yaml`. |
| Omnigent reports `REQUIRED_TERMINAL_EXITED` (`profile_mismatch`) | The pairing was made without direct execution: run `scripts/omnigent.sh pair ... --allow-direct-hermes` ([Omnigent](#omnigent)). |
| Omnigent's Hermes answers 401 / "no API key" while the dashboard works | The key is only in the container environment. Put it into `hermes.env` (`03-woow-dotenv` copies it to `/opt/data/.env`) and restart. |
| `unable to find network with name or ID hermes` | The network was removed outside systemd (`podman system reset`, `podman network rm`) while `hermes-network.service` stayed active. Run `scripts/install.sh` again: it restarts that unit and the containers. A volume gone the same way is recreated **empty**, with a warning: restore it with `scripts/restore.sh`. |
| Paseo says `INVALID_DASHBOARD_ORIGIN` or `ORIGIN_DENIED` | See [Paseo](#paseo): the public URL must be the exact origin in the browser's address bar. |
| The container stops at boot with `Invalid HERMES_PASEO_EXTRA_ORIGIN` | Fix the value in `hermes.env` (scheme://host[:port], no path) and run `scripts/install.sh`, which validates it first. |
