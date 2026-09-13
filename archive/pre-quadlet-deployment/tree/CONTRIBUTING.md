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
   git clone https://github.com/WOOWTECH/Woow_hermes_agent_docker_compose_all.git ~/repos/hermes
   cd ~/repos/hermes

   # WRONG — adding as remote to OpenClaw
   cd ~/repos/openclaw
   git remote add hermes https://github.com/WOOWTECH/Woow_hermes_agent_docker_compose_all.git
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
| `deploy/k3s/` | K3s deployment scripts and manifests |
| `deploy/podman/` | Podman deployment scripts and compose |
| `config/` | Golden configs, model routes, env patches |
| `docker/` | Custom Hermes Agent Dockerfile |
| `branding/` | Per-instance branding assets |
| `instances/` | Multi-instance registry and configs |
| `tests/` | Test suites and reports |
| `docs/` | Screenshots, user manual, API docs |
| `skills/` | Hermes skill definitions |

### What does NOT belong

- `openclaw-*` — OpenClaw directories
- `setup-wizard/` — OpenClaw setup wizard
- `Dockerfile.nerve`, `Dockerfile.custom` — OpenClaw images
- `openclaw-console/` — OpenClaw console
- `.claude/epics/` — OpenClaw CI planning artifacts
- `k8s-manifests/` at root level — OpenClaw manifests (Hermes uses `deploy/k3s/manifests/`)

---

## 倉庫隔離政策

> **重要**：此倉庫必須使用獨立的本地 clone 管理。
> 絕對不要將此倉庫作為其他專案的附加 remote。

### 規則

1. **一個 GitHub repo = 一個本地 clone**
2. **安裝 pre-push hook** 作為安全防線
3. **CI 自動檢查** — 每次 push/PR 都會自動偵測跨倉庫污染
