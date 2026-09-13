# Hermes Agent — Podman 部署

## 快速開始

```bash
# 1. 生成設定檔
bash deploy.sh

# 2. 編輯 API Key
nano .env   # 填入 MINIMAX_API_KEY

# 3. 啟動
bash deploy.sh
```

## 架構（v0.17.0 起單容器）

Dashboard TUI 為唯一 chat 介面；沒有獨立 WebUI sidecar。

```
Podman Pod: hermes
├── hermes-agent      :8642 (Gateway) + :9119 (Dashboard + Chat TUI)
├── postgresql        :5432
└── redis             :6379
```

## 唯一 GUI — Dashboard

| 介面 | URL | 用途 |
|------|-----|------|
| Dashboard | http://localhost:19119 | Chat TUI + Config + API Keys + MCP + Model 切換 + Terminal |

Chat TUI 跑在 hermes-agent 容器中，完整存取 ffmpeg / edge-tts / rclone / playwright / node / hermes CLI。

## Cloudflare Tunnel 整合

如已有 CF tunnel，加入單一路由：

```
hostname: name-dashboard.woowtech.io → http://localhost:19119
```

## 管理

```bash
podman-compose ps          # 查看狀態
podman-compose logs -f     # 查看日誌
podman-compose restart     # 重啟
podman-compose down        # 停止
podman-compose down -v     # 停止並刪除資料（會清 PVC）
```

## v0.16.x → v0.17.0 遷移

- `hermes-webui` 容器已移除；port `18787` 不再開放
- `.env` 中的 `WEBUI_PASSWORD` 可以刪除（已不再讀取）
- 對外只保留 Dashboard host name；舊的 WebUI CF tunnel route 可拆除
- PVC 資料 (`hermes-data`) 完全保留（agent 沿用同一 volume）
