# s63i-hf2b 离线安装器后端输入（授权修订，不是 HEAD）

本目录是 **secret-free 元数据 + 可复现镜像配方占位**。本云环境 **没有** 已核源码 tar，也 **没有** Docker，因此 **没有** 新的 `orches_orchestration-app_latest.tar`。

禁止：

- 把旧 tar `F3EECC91…` / s63f `514ACD60…` / cloud `35E5F27E…` 改名当成 s63i-hf2b
- 把 Mac c186 SHA `afde40db…` 当成 Windows 客户端钉
- 发明任何 docker-save / runtime-fingerprint / Windows client SHA

## 授权修订

| 项 | 值 |
|---|---|
| author card | `s63i-hf2b` |
| tag | `prod/s63i-hf2` |
| full commit | `623b072320d2e8c68059ec5e7e33958267203a9c` |
| author-card prefix | `623b07232` |
| 源码包 | `ai_orchestration-s63i-hf2b-623b07232.sanitized.tar.gz`（3205603 / `68B6E331…`） |

## Prompt / 迁移合同

- 31 代理注册表 + overlays：intent_extractor v2.24、read_display_declarer v1.15、write_action_declarer v1.10、write_action_declarer_link **v1.10**、sketch_interpreter v4.0
- PAGE_HTML **v20**、STYLESHEET **v6** 各自独立 Settings 键
- 退役键 `XDISPLAY_AI_STAGED_DRAFTER_ENABLED` 必须缺席
- 迁移仅 `0001_init.sql` / `0002_rag.sql` / `0003_orch_runtime.sql`（除非父机证明 623b07232 另有 SQL）

## 父机构建步骤（哈希齐备后）

1. 解压已核源码包到 `ai_orchestration-s63i-hf2b-623b07232/`
2. 确认 `SOURCE_REVISION.txt` 前缀 `623b07232`
3. 运行 `rebuild-orches-app-image.sh`（默认校验已核 SHA）
4. 写出 companion inspect JSON；四个 Linux amd64 tar 放 durable host storage，**不进 git**
5. 更新 `windows-packaging/manifests/pins/offline-inputs.s63i-hf2b.json` 的 `files[]` / `backend.appImage` / Windows client 钉

## 安装器侧门

`Assert-ExistingBackendInputs` + `Assert-ApprovedCardPinsReady` 在缺少 source/app/client 所需哈希时失败关闭。
