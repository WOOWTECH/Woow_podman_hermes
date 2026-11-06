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
所有動到資料卷的步驟則由映像內的佈建腳本負責：開機時（`cont-init.d/020-woow-provision`、
`cont-init.d/03-woow-dotenv`），以及 gateway 健康後（`hermes-provision.service` → `/usr/local/bin/woow-provision`）。

映像與佈建對齊 [Home Assistant add-on](https://github.com/WOOWTECH/Woow_ha_hermes_add_on)（Hermes v0.22.5）：
相同的上游基底、修補、預設值與 Paseo 主機介面，只少了 HA 才有的部分（Ingress、Supervisor token 邊界）。
取自該 add-on 的檔案與雜湊列在 `container/patches/PROVENANCE`。

## 安裝內容

| 項目 | 名稱 | 說明 |
|---|---|---|
| Agent | `hermes-agent`（單元 `hermes-agent.service`） | `localhost/woow-hermes-agent:<tag>`，本機建置、`Pull=never`。gateway 8642、dashboard 9119、webhook 8644，預設發布在 127.0.0.1。 |
| 資料庫 | `hermes-postgresql`（單元 `hermes-postgres.service`） | `postgres:15.19`（digest 釘版），**不開主機埠**。 |
| 快取 | `hermes-redis`（單元 `hermes-redis.service`） | `redis:7.4.11-alpine`（digest 釘版），**不開主機埠**。 |
| 佈建 | `hermes-provision.service` | oneshot，`WantedBy=hermes-agent.service`：等待 `/health`，啟用一次 WOOWTECH tools/plugins（有 stamp），修正 model routes，並在鍵仍為空時寫入 web／browser／webhook 預設值。 |
| 網路 | `hermes` | 私有 bridge。 |
| Volume | `hermes-data`、`hermes-postgres-data`、`hermes-redis-data` | agent 狀態（SQLite、sessions、skills、memories）在 `hermes-data`。 |
| 設定 | `~/.config/hermes/hermes.env`（0600） | 供應商金鑰與公開 URL。 |
| 憑證 | podman secrets `hermes-api-server-key`、`hermes-webhook-secret`、`hermes-dashboard-password`、`hermes-dashboard-session-secret`、`hermes-postgres-password` | 安裝時產生；不再有 `admin`／`admin` 預設值。session secret 用來簽署 dashboard 登入，重啟後不會把人登出。 |

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
| `--rotate-secrets` | 重新產生 API key、webhook secret、dashboard 密碼與 session secret 後重啟 agent；所有 API 用戶端、webhook 發送端與已儲存的登入都要跟著更新。 |
| `--dry-run` | 只產生與驗證、列出會變更的內容，不動任何東西。 |

重複執行 `install.sh` 是安全的：沒有變更時不會重啟任何東西。

## 設定

編輯 `~/.config/hermes/hermes.env`，再執行一次 `scripts/install.sh`。

| 鍵 | 預設 | 說明 |
|---|---|---|
| `HERMES_DASHBOARD_PUBLIC_URL` / `HERMES_BASE_URL` | `http://localhost:19119` | 瀏覽器開啟 dashboard 的精確 Origin（經 tunnel 時填其 `https://` Origin，不含路徑）。MCP OAuth callback 會回到這裡，Paseo 插件也只接受來自它的瀏覽器請求。兩行必須相同。見[公開網址與 HTTPS](#公開網址與-https)。 |
| `HERMES_PASEO_EXTRA_ORIGIN` | 空 | 選用：Paseo 的第二個精確 Origin，例如公開網址是 tunnel 時填 `http://127.0.0.1:19119`。見 [Paseo](#paseo)。 |
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
routes），dashboard TUI 就是從那裡讀取的。開機 hook `03-woow-dotenv` **只在 `hermes.env` 的值自上次啟動後
改變時**才寫入 `MINIMAX_API_KEY`、`OPENROUTER_API_KEY` 與 `GITHUB_TOKEN`，所以在 dashboard 改過的金鑰重啟後
仍會保留（0.20.0 每次開機都重寫整個檔案）。`hermes.env` 裡的空值不會動到該檔；要刪除金鑰請在 dashboard 操作。
由單元管理的 secrets 會從該檔移除，因為那裡的副本會蓋過 podman secret。

### 公開網址與 HTTPS

`HERMES_DASHBOARD_PUBLIC_URL`（以及值相同的 `HERMES_BASE_URL`）要填**瀏覽器實際使用的 Origin**。經 Cloudflare
tunnel 或其他 HTTPS 反向代理時，填它的 `https://` Origin，例如 `https://hermes.example.com`：協定、主機，
非 443 才加埠號，不含路徑與結尾斜線。`install.sh` 會拒絕含帳密、query 或 fragment 的公開網址；非 loopback
主機使用純 `http`，或不是精確 Origin（路徑前綴可用於 OAuth，但 Paseo 不行）時會發出警告。

公開網址設成 HTTPS Origin 後，本機 loopback 的 dashboard 仍可使用（`tests/image-test.sh` P4）：dashboard 在容器
內綁定 `0.0.0.0`，因此 v0.22.5 接受任何 `Host`；cookie 依每個請求本身的協定設定，與公開網址無關；登入也沒有
Origin 檢查。所以 `http://127.0.0.1:19119`（或 `ssh -L`）與 `https://hermes.example.com` 都能登入，兩者是各自
獨立的 session。公開網址會改變的是：MCP OAuth callback 一律回到它，Paseo 插件也只接受它（加上
`HERMES_PASEO_EXTRA_ORIGIN`）。`localhost` 與 `127.0.0.1` 是不同的 Origin。

此時 dashboard 自己的登入就是 agent 前唯一的關卡：能連到 tunnel 的人都能嘗試密碼。請保持
`hermes-dashboard-password` 夠長（自動產生的即可），並考慮在 tunnel 前加上存取政策。

### Paseo

映像內含取自 HA add-on 的 Paseo 主機介面（`container/vendor/paseo`，即
[hermes-paseo-plugin](https://github.com/WOOWTECH/hermes-paseo-plugin) `0.1.4-rc.9` 經審查的 `host/` 目錄，
雜湊見 `PROVENANCE.json`）。它讓已啟用的 Paseo 插件能重載 dashboard，並在插件停用或移除前先停止它的 daemon。
插件本身**不隨映像附帶**：由使用者在 dashboard 安裝，升級也不會自動安裝或啟用。

需求：

- 從其他機器使用時需要 HTTPS 公開網址（Paseo 配對與模型登入都在瀏覽器進行）。介面接受 `http` Origin
  （和 Home Assistant 的區網用法相同），但非 loopback 主機用純 http 時 `install.sh` 會警告。
- agent 容器需能連到 GitHub（插件原始碼）、npm registry（Paseo runtime，首次使用時下載到 `/opt/data`，約一分鐘）
  以及官方 Paseo relay 與 Web 介面（`app.paseo.sh`）。
- Node.js 22.19 以上（插件的 `engines`）：映像內是 v26.12.1，建置時會檢查。

`install.sh`（或 `upgrade.sh`）之後的步驟：

1. **從公開網址**（或 `HERMES_PASEO_EXTRA_ORIGIN`）開啟 dashboard 並登入。
2. **Plugins** → *Git URL or owner/repo* 填 `WOOWTECH/hermes-paseo-plugin`，安裝目前的版本（`0.1.4-rc.9`；以
   程式呼叫 Plugins API 時 ref 必須是完整 commit SHA `1101a5da63178e08bd0fdf849db8e2a5de4d6ef1`，不能用 tag）並
   啟用。來源為公開 GitHub，不需要 GitHub token。確認 caution 提示前，先核對來源與權限說明。
3. 點 **Paseo**。首次啟動會下載 runtime，請等頁面顯示已啟動。Hermes v0.22.5 會在第一次使用時載入新插件的後端，
   只有頁面持續顯示插件 API 尚未載入時才需要按 **重載 Dashboard**。
4. 產生配對連結，點 **開啟 Paseo**，在官方介面按 **Connect**。配對連結具有存取能力，請勿公開。新裝置請先新增
   project（**Add project → New directory**，父目錄 `/opt/data`）。
5. **New workspace**，選 project、Hermes、已登入的模型，再按 **Create**。

停用或移除插件請在 dashboard 的 Plugins 頁操作（主機介面會先停止 Paseo daemon）；從 CLI 移除前先執行
`/paseo stop`。狀態、配對與對話保存在 `/opt/data`。`503 INVALID_DASHBOARD_ORIGIN` 表示公開網址（或額外 Origin）
不是精確 Origin；`ORIGIN_DENIED` 表示瀏覽器的 Origin 兩者都不是。修正 `hermes.env` 後再執行
`scripts/install.sh`；不要關閉來源驗證。

## 映像

`container/Containerfile` 有兩個 target：

- **`slim`（預設）** — 釘版的上游基底，加上舊 `deploy.sh` 對執行中容器做的那些事：tmux、`hermes` CLI
  symlink、移除未用到的二進位與 skill 包、釘版的 `ddgs`、釘版並驗證校驗碼的 OfficeCLI、釘版的 superpowers
  skills 種子；並如同 HA add-on，加入以上游雜湊檢查的套件釘版安裝的 `agent-browser`，以及兩個建置期修補：
  `upstream-contract.py`（驗證原生的 dashboard 登入、MCP OAuth state／issuer 處理與無人值守 approval 路徑）與
  `scoped-prompt-gc.py`（刪除 session 時只回收該 session 參照的 system prompt，而不是所有未被參照的）。
  最後一個建置步驟會逐項驗證它們真的存在。
- **`full`** — `slim` 再加上舊 `docker/Dockerfile.hermes-agent` 的工具鏈（pandoc、texlive、CJK 字型、yq、
  gh、cloudflared 等）。podman 部署從未真的跑過它；gcloud、Playwright、httpie 與 yt-dlp 尚未移植。可用
  `WOOW_HERMES_IMAGE_TARGET=full` 選用。

```bash
scripts/build-image.sh                 # tag 不存在時才建置
scripts/build-image.sh --force         # 重新建置；舊映像保留為 <tag>-prev
tests/patch-anchors.sh                 # 對照釘版的上游 tag 檢查修補與上游契約
tests/image-test.sh                    # 以拋棄式容器啟動建好的映像（本機，約 5 分鐘）
```

升級上游基底時，必須同時更新 `scripts/common.sh` 的 `HERMES_BASE` 與 `HERMES_IMAGE_TAG`，以及
`quadlet/hermes-agent.container` 的 `Image=`；CI 會檢查三者一致。tag 格式為 `<上游 tag>-woow<N>`。基底以
digest 釘在 `v0.22.5`，它已在自己的 dashboard OAuth 流程中轉送 RFC 9207 `iss`，因此舊的 `iss-callback.py`／
`iss-permissive.py` 修補已移除，MCP SDK 的 issuer 檢查也不再放寬：回傳不同 issuer 的 OAuth 伺服器必須修正其
metadata，之後重新連接該整合。

`tests/image-test.sh [IMAGE]` 不發布任何埠，分別以全新 volume、像 compose 堆疊留下的 uid 1000 volume，以及
HTTPS 公開網址啟動映像，檢查 s6、dashboard、佈建、`.env` 合併、登入在重啟後仍有效、approval gate、scoped prompt
GC，以及 Paseo 主機介面（權限降級、Origin、loopback 與 tunnel 登入、`INVALID_DASHBOARD_ORIGIN`）。CI 無法建置
映像，請在發佈前於本機執行。請設定 `IMAGE_TEST_PREFIX`，讓它的容器與 volume 名稱不會和主機上其他東西衝突。

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
  否則 `hermes-provision.service` 會啟用 WOOWTECH 工具與外掛。`deploy.sh` 早已在這個 volume 上做過，
  而之後可能有人在 dashboard 改過設定，因此遷移會在 volume 閒置時寫入標記。`--reapply-config-policy`
  可略過標記，讓佈建再跑一次。（以前一起套用的 `sed` approval 政策已移除；見「安全性現況」。）

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

Approvals 採用**上游預設值**：`approvals.mode: smart`，`approvals.cron_mode`／`approvals.unattended_mode: deny`，
所以來自 cron、OpenAI 相容 API 或 webhook（沒有人能核准）的危險指令會被拒絕（`tests/test-approval-gate.py`
在映像內驗證）。0.20.0 帶有一段本意是關閉 approvals、把 cron 改成 `yolo` 的 `sed`，但它從未匹配設定範本，
因此從未生效；本版將它移除而不是讓它生效（與 HA add-on 相同的決定）。既有的 `config.yaml` 保持原樣；
請在 dashboard（**Config**）調整。

仍然寬鬆、並在 `quadlet/hermes-agent.container` 中可見的：`GATEWAY_ALLOW_ALL_USERS=true` 與
`API_SERVER_CORS_ORIGINS=*`。`HERMES_DASHBOARD_INSECURE` 已移除（v0.22.5 不再讀取）。本堆疊新增的是：只在
loopback 發布、以產生的憑證取代 `admin`／`admin`、區網上的陌生人連不到 dashboard，以及穩定的 session 簽署。

agent 以容器 uid **1000**（`HERMES_UID`）執行，而不是 v0.22.5 預設的 10000：從 compose 堆疊沿用的 volume
屬於 1000，而 stage2 只做定點的擁有權修復，會讓這種 volume 的大部分內容對 10000 不可讀（gateway 開機即失敗）。
全新 volume 兩者皆可；維持同一個值也讓回復到 0.20.0 仍然可行。

## 檔案

```
container/Containerfile            映像：slim（對齊）與 full 兩個 target
container/patches/                 與 HA add-on 共用的建置期修補，及其 PROVENANCE
container/vendor/paseo/            Paseo 主機介面與 hermes 進入點（取自 HA add-on）
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
tests/patch-anchors.sh             對照釘版上游 tag 檢查修補與契約（CI）
tests/test-config-contract.py      靜態檢查映像／單元／佈建契約（CI）
tests/test-scoped-prompt-gc*.py    以上游節錄驗證 scoped prompt GC（CI）
tests/image-test.sh                以拋棄式容器啟動建好的映像（本機）
tests/test-approval-gate.py        映像內的無人值守 approval gate（由 image-test 執行）
tests/run-scoped-prompt-gc-image.py  以映像內的 SessionDB 驗證 scoped prompt GC（由 image-test 執行）
tests/smoke.sh                     主機上的安裝後檢查
tests/lint-repo.sh                 憑證掃描、映像釘版一致性、確認不再有 live mutation（CI）
tests/provisioning-test.sh         以真實 config 形狀驗證 fix-model-routes.py 的結束碼（CI）
tests/rollback-model.sh            以 tests/shims 驗證回復模型、可寫層判斷與沿用驗證（CI）
tests/resource-recreate.sh         在 systemd 之外被刪除的網路／volume 會重建（CI）
tests/test-paseo-vendor.py         Paseo 主機介面的釘版與封裝（CI）
tests/test-paseo-origin.py         額外 Paseo Origin 的驗證，開機 hook 與 install.sh 一致（CI）
tests/shims/                       podman 與 systemctl 測試替身；不會建立任何容器
docs/odoo-posting.md               原本放在 deploy/podman/SKILL.md 的 Odoo cron 筆記
docs/migration-rehearsal-toypark1234.md   遷移端對端預演的實際輸出
```

## 疑難排解

| 症狀 | 檢查 |
|---|---|
| 建置在某個修補錨點失敗 | 上游改動了程式碼：執行 `tests/patch-anchors.sh`，再更新 `container/patches/` 或釘版的基底。 |
| Dashboard 顯示 "No API key configured" | TUI 讀的是 `/opt/data/.env`，由開機 hook 從 env 檔合併寫入。設好 `MINIMAX_API_KEY` 後重啟 `hermes-agent.service`。 |
| `hermes.env` 改了金鑰卻沒生效 | 在 `hermes.env` 的值再次改變前，`/opt/data/.env` 裡 dashboard 的副本優先；請在 dashboard 修改，或改 `hermes.env` 後重啟。 |
| MCP OAuth 登入因 issuer 不符失敗 | v0.22.5 保留 SDK 的 RFC 9207 檢查。修正伺服器的 issuer metadata 後重新連接該整合。 |
| `hermes-provision.service` 失敗 | `journalctl --user -u hermes-provision.service -n 100`。它最多等 5 分鐘的 `/health`，agent 必須先健康。 |
| 升級後 TUI 看起來是舊的 | TUI 直接從映像（`/opt/hermes/ui-tui`）執行，新映像就是新 TUI；重新整理頁面。`/opt/data/.woow-image-version` 記錄最後開機此 volume 的映像。 |
| 少了某個以前 `deploy.sh` 會裝的工具 | 把它加進 `container/Containerfile` 後重建。依設計，現在不會再往執行中的容器安裝任何東西。 |
| 登出或重開機後單元消失 | `loginctl show-user $USER -p Linger` 必須是 `yes`。 |
| `unable to find network with name or ID hermes` | 網路在 systemd 之外被刪除（`podman system reset`、`podman network rm`），但 `hermes-network.service` 仍是 active。再執行一次 `scripts/install.sh`：它會重啟該單元與容器。以同樣方式消失的 volume 會以**空的**重建並發出警告，請用 `scripts/restore.sh` 還原。 |
| Paseo 顯示 `INVALID_DASHBOARD_ORIGIN` 或 `ORIGIN_DENIED` | 見 [Paseo](#paseo)：公開網址必須是瀏覽器網址列的精確 Origin。 |
| 容器開機時停止並顯示 `Invalid HERMES_PASEO_EXTRA_ORIGIN` | 修正 `hermes.env` 的值（scheme://host[:port]，不含路徑），再執行會先驗證它的 `scripts/install.sh`。 |
