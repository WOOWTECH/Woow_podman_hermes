# Odoo 自動貼文排程 / Odoo posting automation

Notes for the WOOWTECH deployment that drives Odoo posts from Hermes cron jobs. They are operational
notes, not part of the install: the scripts live in the agent's data volume under
`/opt/data/scripts/`, which survives restarts and upgrades.

本頁為以 Hermes cron 驅動 Odoo 自動貼文的維運筆記，非安裝流程的一部分；腳本放在 agent 資料卷的
`/opt/data/scripts/`，重啟與升級都會保留。

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
MINIMAX_API_KEY=<your MiniMax token-plan key>   # 放在 ~/.config/hermes/hermes.env，不要放在這裡
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
