# `archive/pre-quadlet-deployment/` — the openclaw compose-era deployment layer

**Reference material. Not installed, not executed, not tested, and not the deployment path of this
repository.** Deploy this repository with `scripts/install.sh` (Quadlet + systemd). Everything
under `tree/` describes what came *before* that, and is kept only so the work is not lost.

本目錄為**歷史參考資料**，不是本倉庫的部署路徑，請勿執行；實際部署請用 `scripts/install.sh`。

`tree/` is a byte-identical copy of the host directory, minus the files listed under
*What was excluded* below. No preserved file was edited.

## Where it came from / 來源

Host `woowtechopenclaw`, directory `~/Woow_podman_hermes`.

That directory was assumed to be a clone of this repository. It is not: it has **no `.git` at
all** — no remote, no history, no bundle. Unlike the other three openclaw trees it does not even
carry a `.deployed-commit`, so there is no claimed provenance to check. A file-by-file comparison
against `main` and an org-wide code search found the material below in no git repository anywhere.

Honest caveat about how live it was: the three hermes containers on that host
(`hermes-agent`, `hermes-postgresql`, `hermes-redis`) ran under `podman-compose` from
`tree/deploy/podman/podman-compose.yml` with **no systemd unit at all** — `restart: unless-stopped`
is not matched by podman's restart filter, so they did not come back after a reboot. So this tree
is not executed by a unit the way the nginxpm, odoo and tailscale trees are; it is the recipe those
running containers were created from, plus the k3s operational tooling that has no home anywhere else.

Extracted from the local backup
`~/.local/share/woow-openclaw-deployment-backup/20260913-234957/deployment-layer.tgz`
(sha256 `13b07d18c3f511e602f63ba4bcff17705cca5bcdd69ef063cf136ac0bf87778f`, captured 2026-09-13).
Nothing was read from, or changed on, the host to produce this directory.

## What it deployed / 部署內容

Hermes Agent v0.17.0 as a three-container `podman-compose` project (`hermes-agent` on
`nousresearch/hermes-agent:latest`, `postgres:15`, `redis:7-alpine`), publishing
`0.0.0.0:18642 -> 8642` (gateway), `0.0.0.0:18644 -> 8644` (webhook) and
`0.0.0.0:19119 -> 9119` (dashboard) — all on **all interfaces**, which is one of the things the
Quadlet rewrite fixed (`WOOW_HERMES_BIND=127.0.0.1` by default now).

`tree/` is the *older upstream layout*: `deploy/`, `docker/` and `config/` where the repository now
has `quadlet/`, `container/` and `scripts/`. Two distinct bodies of work live in it:

1. **The compose deployment** — `deploy/podman/deploy.sh` (generates `.env` with
   `openssl rand`, brings the stack up, then reaches into the running container with
   `podman exec`), `podman-compose.yml`, and `docker/Dockerfile.hermes-agent` +
   `docker/build-image.sh` (the custom image: CLI tools, Chromium/Playwright on top of the
   upstream base).
2. **k3s operational tooling that was never about podman at all** —
   `config/deploy-and-test.sh` (17 KB: deploys a Hermes instance into a `kubectl` namespace and
   runs a full PASS/FAIL acceptance suite against it), `config/post-deploy-setup.sh` (applies the
   golden config to a fresh instance) and `config/apply-env-fingerprint-patch.py` (patches the
   WebUI's `config.py` so the models cache is invalidated when `.env` changes). These reference
   `--context=woow-k3s` namespaces, not podman, and exist in no other repository.

## Relation to the current repository / 與現行倉庫的關係

| Then (`tree/`) | Now (repository root) |
|---|---|
| `deploy/podman/podman-compose.yml` | `quadlet/hermes-*.container`, `*.volume`, `hermes.network` |
| `deploy/podman/deploy.sh` (+ `podman exec` into the image) | `scripts/install.sh`, `upgrade.sh`, `uninstall.sh`; everything baked into `container/Containerfile` |
| `docker/Dockerfile.hermes-agent` (`FROM …:latest`) | `container/Containerfile` (`HERMES_BASE` pinned by digest) |
| `.env` / `deploy/podman/.env` with real values | `config/hermes.env.example` → `~/.config/`, database password via `POSTGRES_PASSWORD_FILE` |
| `0.0.0.0` publishing | `WOOW_HERMES_BIND=127.0.0.1` |

`tests/lint-repo.sh` now actively fails if a root-level `deploy/` directory or a compose file comes
back (decision D1), and if a script writes into the image layer with `podman exec`. Both of those
rules exist *because of* the tree preserved here. The D1 check was scoped in this change to skip
`archive/` — see below.

## What looks reusable / 可再利用之處

`tree/` contains **no test fixtures and no captured podman output** — this repository's
compose-era work had no test suite, which is itself part of the record. The reusable material is
operational:

* `tree/config/deploy-and-test.sh` — a 17 KB acceptance runner with a real PASS/FAIL tally over a
  deployed instance (health endpoints, database, redis, dashboard auth, model routes, skills).
  Nothing equivalent exists in the current repository; `tests/smoke.sh` is much thinner. The
  *structure* is reusable even though the `kubectl` transport is not.
* `tree/config/apply-env-fingerprint-patch.py` — the models-cache fingerprint fix. The current
  `container/fix-model-routes.py` is a sibling of this and is already on `main`; this one is not,
  and the bug it fixes (a stale models cache surviving an `.env` change) is the same class as the
  "Configure Pi shows only Default" problem seen elsewhere in the fleet.
* `tree/deploy/podman/SKILL.md` — the agent-facing deployment skill for the compose stack.

**Assessment: none of this should be wired into the current tests as-is** — it targets a compose
and k3s deployment, not the Quadlet one, and `deploy-and-test.sh` mutates a live namespace, which
the current CI rules forbid. The one concrete follow-up is to lift the acceptance *case list* from
`deploy-and-test.sh` into `tests/smoke.sh`. **Deliberately not done in this change** —
preservation first.

## What was excluded / 已排除的內容

No preserved file was modified; files that could not be preserved were dropped whole rather than
edited, so nothing under `tree/` is a partial or doctored version of a host file.

**Excluded for secrets (1 file)**

* `deploy/podman/.env` — the live environment file. It carried **real values** for
  `OPENROUTER_API_KEY` (an `sk-…` key, 73 chars), `GITHUB_TOKEN` (a `ghp_…` personal access token,
  40 chars), `API_SERVER_KEY` (64 hex), `WEBHOOK_SECRET` (64 hex), `POSTGRES_PASSWORD` (24 chars)
  and `DASHBOARD_PASSWORD` (8 chars). **Every one of those should be treated as disclosed and
  rotated.** No redacted copy was committed because it would add nothing: its `.env.example` twin,
  `tree/deploy/podman/.env.example`, is preserved and carries the identical key list with
  placeholder values, and `tree/deploy/podman/deploy.sh` shows how each was generated.

**Excluded as worthless (0 files).**

**Excluded as already present (21 files)** — byte-identical to files already on `main`:
`config/golden-config.yaml`, `config/golden-settings.json`, `config/fix-model-routes.py`,
`deploy/podman/patches/iss-callback.py`, `deploy/podman/patches/iss-permissive.py`,
`docs/api-contract.md`, `docs/user-manual-zh-TW.md`, the eleven `docs/screenshots/*.png`,
`docs/screenshots/k3s-pods.txt`, `.github/CODEOWNERS` and `skills/playwright-browser-SKILL.md`.

A value-shaped secret scan over `tree/` (GitHub PATs, `sk-` keys, Slack tokens, AWS key ids, PEM
private keys and certificates, JWTs, tailscale/headscale auth keys, bcrypt and crypt hashes, and
non-placeholder `*PASSWORD|SECRET|TOKEN|_KEY=` assignments) reports **0 hits**. Five lines matched
the assignment pattern and were confirmed by hand to be `sed` expressions that *write*
`$(openssl rand …)` into a generated `.env`, and a `${DASHBOARD_PASSWORD:-admin}` compose default —
no values. That weak `admin` default is preserved as-is because it is part of the record; it is
not a default the current Quadlet deployment has.
