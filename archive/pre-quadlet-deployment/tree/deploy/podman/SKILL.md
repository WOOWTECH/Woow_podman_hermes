# Hermes Agent Podman 部署 Skill

## 快速部署
```bash
bash deploy.sh    # 首次生成 .env，編輯 MINIMAX_API_KEY 後再執行
```

## 10 步自動化（v0.17.0，單容器）
1. 生成 .env | 2. 啟動容器 | 3. Hermes CLI + 清理 | 4. ddgs 網搜
5. OfficeCLI | 6. TUI PVC 權限（`HERMES_TUI_DIR`） | 7. tmux
8. Superpowers | 9. Config 優化 | 10. 清 cache

## 唯一 GUI — Dashboard
- Dashboard http://localhost:19119 (Chat TUI + 設定 + API Keys + MCP + Terminal)

Chat TUI 為唯一 chat 介面；跑在 hermes-agent 容器中，具備完整 ffmpeg / edge-tts / rclone / playwright / node / hermes CLI。

## 注意
- Image 需全名: `docker.io/library/postgres:15`
- 首次 config 可能是 anthropic，deploy.sh Step 8 自動修正為 MiniMax
- Token Plan key 使用 `sk-cp-` prefix

## Known Issues & Fixes

| 問題 | 原因 | 修復方式 |
|------|------|----------|
| Dashboard TUI "No API key configured" | TUI 讀取 `.env` 檔案，非容器環境變數 | 部署腳本寫入 `MINIMAX_API_KEY` 到 `.env` |
| Dashboard TUI 重啟後壞掉 | image layer `ui-tui/` 權限被重設 | `HERMES_TUI_DIR=/opt/data/ui-tui` 從 PVC 讀取 |

## 已驗證 K3s 對照 100/100 一致

---

## Odoo 自動貼文排程系統配置

部署 Hermes 後如需連接 Odoo 執行自動貼文生成，按以下步驟設定。

### 排程配置（5 個 Cron Jobs）

在 Dashboard 左側 Cron 頁面建立（或以 `hermes cron add`）：

| 名稱 | 頻率 | 模式 | 腳本 |
|------|------|------|------|
| 自動貼文生成（7角色×2則/時） | `0 * * * *` | no-agent | `run_posts.sh` |
| 草稿自動搬移（草稿→製作中） | `30 * * * *` | no-agent | `move_drafts.sh` |
| 系統心跳檢查 | every 30m | agent | — |
| Odoo 連線檢查 | every 30m | agent | — |
| Shell 環境檢查 | every 30m | agent | — |

### 腳本部署

腳本放在 `HERMES_HOME/scripts/`（PVC 持久化）：

```
scripts/
├── daily_posts_full.py    # 主腳本：RSS新聞→AI生成→Odoo寫入
├── move_drafts.py         # 搬移草稿到製作中
├── run_posts.sh           # daily_posts 包裝
├── move_drafts.sh         # move_drafts 包裝
└── webhook_receiver.py    # Webhook 接收器
```

### Odoo 自訂欄位

在 project.task 上建立 5 個 html 欄位：

| 欄位名稱 | 標籤 |
|---------|------|
| `x_tab_voiceover` | 🎤 配音稿 |
| `x_tab_text_prompt` | ✍ 貼文提示 |
| `x_tab_image_prompt` | 🎨 圖片提示 |
| `x_tab_video_prompt` | 🎬 影片提示 |
| `x_tab_final_post` | 📱 成品貼文 |

建立後需新增 `ir.ui.view` 繼承 `project.task.form`，加入 notebook pages 顯示這 5 個分頁。

### 環境變數

```bash
MINIMAX_API_KEY=sk-cp-...   # MiniMax API（Token Plan）
```

### 品質門檻

```python
MIN_LENGTHS = {
    "voiceover": 300,    # 配音稿最低字數
    "text_prompt": 100,
    "image_prompt": 100,
    "video_prompt": 100,
    "description": 100,
}
```

### 已知排程問題與修復

| 問題 | 根因 | 修復 |
|------|------|------|
| move_drafts 永遠 "No eligible" | `final_post=False` 過濾條件與 `assemble_final_post()` 衝突 | 移除 `final_post=False` 條件 |
| 韭菜觀察局 ERR | MiniMax 內容審核拒絕敏感詞 | 加入 DEBUG 日誌 + 延長重試間隔 |
| WARN 率 ~8% | `image_prompt` 門檻過高 + patch 只在首次重試 | 門檻 120→100 + 每次 attempt 都 patch |
| MoneyDJ RSS 遺失 | 只在 Hermes chat 加了但程式碼沒同步 | 加入第 5 個 RSS 源 |

### 日誌

```
貼文生成: /opt/data/cron/output/posts.log
草稿搬移: /opt/data/cron/output/move_drafts.log
```

### Cloudflare Tunnel 注意（K3s 對照）

v0.17.0 起 K3s 側只需暴露 Dashboard：
```
hostname: <tenant>-dashboard.woowtech.io → hermes-agent-svc:9119
```
不再有 `<tenant>-hermes.woowtech.io` → `hermes-webui-svc:8787` 這條 route。
