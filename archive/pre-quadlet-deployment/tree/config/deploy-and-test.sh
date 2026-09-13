#!/bin/bash
set -euo pipefail

# =============================================================
# Hermes 全自動部署 + 全面測試腳本
# 使用方式:
#   ./deploy-and-test.sh <namespace> [kubectl-context]
# 範例:
#   ./deploy-and-test.sh newclient-hermes woow-k3s
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${1:?Usage: $0 <namespace> [context]}"
CTX="${2:-woow-k3s}"
KC="kubectl --context=$CTX -n $NS"
KC_NONAMESPACE="kubectl --context=$CTX"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0
RESULTS=""

p() { ((PASS++)); ((TOTAL++)); RESULTS="${RESULTS}PASS|$1\n"; echo -e "  ${GREEN}PASS${NC}: $1"; }
f() { ((FAIL++)); ((TOTAL++)); RESULTS="${RESULTS}FAIL|$1|$2\n"; echo -e "  ${RED}FAIL${NC}: $1 -- $2"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
section() { echo ""; echo "============================================================"; echo "  $1"; echo "============================================================"; }

# Get reference secrets from hermes namespace
REF_NS="hermes"
MINIMAX_KEY=$($KC_NONAMESPACE -n $REF_NS get secret hermes-secrets -o jsonpath='{.data.MINIMAX_API_KEY}' 2>/dev/null | base64 -d)
API_SERVER_KEY=$($KC_NONAMESPACE -n $REF_NS get secret hermes-secrets -o jsonpath='{.data.API_SERVER_KEY}' 2>/dev/null | base64 -d)

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Hermes 全自動部署 + 全面測試                                 ║"
echo "║  Namespace: $NS"
echo "║  Context: $CTX"
echo "╚══════════════════════════════════════════════════════════════╝"

# ─────────────────────────────────────────────────
# PHASE 1: DEPLOY
# ─────────────────────────────────────────────────
section "Phase 1: Deploy ($NS)"

info "Creating namespace..."
$KC_NONAMESPACE apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    app.kubernetes.io/part-of: hermes
EOF

info "Creating secrets..."
$KC create secret generic hermes-secrets \
  --from-literal=MINIMAX_API_KEY="$MINIMAX_KEY" \
  --from-literal=API_SERVER_KEY="$API_SERVER_KEY" \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 12)" \
  --dry-run=client -o yaml | $KC apply -f -

$KC create secret generic cf-secrets \
  --from-literal=CF_API_TOKEN="placeholder" \
  --from-literal=CF_TUNNEL_TOKEN="placeholder" \
  --dry-run=client -o yaml | $KC apply -f -

info "Creating ServiceAccount..."
$KC create serviceaccount hermes-agent-sa --dry-run=client -o yaml | $KC apply -f -

info "Creating PVC..."
$KC apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-webui-data
  namespace: $NS
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
EOF

info "Deploying combined hermes pod..."
sed "s|__NAMESPACE__|$NS|g" /tmp/hermes-combined-deploy-template.yaml 2>/dev/null | $KC apply -f - || \
  $KC_NONAMESPACE -n $REF_NS get deploy hermes -o json | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['metadata']['namespace'] = '$NS'
for k in ['resourceVersion','uid','creationTimestamp','generation']:
    d['metadata'].pop(k, None)
d['metadata']['annotations'] = {}
d.pop('status', None)
json.dump(d, sys.stdout)
" | $KC apply -f -

info "Creating services..."
for SVC in hermes-agent-svc hermes-webui-svc hermes-postgresql-svc hermes-redis-svc; do
  $KC_NONAMESPACE -n $REF_NS get svc $SVC -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['metadata']['namespace'] = '$NS'
for k in ['resourceVersion','uid','creationTimestamp']:
    d['metadata'].pop(k, None)
d['spec'].pop('clusterIP', None)
d['spec'].pop('clusterIPs', None)
d['spec']['selector'] = {'app': 'hermes'}
json.dump(d, sys.stdout)
" | $KC apply -f - 2>/dev/null
done

info "Waiting for pod to be ready (max 3 min)..."
$KC rollout status deploy/hermes --timeout=180s 2>&1 | tail -1

info "Running post-deploy setup..."
bash "$SCRIPT_DIR/post-deploy-setup.sh" "$NS" "$CTX"

# ─────────────────────────────────────────────────
# PHASE 2: COMPREHENSIVE TESTS
# ─────────────────────────────────────────────────
section "Phase 2: Comprehensive Tests (34 checks)"

# --- 2.1 Pod Health ---
section "2.1 Pod Health (5 tests)"

POD_STATUS=$($KC get pod -l app=hermes --no-headers 2>/dev/null | grep -v Terminating | awk '{print $2, $3}')
[[ "$POD_STATUS" == "2/2 Running" ]] && p "Pod 2/2 Running" || f "Pod status" "$POD_STATUS"

CONTAINERS=$($KC get pod -l app=hermes -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null)
echo "$CONTAINERS" | grep -q "hermes-agent" && p "Agent container exists" || f "Agent container" "missing"
echo "$CONTAINERS" | grep -q "hermes-webui" && p "WebUI container exists" || f "WebUI container" "missing"

AGENT_READY=$($KC get pod -l app=hermes -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="hermes-agent")].ready}' 2>/dev/null)
[[ "$AGENT_READY" == "true" ]] && p "Agent container ready" || f "Agent ready" "$AGENT_READY"

WEBUI_READY=$($KC get pod -l app=hermes -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="hermes-webui")].ready}' 2>/dev/null)
[[ "$WEBUI_READY" == "true" ]] && p "WebUI container ready" || f "WebUI ready" "$WEBUI_READY"

# --- 2.2 Config & Settings ---
section "2.2 Config & Settings (6 tests)"

CONFIG_LINES=$($KC exec deploy/hermes -c hermes-agent -- wc -l /opt/data/config.yaml 2>/dev/null | awk '{print $1}')
[[ "$CONFIG_LINES" -ge 400 ]] && p "Golden config applied ($CONFIG_LINES lines)" || f "Config" "only $CONFIG_LINES lines"

CRON_MODE=$($KC exec deploy/hermes -c hermes-agent -- grep "cron_mode" /opt/data/config.yaml 2>/dev/null | awk '{print $2}')
[[ "$CRON_MODE" == "auto" ]] && p "cron_mode=auto" || f "cron_mode" "$CRON_MODE"

HIDDEN=$($KC exec deploy/hermes -c hermes-webui -- python3 -c "import json; print(json.load(open('/home/hermeswebui/.hermes/webui/settings.json')).get('hidden_tabs',[]))" 2>/dev/null)
echo "$HIDDEN" | grep -q "kanban" && echo "$HIDDEN" | grep -q "todos" && p "hidden_tabs: kanban+todos" || f "hidden_tabs" "$HIDDEN"

CSS=$($KC exec deploy/hermes -c hermes-webui -- grep -c "HIDE_KANBAN_TODOS" /app/static/index.html 2>/dev/null)
[[ "$CSS" -ge 1 ]] && p "CSS injection active" || f "CSS injection" "missing"

SOUL_SIZE=$($KC exec deploy/hermes -c hermes-webui -- wc -c /home/hermeswebui/.hermes/SOUL.md 2>/dev/null | awk '{print $1}')
[[ "${SOUL_SIZE:-0}" -ge 50 ]] && p "SOUL.md exists (${SOUL_SIZE}B)" || f "SOUL.md" "empty or missing"

GW=$($KC exec deploy/hermes -c hermes-webui -- python3 -c "import json; print(json.load(open('/home/hermeswebui/.hermes/gateway_state.json')).get('gateway_state','?'))" 2>/dev/null)
[[ "$GW" == "running" ]] && p "Gateway state: running" || f "Gateway state" "$GW"

# --- 2.3 API Connectivity ---
section "2.3 API Connectivity (4 tests)"

API_KEY=$($KC_NONAMESPACE -n $NS get secret hermes-secrets -o jsonpath='{.data.API_SERVER_KEY}' 2>/dev/null | base64 -d)

MODELS=$($KC exec deploy/hermes -c hermes-agent -- curl -s --max-time 10 \
  -H "Authorization: Bearer $API_KEY" http://localhost:8642/v1/models 2>/dev/null)
echo "$MODELS" | grep -q "hermes-agent" && p "Agent API /v1/models responds" || f "Agent API" "no response"

WEBUI_HTTP=$($KC exec deploy/hermes -c hermes-webui -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8787/ 2>/dev/null)
[[ "$WEBUI_HTTP" =~ ^[23] ]] && p "WebUI HTTP $WEBUI_HTTP" || f "WebUI HTTP" "$WEBUI_HTTP"

GW_FROM_WEBUI=$($KC exec deploy/hermes -c hermes-webui -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  -H "Authorization: Bearer $API_KEY" http://localhost:8642/v1/models 2>/dev/null)
[[ "$GW_FROM_WEBUI" == "200" ]] && p "WebUI→Agent gateway: 200" || f "WebUI→Agent" "$GW_FROM_WEBUI"

GW_KEY_ENV=$($KC exec deploy/hermes -c hermes-webui -- sh -c 'test -n "$HERMES_WEBUI_GATEWAY_API_KEY" && echo ok' 2>/dev/null)
[[ "$GW_KEY_ENV" == "ok" ]] && p "HERMES_WEBUI_GATEWAY_API_KEY set" || f "Gateway API key" "missing in WebUI env"

# --- 2.4 LLM Chat ---
section "2.4 LLM Chat (3 tests)"

CHAT_RESP=$($KC exec deploy/hermes -c hermes-agent -- curl -s --max-time 30 \
  -X POST http://localhost:8642/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"minimax/MiniMax-M2.7","messages":[{"role":"user","content":"Reply with exactly: PING OK"}],"max_tokens":20}' 2>/dev/null)
echo "$CHAT_RESP" | grep -qi "PING\|OK\|ping" && p "LLM chat responds" || f "LLM chat" "no valid response"

CHAT_CHINESE=$($KC exec deploy/hermes -c hermes-agent -- curl -s --max-time 30 \
  -X POST http://localhost:8642/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"minimax/MiniMax-M2.7","messages":[{"role":"user","content":"用一個字回答：1+1等於幾？"}],"max_tokens":10}' 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null)
echo "$CHAT_CHINESE" | grep -q "2\|二\|兩" && p "LLM Chinese: $CHAT_CHINESE" || f "LLM Chinese" "$CHAT_CHINESE"

CHAT_SOUL=$($KC exec deploy/hermes -c hermes-agent -- curl -s --max-time 30 \
  -X POST http://localhost:8642/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"minimax/MiniMax-M2.7","messages":[{"role":"user","content":"What is your name? 1 word only."}],"max_tokens":20}' 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'][:50])" 2>/dev/null)
[[ -n "$CHAT_SOUL" ]] && p "LLM identity: $CHAT_SOUL" || f "LLM identity" "empty"

# --- 2.5 SOUL.md Effect ---
section "2.5 SOUL.md Effect (2 tests)"

ORIGINAL_SOUL=$($KC exec deploy/hermes -c hermes-webui -- cat /home/hermeswebui/.hermes/SOUL.md 2>/dev/null)

$KC exec deploy/hermes -c hermes-webui -- sh -c 'cat > /home/hermeswebui/.hermes/SOUL.md << "EOF"
# 身份
你是一個海盜船長 AI，名叫 Captain Redbeard。你說話用海盜口吻，用「Arrr」開頭。
EOF'

PIRATE=$($KC exec deploy/hermes -c hermes-agent -- curl -s --max-time 30 \
  -X POST http://localhost:8642/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"minimax/MiniMax-M2.7","messages":[{"role":"user","content":"Say hello in your style, 1 sentence."}],"max_tokens":50}' 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'][:100])" 2>/dev/null)

echo "$PIRATE" | grep -qi "arrr\|pirate\|captain\|海盜\|船長\|紅鬍子\|Redbeard" && p "SOUL change: pirate detected ($PIRATE)" || f "SOUL change" "no pirate: $PIRATE"

echo "$ORIGINAL_SOUL" | $KC exec -i deploy/hermes -c hermes-webui -- sh -c 'cat > /home/hermeswebui/.hermes/SOUL.md'

RESTORED=$($KC exec deploy/hermes -c hermes-agent -- curl -s --max-time 30 \
  -X POST http://localhost:8642/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"minimax/MiniMax-M2.7","messages":[{"role":"user","content":"Who are you? 1 sentence."}],"max_tokens":50}' 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'][:100])" 2>/dev/null)
echo "$RESTORED" | grep -qvi "pirate\|captain\|arrr" && p "SOUL restored: $RESTORED" || f "SOUL restore" "still pirate: $RESTORED"

# --- 2.6 Skill Toggle ---
section "2.6 Skill Toggle (2 tests)"

SKILLS_COUNT=$($KC exec deploy/hermes -c hermes-agent -- find /opt/data/skills -name "SKILL.md" 2>/dev/null | wc -l)
[[ "$SKILLS_COUNT" -ge 85 ]] && p "Skills loaded: $SKILLS_COUNT" || f "Skills count" "$SKILLS_COUNT"

SKILLS_WEBUI=$($KC exec deploy/hermes -c hermes-webui -- find /home/hermeswebui/.hermes/skills -name "SKILL.md" 2>/dev/null | wc -l)
[[ "$SKILLS_WEBUI" -ge 85 ]] && p "WebUI skills: $SKILLS_WEBUI" || f "WebUI skills" "$SKILLS_WEBUI"

# --- 2.7 Cron Scheduler ---
section "2.7 Cron Scheduler (4 tests)"

CRON_JOBS=$($KC exec deploy/hermes -c hermes-webui -- python3 -c "import json; print(len(json.load(open('/home/hermeswebui/.hermes/cron/jobs.json')).get('jobs',[])))" 2>/dev/null)
[[ "$CRON_JOBS" -ge 1 ]] && p "Cron jobs: $CRON_JOBS" || f "Cron jobs" "$CRON_JOBS"

CRON_PERMS=$($KC exec deploy/hermes -c hermes-agent -- stat -c "%a" /opt/data/cron/jobs.json 2>/dev/null)
[[ "$CRON_PERMS" == "666" || "$CRON_PERMS" == "664" || "$CRON_PERMS" == "644" ]] && p "Cron perms: $CRON_PERMS" || f "Cron perms" "$CRON_PERMS"

TICK=$($KC exec deploy/hermes -c hermes-agent -- stat -c "%Y" /opt/data/cron/.tick.lock 2>/dev/null)
NOW=$(date +%s)
AGE=$((NOW - ${TICK:-0}))
[[ "$AGE" -lt 300 ]] && p "Scheduler ticking (${AGE}s ago)" || f "Scheduler tick" "${AGE}s old"

CRON_ERR=$($KC logs deploy/hermes -c hermes-agent --tail=100 2>/dev/null | grep -c "Permission denied.*jobs.json" || true 2>/dev/null)
[[ "$CRON_ERR" -eq 0 ]] && p "No cron permission errors" || f "Cron errors" "$CRON_ERR found in logs"

# --- 2.8 Persistence ---
section "2.8 Persistence (2 tests)"

VOLUME=$($KC get pod -l app=hermes -o jsonpath='{.items[0].spec.volumes[?(@.name=="hermes-data")].persistentVolumeClaim.claimName}' 2>/dev/null)
[[ "$VOLUME" == "hermes-webui-data" ]] && p "PVC: $VOLUME" || f "PVC" "$VOLUME"

PVC_STATUS=$($KC get pvc hermes-webui-data -o jsonpath='{.status.phase}' 2>/dev/null)
[[ "$PVC_STATUS" == "Bound" ]] && p "PVC Bound" || f "PVC phase" "$PVC_STATUS"

# --- 2.9 WebUI Frontend ---
section "2.9 WebUI Frontend (2 tests)"

LOGIN_PAGE=$($KC exec deploy/hermes -c hermes-webui -- curl -s --max-time 5 http://localhost:8787/ 2>/dev/null | head -5)
echo "$LOGIN_PAGE" | grep -qi "hermes\|password\|sign" && p "Login page renders" || f "Login page" "unexpected content"

BACKEND=$($KC exec deploy/hermes -c hermes-webui -- sh -c 'echo $HERMES_WEBUI_CHAT_BACKEND' 2>/dev/null)
[[ "$BACKEND" == "gateway" ]] && p "Chat backend: gateway" || f "Chat backend" "$BACKEND"

# --- 2.10 Branding (4 injection points) ---
section "2.10 Branding (4 tests)"

# Check if branding script exists on PVC
BRANDING=$($KC exec deploy/hermes -c hermes-webui -- test -f /home/hermeswebui/.hermes/apply_branding.py && echo "yes" 2>/dev/null)
[[ "$BRANDING" == "yes" ]] && p "apply_branding.py exists" || f "apply_branding.py" "missing from PVC"

# Check empty-logo replacement in index.html (must NOT contain gold caduceus, MUST contain custom SVG)
EMPTY_LOGO=$($KC exec deploy/hermes -c hermes-webui -- grep -c 'empty-logo.*svg\|empty-logo.*path' /app/static/index.html 2>/dev/null)
[[ "${EMPTY_LOGO:-0}" -ge 1 ]] && p "Empty-state logo branded" || f "Empty-state logo" "still default caduceus"

# Check CSS hide-tabs injection
CSS_HIDE=$($KC exec deploy/hermes -c hermes-webui -- grep -c "HIDE_KANBAN_TODOS" /app/static/index.html 2>/dev/null)
[[ "${CSS_HIDE:-0}" -ge 1 ]] && p "CSS tab-hide injected" || f "CSS tab-hide" "missing from index.html"

# Check replace_icons.sh is wired into hermeswebui_init.bash
INIT_HOOK=$($KC exec deploy/hermes -c hermes-webui -- grep -c "replace_icons" /hermeswebui_init.bash 2>/dev/null)
[[ "${INIT_HOOK:-0}" -ge 1 ]] && p "replace_icons.sh in init.bash" || f "Init hook" "replace_icons.sh not injected into init.bash"

# ─────────────────────────────────────────────────
# PHASE 3: REPORT
# ─────────────────────────────────────────────────
section "FINAL REPORT"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  Pass: $PASS  |  Fail: $FAIL  |  Total: $TOTAL"
if [[ $TOTAL -gt 0 ]]; then
  RATE=$((PASS * 100 / TOTAL))
  echo "  ║  Pass Rate: ${RATE}%"
fi
echo "  ╚══════════════════════════════════════╝"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "  Failed tests:"
  echo -e "$RESULTS" | grep "^FAIL" | while IFS='|' read -r _ name detail; do
    echo "    ✗ $name: $detail"
  done
fi

echo ""
echo "  Instance: $NS"
echo "  Context: $CTX"
echo ""

exit $FAIL
