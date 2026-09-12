# Contributing to Woow Hermes Agent

## Repository Isolation Policy

> **CRITICAL**: This repository MUST be managed from a dedicated local clone.
> Never add this repo as a remote to another project's local repository.

### Background

In March 2026, this repository was accidentally polluted when it was added as a
secondary remote to the OpenClaw monorepo. Running `git push hermes k3s` pushed
the entire OpenClaw branch (including `openclaw-k3s-paas/`, `setup-wizard/`,
`Dockerfile.nerve`, etc.) to this repository.

### Rules

1. **One repo = one local clone**
   ```bash
   # CORRECT — dedicated clone
   git clone https://github.com/WOOWTECH/Woow_podman_hermes.git ~/repos/hermes
   cd ~/repos/hermes

   # WRONG — adding as remote to OpenClaw
   cd ~/repos/openclaw
   git remote add hermes https://github.com/WOOWTECH/Woow_podman_hermes.git
   git push hermes k3s  # ← THIS WILL POLLUTE HERMES WITH OPENCLAW FILES
   ```

2. **Install the pre-push hook** (optional safety net)
   ```bash
   cp .github/hooks/pre-push .git/hooks/pre-push
   chmod +x .git/hooks/pre-push
   ```

3. **CI guard** — The `repo-guard.yml` GitHub Action automatically checks every
   push and PR for OpenClaw/OpenDesign pollution markers. If foreign files are
   detected, the CI will fail.

### What belongs in this repo

| Directory | Content |
|-----------|---------|
| `quadlet/` | The Quadlet units (`.container`, `.volume`, `.network`) and `render-vars` |
| `systemd/` | Plain user units, currently `hermes-provision.service` |
| `container/` | The image build context: `Containerfile`, patches, `rootfs/` |
| `config/` | `hermes.env.example` and the golden reference configs |
| `scripts/` | `install.sh`, `upgrade.sh`, `uninstall.sh`, `backup.sh`, `restore.sh`, `build-image.sh` |
| `scripts/lib/` | The vendored `quadlet-lib.sh`. **Do not edit it here** — it is synced from the shared library and CI checks its hash against `quadlet-lib.manifest`. |
| `tests/` | `dryrun.sh`, `smoke.sh`, `lint-repo.sh`, `patch-anchors.sh` |
| `docs/` | Screenshots, user manual, API contract, Odoo posting notes |
| `skills/` | Hermes skill definitions |

Kubernetes manifests live in `Woow_k3s_hermes`, not here. The compose deployment was removed in
`0.20.0-quadlet`; its last version is on the `compose-final` tag.

### Before you open a PR

```bash
tests/dryrun.sh                                          # render + Quadlet dry-run + systemd-analyze
tests/lint-repo.sh                                       # credentials, image pins, no live mutation
shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh
```

`.github/workflows/quadlet-ci.yml` runs the same three on `ubuntu-24.04`.

### What does NOT belong

- `openclaw-*` — OpenClaw directories
- `setup-wizard/` — OpenClaw setup wizard
- `Dockerfile.nerve`, `Dockerfile.custom` — OpenClaw images
- `openclaw-console/` — OpenClaw console
- `.claude/epics/` — OpenClaw CI planning artifacts
- `k8s-manifests/` at root level — OpenClaw manifests (Hermes k3s manifests live in `Woow_k3s_hermes`)

---

## 倉庫隔離政策

> **重要**：此倉庫必須使用獨立的本地 clone 管理。
> 絕對不要將此倉庫作為其他專案的附加 remote。

### 規則

1. **一個 GitHub repo = 一個本地 clone**
2. **安裝 pre-push hook** 作為安全防線
3. **CI 自動檢查** — 每次 push/PR 都會自動偵測跨倉庫污染
