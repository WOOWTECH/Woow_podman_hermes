# Woow Hermes Agent：rootless Podman（Quadlet + systemd）部署

[English](README.md) · **繁體中文**

[Hermes Agent](https://github.com/NousResearch/hermes-agent) 堆疊（gateway、含 chat TUI 的 dashboard、
webhook 接收器）以 rootless Podman
[Quadlet](https://docs.podman.io/en/v4.9.3/markdown/podman-systemd.unit.5.html) 單元在 `systemd --user`
下執行，映像由本倉庫建置且**不可變**。

> **Docker 或 podman-compose 使用者：** compose 部署（`deploy/podman/`）已移除。最後一版保留在 tag
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_hermes/tree/compose-final)
> （`git clone -b compose-final https://github.com/WOOWTECH/Woow_podman_hermes.git`）。該 tag 不再維護：
> 在 rootless podman 上沒有開機自復、dashboard 密碼預設為 `admin`，而且依賴 `deploy.sh` 去修改執行中的
> 容器。Kubernetes 請用 [Woow_k3s_hermes](https://github.com/WOOWTECH/Woow_k3s_hermes)。

## 這個版本為什麼存在

舊的部署方式是對**執行中的容器**跑 `deploy.sh`：apt 安裝 tmux、pip 安裝 `ddgs`、下載 OfficeCLI、在
`/opt/hermes` 內修補 MCP OAuth 程式碼、複製 skills — 而且多半接著 `2>/dev/null`，失敗看不見，容器一旦重建
就全部消失。在實際主機上 `podman diff hermes-agent` 回傳**零**行，沒有人能確認 MCP OAuth 修補是否真的生效。

現在所有動到映像的步驟都在建置期由 `container/Containerfile` 完成，錨點消失或下載內容改變都會**讓建置失敗**。
所有動到資料卷的步驟則由映像內的佈建腳本負責：開機時（`cont-init.d/020-woow-provision`），以及 gateway
健康後執行一次（`hermes-provision.service` → `/usr/local/bin/woow-provision`）。

## 安裝內容

| 項目 | 名稱 | 說明 |
|---|---|---|
| Agent | `hermes-agent`（單元 `hermes-agent.service`） | `localhost/woow-hermes-agent:<tag>`，本機建置、`Pull=never`。gateway 8642、dashboard 9119、webhook 8644，預設發布在 127.0.0.1。 |
| 資料庫 | `hermes-postgresql`（單元 `hermes-postgres.service`） | `postgres:15.19`（digest 釘版），**不開主機埠**。 |
| 快取 | `hermes-redis`（單元 `hermes-redis.service`） | `redis:7.4.11-alpine`（digest 釘版），**不開主機埠**。 |
| 佈建 | `hermes-provision.service` | oneshot，`WantedBy=hermes-agent.service`：等待 `/health`，套用一次 WOOWTECH 設定政策（有 stamp），啟用 tools/plugins，並修正 model routes。 |
| 網路 | `hermes` | 私有 bridge。 |
| Volume | `hermes-data`、`hermes-postgres-data`、`hermes-redis-data` | agent 狀態（SQLite、sessions、skills、memories）在 `hermes-data`。 |
| 設定 | `~/.config/hermes/hermes.env`（0600） | 供應商金鑰與公開 URL。 |
| 憑證 | podman secrets `hermes-api-server-key`、`hermes-webhook-secret`、`hermes-dashboard-password`、`hermes-postgres-password` | 安裝時產生；不再有 `admin`／`admin` 預設值。 |

> **PostgreSQL 與 Redis 是對齊用的服務。** 本倉庫（以及先前的 compose 檔）都沒有給 agent 任何一方的連線
> 設定，實機上它們的資料卷是空的，agent 的狀態存在 `/opt/data` 的 SQLite。保留它們是為了與 k3s chart 對齊，
> 並以 `Wants=` 連接，因此永遠不會阻擋 agent 啟動。若確定不需要，請開 issue 討論移除。

## 需求

- 有 systemd 與 cgroup v2 的 Linux。已在 Ubuntu 24.04 測試。
- Podman 4.9 以上、rootless，另需 `curl` 與 `git`。
- 擁有容器的使用者需以一般登入工作階段操作，並啟用 linger（install.sh 會處理）。
- 建置約需 8 GB 磁碟（光是上游基底就約 2.8 GB），記憶體依 `WOOW_HERMES_MEMORY`（預設 6g；小主機用 3g 即可）。
- 預設需要空閒的 18642、19119、18644。資料庫與快取不開任何主機埠，因此主機上既有的
  `127.0.0.1:5432`／`6379` 不會衝突。

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_hermes.git
cd Woow_podman_hermes
scripts/install.sh                     # 第一次：建立 ~/.config/hermes/hermes.env 後停下讓你檢查
nano ~/.config/hermes/hermes.env       # 填 MINIMAX_API_KEY 與 dashboard 公開 URL
scripts/install.sh                     # 建置映像、產生單元、驗證、啟動、佈建、smoke
```

第一次會建置 `localhost/woow-hermes-agent:$(sed -n 's/^HERMES_IMAGE_TAG=//p' scripts/common.sh)`，約 5-15
分鐘；`WOOW_HERMES_BUILD_CPUS`（與 `nice`）可避免建置搶走其他服務的資源。

| 選項 | 作用 |
|---|---|
| `--no-llm` | 不需供應商金鑰即可安裝（只做平台檢查）。 |
| `--accept-defaults` | 第一次執行時直接採用範例設定繼續。 |
| `--set KEY=VALUE` | 先寫入設定（可重複），例如 `--set WOOW_HERMES_MEMORY=3g`。 |
| `--no-build` / `--rebuild` | 略過建置（tag 必須已存在）／重新建置（舊映像保留為 `<tag>-prev`）。 |
| `--rotate-secrets` | 重新產生 API key、webhook secret 與 dashboard 密碼後重啟 agent；所有 API 用戶端、webhook 發送端與已儲存的登入都要跟著更新。 |
| `--dry-run` | 只產生與驗證、列出會變更的內容，不動任何東西。 |

重複執行 `install.sh` 是安全的：沒有變更時不會重啟任何東西。

## 設定

編輯 `~/.config/hermes/hermes.env`，再執行一次 `scripts/install.sh`。

| 鍵 | 預設 | 說明 |
|---|---|---|
| `HERMES_DASHBOARD_PUBLIC_URL` / `HERMES_BASE_URL` | `http://localhost:19119` | 開啟 dashboard 的 URL；MCP OAuth callback 會用到。兩行必須相同。 |
| `MINIMAX_API_KEY` | 空 | 除非以 `--no-llm` 安裝，否則必填。 |
| `OPENROUTER_API_KEY`、`GITHUB_TOKEN`、`MCP_*` | 空 | 選用的供應商與 MCP 金鑰。 |
| `WOOW_HERMES_BIND` | `127.0.0.1` | 三個埠發布的位址；`all` 同時涵蓋 IPv4 與 IPv6。 |
| `WOOW_HERMES_PORT_GATEWAY` / `_DASHBOARD` / `_WEBHOOK` | `18642` / `19119` / `18644` | 主機埠。 |
| `WOOW_HERMES_MEMORY` / `WOOW_HERMES_CPUS` | `6g` / `3` | agent 容器的限制。 |
| `WOOW_HERMES_IMAGE_TARGET` | `slim` | `full` 會加上舊的 7 層工具鏈（見下）。 |
| `WOOW_HERMES_BUILD_CPUS` | 空 | 建置用的 `--cpuset-cpus`，例如 `0-2`。 |

供應商金鑰是「env 檔不放憑證」的唯一例外：它們由使用者提供、而且經常是空值，podman secret 無法表達空值。
所有自動產生的憑證都在 podman secret：

```bash
podman secret inspect --showsecret --format '{{.SecretData}}' hermes-dashboard-password   # 私人終端機
podman secret inspect --showsecret --format '{{.SecretData}}' hermes-api-server-key
```

Hermes 本身會把供應商金鑰寫進資料卷（`/opt/data/.env`，0600；OpenRouter 還會寫進 `config.yaml` 的 model
routes），dashboard TUI 就是從那裡讀取的；這在本版之前也是如此。

## 映像

`container/Containerfile` 有兩個 target：

- **`slim`（預設）** — 釘版的上游基底，加上舊 `deploy.sh` 對執行中容器做的那些事：tmux、`hermes` CLI
  symlink、移除未用到的二進位與 skill 包、釘版的 `ddgs`、釘版並驗證校驗碼的 OfficeCLI、兩個 MCP OAuth
  `iss` 修補、釘版的 superpowers skills 種子，以及 TUI 擁有權修正。最後一個建置步驟會逐項驗證它們真的存在。
- **`full`** — `slim` 再加上舊 `docker/Dockerfile.hermes-agent` 的工具鏈（pandoc、texlive、CJK 字型、yq、
  gh、cloudflared 等）。podman 部署從未真的跑過它；gcloud、Playwright、httpie 與 yt-dlp 尚未移植。可用
  `WOOW_HERMES_IMAGE_TARGET=full` 選用。

```bash
scripts/build-image.sh                 # tag 不存在時才建置
scripts/build-image.sh --force         # 重新建置；舊映像保留為 <tag>-prev
tests/patch-anchors.sh                 # 對照釘版的上游 tag 檢查 MCP OAuth 錨點
```

升級上游基底時，必須同時更新 `scripts/common.sh` 的 `HERMES_BASE` 與 `HERMES_IMAGE_TAG`，以及
`quadlet/hermes-agent.container` 的 `Image=`；CI 會檢查三者一致。基底釘在 `v2026.8.31`，該版本
`iss-callback.py` 的每個錨點都還在；上游 `v2026.9.7` 已自行轉送 `iss`，升到該版本就必須移除那個修補。

## 驗證

```bash
tests/smoke.sh           # 單元、健康、埠、dashboard 與 gateway 認證、內建工具、
                         # 不可變性（podman diff）、佈建 stamp、密碼外洩檢查
tests/smoke.sh --quick   # 只檢查單元、健康、埠與 /health
```

Dashboard 在 `http://127.0.0.1:19119/`（使用者 `admin`）；從其他機器請用
`ssh -L 19119:127.0.0.1:19119 <host>` 或 tunnel。Gateway 提供 OpenAI 相容 API
`http://127.0.0.1:18642/v1`，需帶 `Authorization: Bearer <hermes-api-server-key>`。

## 升級

```bash
git pull
scripts/upgrade.sh
```

備份、單元快照、建置、`install.sh`、smoke。失敗時放回原本的單元，也就回到先前的映像 tag。agent 會把
SQLite schema 向前遷移，跨 schema 變更的回復還需要用 `scripts/restore.sh` 還原升級前的封存檔。

## 備份與還原

```bash
scripts/backup.sh                      # 停止 agent、匯出 hermes-data、dump 對齊用資料庫
scripts/backup.sh --hot                # 不停止（SQLite 可能寫到一半）
scripts/restore.sh --archive ~/.local/share/woow-backups/hermes/backup-<ts> --confirm-restore hermes
```

## 解除安裝

```bash
scripts/uninstall.sh                             # 移除單元；保留 volume、secrets、設定
scripts/uninstall.sh --purge                     # 另外刪除它們，並先做最後備份
scripts/uninstall.sh --purge --purge-images      # 再移除本機建置的 agent 映像
```

`--purge` 是唯一會刪除資料的指令。

## 從 podman-compose 部署遷移

compose 使用的是通用 volume 名稱（`podman_hermes-data` 等），所以這是**複製**遷移，不是原地沿用。

1. **先建置映像：** `scripts/build-image.sh`。基底會從某個 `main` 版本改為釘版的 `v2026.8.31` 發行版。
2. **停止舊堆疊並複製 volume：**
   ```bash
   podman stop hermes-agent hermes-postgresql hermes-redis
   podman volume export podman_hermes-data -o hermes-data.tar          # 約 1.2 GB
   podman volume create hermes-data && podman volume import hermes-data hermes-data.tar
   ```
   `podman_postgres-data` → `hermes-postgres-data`、`podman_redis-data` → `hermes-redis-data` 同理。
   舊 volume 保持不動，就是你的回復路徑。
3. **標記設定政策已套用過**（舊的 `deploy.sh` 已做過），避免佈建再次對你後來改過的設定跑 `sed`：
   ```bash
   mp=$(podman volume inspect --format '{{.Mountpoint}}' hermes-data)
   podman unshare touch "$mp/.woow-policy-v1" && podman unshare chown 1000:1000 "$mp/.woow-policy-v1"
   ```
4. **從舊的 `.env` 匯入 secrets**，一律用管線、不要 echo，讓 API 客戶端與 webhook 發送端繼續可用：
   ```bash
   grep '^API_SERVER_KEY=' .env | cut -d= -f2- | tr -d '\n' | podman secret create hermes-api-server-key -
   ```
   `WEBHOOK_SECRET` → `hermes-webhook-secret`、`DASHBOARD_PASSWORD` → `hermes-dashboard-password`、
   `POSTGRES_PASSWORD` → `hermes-postgres-password`（必須與已初始化的叢集相符）同理。
   `MINIMAX_API_KEY`、`OPENROUTER_API_KEY`、`GITHUB_TOKEN` 與 `HERMES_DASHBOARD_PUBLIC_URL` 則搬到
   `~/.config/hermes/hermes.env`。
5. **把舊容器改名**（`podman rename hermes-agent hermes-agent-legacy-$(date +%Y%m%d)`，另外兩個同理），
   避免被 Quadlet 取代，然後執行 `scripts/install.sh` 與 `tests/smoke.sh`。
6. **公告行為變更：** 三個埠現在預設只在 127.0.0.1（除非設 `WOOW_HERMES_BIND=all`），dashboard 密碼是你
   匯入的那一組（不再是 `admin`）。

## 安全性現況

本版保留 agent 既有（寬鬆）的政策 — 關閉 approvals、`cron_mode: yolo`、自動接受、
`GATEWAY_ALLOW_ALL_USERS=true`、`API_SERVER_CORS_ORIGINS=*`、`HERMES_DASHBOARD_INSECURE=1` — 因為改動它
會改變既有使用者依賴的行為。本版新增的是：只在 loopback 發布、以產生的憑證取代 `admin`／`admin`，以及區網
上的陌生人再也連不到 dashboard。檢討該政策值得另開 issue 處理。

## 檔案

```
container/Containerfile            映像：slim（對齊）與 full 兩個 target
container/patches/                 MCP OAuth iss 修補（錨點消失時讓建置失敗）
container/rootfs/                  映像內佈建：cont-init hooks 與 /usr/local/bin/woow-provision
container/fix-model-routes.py      冪等的 model route 修正，由 woow-provision 執行
quadlet/                           帶 @@VAR@@ 標記的單元；quadlet/render-vars 為白名單
systemd/hermes-provision.service   gateway 健康後執行 woow-provision 的 oneshot
config/hermes.env.example          ~/.config/hermes/hermes.env 的範本
config/golden-config.yaml          參考設定（不會自動套用）
scripts/                           build-image、install、upgrade、uninstall、backup、restore
scripts/lib/                       內嵌的 quadlet-lib（請勿修改；CI 會檢查其雜湊）
tests/dryrun.sh                    產生單元 + Quadlet 4.9.3 dry-run + systemd-analyze verify（CI 與本機）
tests/patch-anchors.sh             對照釘版上游 tag 檢查修補錨點
tests/smoke.sh                     主機上的安裝後檢查
tests/lint-repo.sh                 憑證掃描、映像釘版一致性、確認不再有 live mutation（CI）
docs/odoo-posting.md               原本放在 deploy/podman/SKILL.md 的 Odoo cron 筆記
```

## 疑難排解

| 症狀 | 檢查 |
|---|---|
| 建置在某個修補錨點失敗 | 上游改動了程式碼：執行 `tests/patch-anchors.sh`，再更新 `container/patches/` 或釘版的基底。 |
| Dashboard 顯示 "No API key configured" | TUI 讀的是 `/opt/data/.env`，由開機 hook 從 env 檔寫入。設好 `MINIMAX_API_KEY` 後重啟 `hermes-agent.service`。 |
| `hermes-provision.service` 失敗 | `journalctl --user -u hermes-provision.service -n 100`。它最多等 5 分鐘的 `/health`，agent 必須先健康。 |
| 升級後 TUI 看起來是舊的 | 映像版本改變時開機 hook 會重新同步 `/opt/data/ui-tui`；檢查 `/opt/data/.woow-image-version`。 |
| 少了某個以前 `deploy.sh` 會裝的工具 | 把它加進 `container/Containerfile` 後重建。依設計，現在不會再往執行中的容器安裝任何東西。 |
| 登出或重開機後單元消失 | `loginctl show-user $USER -p Linger` 必須是 `yes`。 |
