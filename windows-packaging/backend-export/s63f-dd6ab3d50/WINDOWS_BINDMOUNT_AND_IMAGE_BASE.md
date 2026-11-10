# Dockerfile 运行时基座 vs Windows 安装器 bind-mount

引文来源：本修订 `Dockerfile` / `docker-compose.yml` / `.dockerignore`；xdisplay_ai PR#1 `04e713f22c5498143180315c632c039b125a0bff` 的 `compose.windows.yml.tmpl` 与 `src/scripts/common/Common.ps1`。

## 镜像层（Docker build 烤进去的）

基座：`python:3.11-slim-bookworm`（stage 1 `qt_builder` 与 stage 2 runtime 相同 FROM）。

Runtime `apt`（Dockerfile 27–31 行）：

- `fonts-dejavu` `fonts-noto-cjk`
- `libqt6gui6` `libqt6core6` `libqt6dbus6`
- `libgl1` `libfontconfig1`

烤进镜像、**不**靠 bind-mount：

- Linux `xd_render_cli`（qt_builder 现编 → `/usr/local/bin/xd_render_cli`）
- pip 包（见 `image-pip-packages.from-Dockerfile.txt`；**不读 uv.lock**）
- `playwright==1.56.0` + Chromium revision **1194** under `/opt/ms-playwright`
- `COPY app` 与 `COPY pyproject.toml`（会被 Windows bind-mount 盖掉）

`.dockerignore` 排除：`docs` `tests` `data` `db` `uv.lock` `.git` `.venv` 及各类 cache。所以 **data/ 与 migrations 不在镜像层**。

## Windows 安装器挂载（运行时权威源码）

`compose.windows.yml.tmpl`：

```
orchestration-app:
  volumes:
    - "${BACKEND_WORKSPACE_PATH}:/app"
    - "app_data:/data"
    - "app_logs:/data/logs"
embedding-worker:
  volumes:
    - "${BACKEND_WORKSPACE_PATH}:/app"
```

`Get-InstallStateLayout`：`BACKEND_WORKSPACE_PATH` = `C:\ProgramData\XDisplayAI\workspace\backend`。种子来自安装包 `seed\backend`，门是 `app\main.py`。

因此安装后容器内 `/app` = 整份后端源码快照（含 `app/` `data/` `app/prompts/` `app/assets/` `.env`），不是镜像里那份 `COPY app`。

持久化数据在 named volume `app_data:/data`（日志、生成图），**不是** 仓库 `data/`。仓库 `data/` 必须在 workspace 里，因为 `.dockerignore` 没把它打进镜像。

## bind-mount 必须带上的本快照内容

| 树 | 本 2.89MB 包内 | 用途 |
|---|---|---|
| `app/`（700 文件，含 `app/prompts/` `app/assets/` `app/browser_solver/prompts/`） | 有 | 运行时代码 + prompt 文件 |
| `data/chunks` 23 文件 | 有 | 组件规格 catalog |
| `data/contracts` 208 文件 | 有 | page-engineering 契约 |
| `data/icons` 201 文件 | 有 | 图标资产 |
| `data/design_system` `control_conventions` `intent_recall` | 有 | 约束/惯例 |
| `data/benchmarks` `golden` `uat_reports` `traces` … | 有（快照未裁） | 非安装器硬门；在包内以免漏资产 |
| `db/migrations/0001_init.sql` `0002_rag.sql` `0003_orch_runtime.sql` | 有 | 安装器拷到 `docker\migrations\`；s63f **无新 migration** |
| `scripts/embedding_http_service.py` | 有 | embedding 镜像 Dockerfile.embedding COPY；workspace 挂 /app 时也能看见 |
| `.env` | **无**（有意） | 安装器种子 tmpl 生成；退役键 `XDISPLAY_AI_STAGED_DRAFTER_ENABLED` 不得出现 |

安装器还单独拷贝：

- `docker-compose.yml` → `inputs/backend/compose/upstream/` 再进 payload `docker/compose/`
- `db/migrations/*.sql` → `inputs/backend/migrations/` → payload `docker/migrations/`

不要为了包装指纹去补 `docker/export_runtime_requirements.py` 或 `docker/strict-ocr`：s63f 树没有它们，Dockerfile 也不 COPY 它们。
