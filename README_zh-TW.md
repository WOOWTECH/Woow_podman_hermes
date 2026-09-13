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

`scripts/migrate-legacy.sh` 會完整執行整個流程，並提供回復。

```bash
scripts/migrate-legacy.sh --dry-run        # 全部檢查，並說明本主機需要哪一種回復形式
scripts/migrate-legacy.sh --prepare-only   # env 檔、secrets、映像建置、熱備份
scripts/migrate-legacy.sh --yes            # 正式切換
scripts/migrate-legacy.sh --status         # 查看記錄
```

**三個 volume 都是原地沿用。** `quadlet/*.volume` 的 `VolumeName=` 由 `WOOW_HERMES_DATA_VOLUME`、
`WOOW_HERMES_POSTGRES_VOLUME`、`WOOW_HERMES_REDIS_VOLUME` 產生，遷移時會把它們設為 compose 時期的名稱
`podman_hermes-data`、`podman_postgres-data`、`podman_redis-data`。1.3 GB 的 agent 狀態完全不複製，
安裝後還會**驗證**沿用：比對每個 volume 的 mountpoint、`CreatedAt` 與 inode 是否與切換前一致。若單元仍用
預設名稱，這裡會出現全新的空 `hermes-data`，而這個比對正是用來抓出它。全新安裝則維持預設值。

它會拒絕而不是猜測的情況：容器不存在、未執行或已由 Quadlet 管理；volume 掛在本倉庫預期以外的位置；
另有執行中的容器在寫同一個 volume；agent 沒有發佈全部三個埠；埠發佈在多個位址；目標埠被非舊堆疊的程式占用；
PostgreSQL 主版本與釘版不符（沿用的叢集無法原地升主版本）；資料庫不回應 `pg_isready`；
`HERMES_DASHBOARD_PUBLIC_URL` 為空；單元已安裝；以及 `hermes.network` 被改成 compose 專案名稱（見下）。

所有耗時的工作都在**停機之前**完成：env 檔、secrets、映像建置（5–15 分鐘外加基底下載）、釘版的
`postgres` 與 `redis` 下載、`hermes` 資料庫的 `pg_dump -Fc` 與 `pg_dumpall --roles-only`、
三個 volume 的熱匯出、`podman inspect`、compose 檔，以及 capture 路徑下的回復副本。`--prepare-only`
就停在這裡。之後的切換才停止堆疊、做冷匯出、退役容器、標記設定政策（見下）、安裝、驗證沿用、
執行 `tests/smoke.sh`、與切換前快照比對，並印出**實測停機時間**。

### 有三件事會刻意改變

* **映像。** compose 堆疊跑的是 `docker.io/nousresearch/hermes-agent:latest`，然後用 `podman exec`
  修改執行中的容器：`deploy/podman/deploy.sh` 以 apt 安裝 tmux、用 uv 把 `ddgs` 裝進 agent venv、
  下載 OfficeCLI、在 `/usr/local/bin` 建立 symlink、`rm -rf` 掉 `/opt/hermes` 下的技能包，並修補其中
  兩個 Python 檔。Quadlet 堆疊改跑 `localhost/woow-hermes-agent:<tag>`，由釘 digest 的基底建置，
  上述全部烘進映像。腳本會回報兩邊的映像，並在確認提示中指出這項變更。舊容器裡的東西不會被讀回來 —
  那 42 MB 的可寫層是由建置重現，不是複製。
* **secrets 是沿用而非重新產生：** API key、webhook secret 與 dashboard 密碼都取自舊容器的環境，
  讓 API 客戶端、webhook 發送端與已儲存的登入繼續可用。`--rotate-secrets` 會改為產生新值並讓三者全部失效。
  資料庫密碼同樣取自舊容器，因為 PostgreSQL 只在 initdb 時讀 `POSTGRES_PASSWORD_FILE`：在沿用的叢集上，
  記錄的 secret 必須就是叢集既有的密碼。`--align-db-password` 會額外執行 `ALTER ROLE`。
* **設定政策是「標記」而非重新套用。** 除非 `/opt/data/.woow-policy-v1` 存在，
  否則 `hermes-provision.service` 會套用 WOOWTECH 政策（對 `config.yaml` 做 `sed`，並啟用工具與外掛）。
  `deploy.sh` 早已在這個 volume 上跑過該政策，而之後可能有人在 dashboard 改過設定，因此遷移會在 volume
  閒置時寫入標記。`--reapply-config-policy` 可略過標記，讓佈建再跑一次。

埠沿用 compose 堆疊原本發佈的設定，包含 `0.0.0.0`。事後在 `~/.config/hermes/hermes.env` 設
`WOOW_HERMES_BIND=127.0.0.1` 並重新執行 `scripts/install.sh` 即可收斂。

### compose 專案叫做 `podman`，它的網路也是

compose 檔位於 `deploy/podman/`，所以 podman-compose 推導出的專案名稱是 **`podman`**：volume 是
`podman_*`，網路是 **`podman_default`**。這個名稱看起來像 podman 自己的預設網路、不屬於任何應用 —
**但在 `woowtechopenclaw` 上它就是 hermes 堆疊的網路。** 把它當成殘留物刪掉會弄壞舊堆疊以及所有依賴它的回復。

volume 之所以沿用，是因為它們存放資料；網路不存資料，所以 `quadlet/hermes.network` 另建一個 `hermes`，
並保持 `podman_default` 不動。這是刻意的：沿用該名稱會讓 `podman_default` 進入本應用的 manifest，
接著 `scripts/uninstall.sh --purge` 就會刪掉它。若 `quadlet/hermes.network` 被改成該名稱，遷移會直接拒絕執行；
`tests/dryrun.sh` 會檢查沒有任何產生的單元帶有它；切換完成時也會警告觀察期內不要移除它。

### 回復形式（STANDARD 7a）

把舊容器改名並保持停止，只在沒有東西再啟動它們時才安全。使用者單元 `podman-restart.service` 會在開機時執行
`podman start --all --filter restart-policy=always`。`ql_rollback_strategy` 會問本主機：該單元是否啟用、
是否有舊容器的策略正好是 `always`：

| 回答 | 切換時的動作 | `--rollback` 的動作 |
|---|---|---|
| `rename` | `podman rename <name> <name>-legacy-<suffix>`，保持停止 | 改名回去並啟動 |
| `capture` | `ql_capture_container` 寫入備份，然後執行單純的 `podman rm`（絕不用 `rm -v`） | `ql_recreate_container` 以原本的重啟策略重建並啟動 |

在 `woowtechopenclaw` 上三個 hermes 容器都是 `unless-stopped`，不符合該過濾條件，因此目前走 rename 路徑。
capture 路徑在這裡仍然重要，而且正是需要 **`--commit`** 的那一個：`hermes-agent` 的可寫層是
**42 672 686 bytes、844 個檔案** — 恰好就是 `deploy.sh` 造成的變更 — 若 capture 後直接移除而不先 commit，
回復得到的會是缺少全部這些變更的容器。`scripts/common.sh` 因此把 `hermes-agent` 列在
`LEGACY_COMMIT_ALWAYS`；任何可寫層超過 `LEGACY_COMMIT_RW_BYTES`（1 MiB）的容器也會僅憑量測結果被 commit —
`hermes-postgresql`（1 087 119 bytes）就是這樣處理的。大小來自 `podman inspect --size`（`.SizeRw`）；
**`podman diff` 對線上的 `hermes-agent` 印出空物件，不能拿來替代。** `tests/rollback-model.sh` 固定了以上全部行為。

### 回復

```bash
scripts/migrate-legacy.sh --rollback
```

它會停止並移除 Quadlet 單元（**三個 volume、`podman_default` 與 secrets 都保留**），依切換當時採用的形式把
舊容器帶回來，先啟動資料庫與快取、再啟動 agent，並等待 `/health`。過程中不涉及資料還原：volume 是原地沿用、
從未被覆寫。備份目錄中的 `pg_dump` 與冷匯出只在資料庫損壞時才需要 —
在容器內以 `pg_restore -c -d hermes` 還原。

請注意舊堆疊**沒有任何 systemd 單元**，策略是 `unless-stopped`，不被 `podman-restart.service` 匹配：
重開機後它不會自己回來。這在遷移之前就已經如此 — Quadlet 正是這件事的解法。

### 觀察期結束後

移除 `hermes-*-legacy-<suffix>`（rename 路徑），或備份中的 `legacy-container/` 目錄與 commit 產生的
`localhost/woow-legacy/hermes-agent:*` 映像（capture 路徑）；封存備份目錄；最後才考慮 `podman_default`。
在那之前請保留 compose checkout。

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
scripts/                           build-image、install、upgrade、uninstall、backup、restore、
                                   migrate-legacy
scripts/legacy-common.sh           rename 與 capture 回復輔助函式、可寫層判斷、volume 沿用驗證
scripts/lib/                       內嵌的 quadlet-lib（請勿修改；CI 會檢查其雜湊）
tests/dryrun.sh                    產生單元 + Quadlet 4.9.3 dry-run + systemd-analyze verify（CI 與本機）
tests/patch-anchors.sh             對照釘版上游 tag 檢查修補錨點
tests/smoke.sh                     主機上的安裝後檢查
tests/lint-repo.sh                 憑證掃描、映像釘版一致性、確認不再有 live mutation（CI）
tests/rollback-model.sh            以 tests/shims 驗證回復模型、可寫層判斷與沿用驗證（CI）
tests/shims/                       podman 與 systemctl 測試替身；不會建立任何容器
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
