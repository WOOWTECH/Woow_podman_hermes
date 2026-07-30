#!/bin/bash
# Hermes Agent v0.17.0 — Podman 部署（單容器架構）
# Dashboard TUI 為唯一 chat 介面；不再部署 hermes-webui
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

echo "═══════════════════════════════════════"
echo "  Hermes Agent — Podman Deploy (Dashboard-only)"
echo "═══════════════════════════════════════"

# Step 1: Generate .env if missing
if [ ! -f "$ENV_FILE" ]; then
    cp "${SCRIPT_DIR}/.env.example" "$ENV_FILE"
    sed -i "s/^API_SERVER_KEY=.*/API_SERVER_KEY=$(openssl rand -hex 32)/" "$ENV_FILE"
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)/" "$ENV_FILE"
    sed -i "s/^HERMES_UID=.*/HERMES_UID=$(id -u)/" "$ENV_FILE"
    sed -i "s/^HERMES_GID=.*/HERMES_GID=$(id -g)/" "$ENV_FILE"
    echo "已生成 .env — 編輯 MINIMAX_API_KEY 後重新執行"
    exit 0
fi

# Step 2: Start containers
cd "$SCRIPT_DIR"
echo "Step 2: Starting containers..."
podman-compose up -d
sleep 20

# Step 3: Hermes CLI symlink + cleanup
echo "Step 3: Hermes CLI + cleanup..."
podman exec hermes-agent sh -c '
  ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes 2>/dev/null
  rm -f /usr/local/bin/argocd /usr/local/bin/helm /usr/bin/docker 2>/dev/null
  rm -rf /opt/hermes/skills/apple /opt/hermes/skills/gaming /opt/hermes/skills/email /opt/hermes/skills/social-media /opt/hermes/skills/yuanbao /opt/hermes/skills/media/heartmula /opt/hermes/skills/media/songsee /opt/hermes/skills/media/spotify /opt/hermes/skills/media/youtube-content /opt/hermes/skills/smart-home/openhue 2>/dev/null
'

# Step 4: Install ddgs web search
echo "Step 4: Install ddgs web search..."
podman exec hermes-agent sh -c '
  SITE=$(/opt/hermes/.venv/bin/python3 -c "import site;print(site.getsitepackages()[0])" 2>/dev/null)
  uv pip install --target="$SITE" ddgs 2>/dev/null
  /opt/hermes/.venv/bin/python3 -c "from ddgs import DDGS; print(\"ddgs OK\")" 2>&1 | grep OK
'

# Step 4b: Install OfficeCLI (Office document automation)
echo "Step 4b: Install OfficeCLI..."
podman exec hermes-agent sh -c '
  if [ ! -f /opt/data/officecli ]; then
    curl -L --fail -o /opt/data/officecli "https://github.com/iOfficeAI/OfficeCLI/releases/download/v1.0.135/officecli-linux-x64" 2>/dev/null
    chmod +x /opt/data/officecli
    echo "  OfficeCLI downloaded"
  fi
  ln -sf /opt/data/officecli /usr/local/bin/officecli 2>/dev/null
  export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true
  officecli --version 2>/dev/null && echo "  OfficeCLI OK" || echo "  OfficeCLI install failed"
'

# Step 5: TUI PVC fix
echo "Step 5: TUI PVC setup..."
podman exec hermes-agent sh -c '
  test -d /opt/data/ui-tui || cp -r /opt/hermes/ui-tui /opt/data/ui-tui 2>/dev/null
  chown -R hermes:hermes /opt/data/ui-tui/ 2>/dev/null || true
'

# Step 6: tmux
echo "Step 6: tmux install..."
podman exec hermes-agent sh -c 'which tmux || (apt-get update -qq && apt-get install -y -qq tmux)' 2>/dev/null

# Step 7: Superpowers skills
echo "Step 7: Superpowers skills..."
if ! podman exec hermes-agent test -f /opt/data/skills/brainstorming/SKILL.md 2>/dev/null; then
    T=$(mktemp -d)
    git clone --depth 1 https://github.com/obra/superpowers.git "$T/sp" 2>/dev/null
    tar czf "$T/sp.tar.gz" -C "$T/sp" skills/
    podman cp "$T/sp.tar.gz" hermes-agent:/tmp/
    podman exec hermes-agent tar xzf /tmp/sp.tar.gz -C /opt/data/
    rm -rf "$T"
    echo "  Superpowers installed"
fi

# Step 8: Config optimize
echo "Step 8: Config optimize..."
podman exec hermes-agent sh -c '
  # Fix approvals
  sed -i "s/mode: manual/mode: off/" /opt/data/config.yaml 2>/dev/null
  sed -i "s/cron_mode: deny/cron_mode: yolo/" /opt/data/config.yaml 2>/dev/null
  sed -i "s/hooks_auto_accept: false/hooks_auto_accept: true/" /opt/data/config.yaml 2>/dev/null
  sed -i "s/subagent_auto_approve: false/subagent_auto_approve: true/" /opt/data/config.yaml 2>/dev/null
  # Fix terminal
  sed -i "/^terminal:/,/^[a-z]/{s/  backend: auto/  backend: local/}" /opt/data/config.yaml 2>/dev/null
  # Fix web search backend
  sed -i "/^web:/,/^[a-z]/{s/  backend: .*/  backend: ddgs/}" /opt/data/config.yaml 2>/dev/null
  sed -i "/^web:/,/^[a-z]/{s/  search_backend: .*/  search_backend: ddgs/}" /opt/data/config.yaml 2>/dev/null
  # Remove toolsets restriction
  sed -i "/^toolsets:/d" /opt/data/config.yaml 2>/dev/null
  sed -i "/^- hermes-cli$/d" /opt/data/config.yaml 2>/dev/null
  sed -i "/^  - hermes-cli$/d" /opt/data/config.yaml 2>/dev/null
  # Write .env for TUI
  echo "MINIMAX_API_KEY=$(printenv MINIMAX_API_KEY)" > /opt/data/.env
  echo "OPENROUTER_API_KEY=$(printenv OPENROUTER_API_KEY)" >> /opt/data/.env
  # Enable extra toolsets
  hermes tools enable video 2>/dev/null | tail -1
  hermes tools enable moa 2>/dev/null | tail -1
  hermes tools enable context_engine 2>/dev/null | tail -1
  hermes tools enable homeassistant 2>/dev/null | tail -1
  # Enable plugins
  hermes plugins enable disk-cleanup 2>/dev/null | tail -1
  hermes plugins enable security-guidance 2>/dev/null | tail -1
  echo "  Config optimized"
'

# Step 9: Model routing fix (@openai: prefix support)
echo "Step 9: Model routing fix..."
podman cp "${SCRIPT_DIR}/../../config/fix-model-routes.py" hermes-agent:/tmp/fix-model-routes.py 2>/dev/null || true
podman exec hermes-agent python3 /tmp/fix-model-routes.py 2>/dev/null || echo "  (model routes: no model_routes section yet)"

# Step 10: Clear caches
echo "Step 10: Clear caches..."
podman exec hermes-agent sh -c 'rm -f /opt/data/.skills_prompt_snapshot.json /opt/data/skills/.bundled_manifest /opt/data/provider_models_cache.json /opt/data/models_dev_cache.json'

echo ""
echo "═══════════════════════════════════════"
echo "  部署完成！Hermes Agent (Dashboard-only)"
echo "═══════════════════════════════════════"
echo "  Dashboard: http://localhost:19119   (Chat TUI + Config + MCP)"
echo "  Gateway:   http://localhost:18642"
echo "  密碼:      admin (Dashboard basic-auth)"
echo "═══════════════════════════════════════"
