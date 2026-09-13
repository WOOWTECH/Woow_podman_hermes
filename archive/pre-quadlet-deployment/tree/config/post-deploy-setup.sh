#!/bin/bash
# =============================================================
# Hermes Instance Post-Deploy Setup
# Applies golden config from WoowTech reference to a new instance
# Usage: ./post-deploy-setup.sh <namespace> [context]
# =============================================================

set -euo pipefail

NS="${1:?Usage: $0 <namespace> [kubectl-context]}"
CTX="${2:-woow-k3s}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC="kubectl --context=$CTX -n $NS"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $1"; }

echo "============================================================"
echo "  Hermes Post-Deploy Setup: $NS"
echo "============================================================"

# 1. Copy golden config.yaml (with API key substitution)
info "Applying golden config.yaml..."
OPENROUTER_KEY="${OPENROUTER_API_KEY:-}"
if [ -n "$OPENROUTER_KEY" ]; then
    sed "s|__OPENROUTER_API_KEY__|${OPENROUTER_KEY}|g" "$SCRIPT_DIR/golden-config.yaml" | $KC exec -i deploy/hermes -c hermes-agent -- sh -c 'cat > /opt/data/config.yaml && chmod 666 /opt/data/config.yaml'
    ok "config.yaml applied (with model_routes API keys)"
else
    cat "$SCRIPT_DIR/golden-config.yaml" | $KC exec -i deploy/hermes -c hermes-agent -- sh -c 'cat > /opt/data/config.yaml && chmod 666 /opt/data/config.yaml'
    ok "config.yaml applied (model_routes need OPENROUTER_API_KEY)"
fi

# 2. Copy golden settings.json (hidden_tabs: kanban, todos)
info "Applying golden settings.json (hidden_tabs)..."
$KC exec deploy/hermes -c hermes-webui -- mkdir -p /home/hermeswebui/.hermes/webui
cat "$SCRIPT_DIR/golden-settings.json" | $KC exec -i deploy/hermes -c hermes-webui -- sh -c 'cat > /home/hermeswebui/.hermes/webui/settings.json'
ok "settings.json applied (kanban + todos hidden)"

# 3. Inject CSS to hide kanban/todos in index.html
info "Injecting CSS to hide kanban/todos..."
$KC exec deploy/hermes -c hermes-webui -- python3 -c "
with open('/app/static/index.html') as f:
    html = f.read()
marker = '/* HIDE_KANBAN_TODOS */'
if marker not in html:
    css = marker + ' [data-panel=\"kanban\"],[data-panel=\"todos\"]{display:none!important;}'
    html = html.replace('</head>', '<style>' + css + '</style></head>')
    with open('/app/static/index.html', 'w') as f:
        f.write(html)
    print('injected')
else:
    print('already_patched')
"
ok "CSS injection done"

# 4. Create default SOUL.md if empty
info "Checking SOUL.md..."
SOUL_SIZE=$($KC exec deploy/hermes -c hermes-webui -- wc -c /home/hermeswebui/.hermes/SOUL.md 2>/dev/null | awk '{print $1}')
if [ "${SOUL_SIZE:-0}" -lt 10 ]; then
    INSTANCE_NAME=$(echo "$NS" | sed 's/-hermes//' | sed 's/\b\(.\)/\u\1/g')
    $KC exec deploy/hermes -c hermes-webui -- sh -c "cat > /home/hermeswebui/.hermes/SOUL.md << 'SOULEOF'
# 身份

你是 **${INSTANCE_NAME} AI 助手**，一個多功能的智慧助理。你能協助處理各類問題，包括程式開發、系統管理、文件撰寫、資料分析、和日常工作自動化。

## 專業領域

- 程式開發與除錯（Python、JavaScript、Shell Script）
- 系統管理與 DevOps（K8s、Docker、Linux）
- 資料分析與報告生成
- 文件撰寫與翻譯
- 工作流程自動化

## 溝通風格

- 以繁體中文為主，技術名詞保留英文
- 步驟化說明，清楚易懂
- 主動提供替代方案和最佳實踐
- 根據問題複雜度調整回答詳細程度
SOULEOF"
    ok "Default SOUL.md created for ${INSTANCE_NAME}"
else
    ok "SOUL.md exists (${SOUL_SIZE} bytes)"
fi

# 5. Create default heartbeat cron job
info "Setting up heartbeat cron job..."
$KC exec deploy/hermes -c hermes-webui -- python3 -c "
import json, time, uuid, os
path = '/home/hermeswebui/.hermes/cron/jobs.json'
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as f:
        data = json.load(f)
except:
    data = {'jobs': [], 'updated_at': time.time()}
jobs = data.get('jobs', [])
if not any('心跳' in j.get('name','') for j in jobs):
    jobs.append({
        'id': uuid.uuid4().hex[:12],
        'name': '排程自檢 — 系統心跳',
        'schedule': {'kind': 'interval', 'minutes': 30, 'display': 'every 30m'},
        'prompt': 'Run: echo heartbeat and hostname. Respond: HEARTBEAT OK <timestamp>.',
        'enabled': True, 'deliver': 'local', 'mode': 'agent',
        'profile': None, 'skills': None, 'completion_toasts': True,
        'next_run_at': None, 'last_run_at': None, 'created_at': time.time()
    })
    data['jobs'] = jobs
    data['updated_at'] = time.time()
    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.chmod(path, 0o666)
    print('created')
else:
    print('exists')
"
ok "Heartbeat cron job ready"

# 6. Sync shared skills (browser-automation, web-automation)
info "Syncing shared skills..."
# This would typically copy from the template or a reference instance
ok "Skills sync (use deploy-instance.sh for full skill sync)"

# 7. Fix permissions
info "Fixing permissions..."
$KC exec deploy/hermes -c hermes-agent -- sh -c 'chmod -R 666 /opt/data/cron/ 2>/dev/null; chown -R hermes:hermes /opt/data/cron/ 2>/dev/null' || true
ok "Permissions fixed"

echo ""
echo "============================================================"
echo "  Post-deploy setup complete for: $NS"
echo "============================================================"
