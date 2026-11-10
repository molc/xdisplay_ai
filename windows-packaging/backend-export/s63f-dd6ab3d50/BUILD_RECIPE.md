# s63f 离线安装器后端输入（授权修订，不是 HEAD）

本目录是 **secret-free 源码快照 + 可复现镜像配方**。本云环境 **没有 Docker**，因此 **没有** 新的 `orches_orchestration-app_latest.tar`。禁止把旧 tar `F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309` 改名当成 s63f。

未改 `app/` 业务代码、未部署 `.21`、未合并、未新增密钥/供应商。

## 授权身份（已核远程 tag，不是工作区 HEAD 口头值）

| 项 | 值 |
|---|---|
| tag | `prod/s63f`（lightweight，对象类型 `commit`） |
| full commit | `dd6ab3d505827a94cbc9d59d7067fcce14db6fbe` |
| author-card prefix | `dd6ab3d50` |
| 远程 `refs/tags/prod/s63f` | 同一 SHA |
| 子模块 `external/xdisplay` gitlink | `0c657ad3eac7ece814206bd40fea807ec6568f81`（`client/c-180` 尖） |
| 源码包 | `ai_orchestration-s63f-dd6ab3d50.tar.gz` |
| 源码包 SHA256 | `767E9305A7C9C6B57CE9220A971C9F1BE0F8102E46F9A8C67444203253B76A84` |
| 源码包 size | 2890098 |

证据：`TAG_VERIFY.txt`、包内 `SOURCE_REVISION.txt`（41 字节 = 40 hex + newline）。

## `xd_render_cli`：源码包里有二进制，但不是 Linux 镜像里的那份

对已交接的 2.89MB 源码包 `sha256sum` 后实测（不是口头）：

| 路径 | size | SHA256 | `file` |
|---|---:|---|---|
| `external/xdisplay/bin/xd_render_cli/xd_render_cli` | 50200 | `58618ec212229ac900e48304922afd50edffd0f54cb325dcfa60f34382a606ea` | **Mach-O 64-bit x86_64**（macOS） |
| 同目录 `.pro` / `.cpp` / `.h` / `Makefile` | 见 `XD_RENDER_CLI_PROOF.json` | gitlink `0c657ad3eac7ece814206bd40fea807ec6568f81` | 源码 |

Dockerfile 第 9–14 行（本修订 blob `6c5e959a…`）是：

```
COPY external/xdisplay/bin/xd_render_cli /src/xd_render_cli
WORKDIR /src/xd_render_cli
RUN rm -f xd_render_cli \
    && qmake6 xd_render_cli.pro \
    && make -j"$(nproc)" \
    && make install INSTALL_ROOT=/opt/stage
```

因此：**镜像不使用包内 Mach-O**。Linux ELF 由 `python:3.11-slim-bookworm` 的 `qt_builder` 阶段用 `qmake6` + `qt6-base-dev` 现编。父机 Docker 构建不需要另给 Linux CLI，也不要 ad-hoc 替换 COPY 路径。

本导出环境：`g++`/`make` 有，**没有** `qmake6` / `qt6-base-dev` / Docker。未在宿主机编 Linux CLI（编出来也不是镜像内 Debian bookworm/Qt6 那份）。未、也不能从旧 app tar `F3EECC91…` 取出 CLI 并宣称兼容——此处没有该 tar、没有 Docker、没有旧镜像 ELF 哈希。

## 父流程如何接到 xdisplay_ai 0.1.4 门

安装器 PR https://github.com/molc/xdisplay_ai/pull/1 的 `Assert-ExistingBackendInputs` 需要：

1. `inputs/backend/source/SOURCE_REVISION.txt` 前缀 `dd6ab3d50`
2. `inputs/backend/source/app/main.py`
3. `inputs/backend/compose/upstream/docker-compose.yml`
4. `inputs/backend/migrations/*.sql`（本批 **无新 data migration**；仍要带上仓库里已有的三份 SQL）
5. 新的 `inputs/backend/images/orches_orchestration-app_latest.tar`，SHA256 **不得** 为 `F3EECC91…`

本包解压后就是 `BackendRepoPath`。xdisplay_ai `prepare-inputs.ps1` `Sync-BackendSourceSnapshot` 会 robocopy 整树（排除 `.git` / `.venv` / `.env` 等）并写入 `SOURCE_REVISION.txt`。

```powershell
$src = "<UNPACK>\ai_orchestration-s63f-dd6ab3d50"
# 1) 源码快照（或让 prepare-inputs -BackendRepoPath $src 自己拷）
# 2) 在有 Docker 的 builder 上跑 rebuild-orches-app-image.sh，把 tar 放到 inputs/backend/images/
# 3) 禁止 -SkipBackendImageBuild
```

客户端继续用 Word-fix 超集，**不要动客户端**：

- CatalogWrite `Xdisplay.exe` 675539394 / SHA256 `2A80890DB988157371CF28D24CA23685D7933C4E59630E5A2DCD2363B7DB5600`
- Converter `F7C50DB87D082DE31A154A123B05FA3D327A4117F7CE5FCD2F5E51CF3D595D36`

这不是提测卡字面 c180 邮件字节。安装器 0.1.4 正确性修复是 xdisplay_ai 上的独立 PR。

## 包内有什么（实际需要的运行时 + 镜像构建上下文）

解压根目录 `ai_orchestration-s63f-dd6ab3d50/`：

- `app/`（含 `app/prompts/`、`app/assets/`、`app/browser_solver/prompts/`）
- `data/`（chunks / contracts / design_system / icons / control_conventions 等；运行时 bind-mount 需要。`.dockerignore` **排除** `data/`，所以它们不进镜像层）
- `db/migrations/0001_init.sql` `0002_rag.sql` `0003_orch_runtime.sql`
- `Dockerfile` `Dockerfile.embedding` `.dockerignore`
- `docker-compose.yml` `docker-compose.local.yml` `docker-compose.orches.yml`
- `docker/grafana` `docker/prometheus`（compose.orches 引用；Windows 安装器 overlay 是 xdisplay_ai 自己的 tmpl）
- `pyproject.toml` `uv.lock`（锁文件随包；**镜像构建不读 uv.lock**）
- `.env.example` `.env.orches.example`（无密钥模板）
- `config/production_behaviour.env.snapshot`（总指挥标注无密钥的行为键快照；**不是** `.env`）
- `scripts/embedding_http_service.py`
- `external/xdisplay/bin/xd_render_cli/*`（Dockerfile `COPY` 所需；从 gitlink `0c657ad3` 检出，不是发明）
- `SOURCE_REVISION.txt` `SOURCE_TAG.txt` `SOURCE_SUBMODULE.txt` `SHA256SUMS.txt`

**未打入包（有意）：** `.git`、`.env`、tests、docs、`_bmad-output`、真实 API key、本机 `origin` token。

s63f 提测卡：本批 **无 data migration**；prompt 钉不变；退役键 `XDISPLAY_AI_STAGED_DRAFTER_ENABLED` 已不在本快照任何文件中。安装器种子 `.env` 的删除逻辑在 xdisplay_ai tmpl / `Get-RetiredBackendEnvKeys`，本包不提供带密钥的生产 `.env`。

提测卡列出的钉在本修订均存在（文件 sha256 见 `key-file-hashes.json`）：

- `intent_extractor` v2.24
- `PAGE_HTML` v19 → `app/browser_solver/prompts/page_html_v19.md`
- `read_display_declarer` v1.15
- `write_action_declarer` v1.10
- `write_action_declarer_link` v1.8
- `sketch_interpreter` v4.0
- `STYLESHEET` v6 → `app/browser_solver/prompts/engineering_stylesheet_v6.md`
- 草图视觉 timeout 90s：生产行为快照有 `XDISPLAY_AI_SKETCH_VISION_TIMEOUT_SECONDS=90`

生产快照里的 `XDISPLAY_AI_PROMPT_VERSIONS` 是 **整表**；xdisplay_ai `backend.env.tmpl` 只写了提测卡那 7 项。本包不改安装器 tmpl。

## 真实 Docker 构建上下文（不是发明）

仓库 `docker-compose.yml`：

```
orchestration-app:
  image: orches/orchestration-app:latest
  build:
    context: .
    dockerfile: Dockerfile
```

`Dockerfile`（blob `6c5e959ae89a9da95851795ff978faeba731bea0` / sha256 `bdd86198bea1f87ac04e996613d8addbc02cc65cfaf9eba1b02c30478f56e5a0`）实际 `COPY`：

1. `external/xdisplay/bin/xd_render_cli` → 阶段 1 用 Qt6 `qmake6` 重建 Linux 二进制（目录里的 Mach-O `xd_render_cli` 会被 `rm -f`）
2. `app` → `/app/app`
3. `pyproject.toml` → `/app/pyproject.toml`（**不** `pip install -e .` / **不** 用 `uv.lock`）
4. 随后 `pip install` 固定清单 + `playwright==1.56.0` + Chromium revision **1194**

`.dockerignore` 排除：`.git` `.venv` `__pycache__` `*.pyc` pytest/mypy/ruff cache、`docs` `tests` `data` `db` `uv.lock`。

运行时合同（与 `.21` / Windows 包装一致）：镜像是 Python/Playwright/xd_render_cli 运行时；`app/` `data/` prompts 由 **bind-mount `/app`** 覆盖镜像内 `COPY app`。所以必须同时交付 **新镜像** 和 **本源码快照**。只换源码挂旧镜像、或只换镜像不换源码，都不能标 s63f。

xdisplay_ai `s63f-app-image-build-recipe.md` 的命令与上面一致。本包已带入子模块文件，**不必**再 `git submodule update`（父机若自己 clone 仓库则仍应按 gitlink 初始化）。

在有 Docker 的 builder 上：

```bash
chmod +x packaging-export/s63f-dd6ab3d50/rebuild-orches-app-image.sh
./packaging-export/s63f-dd6ab3d50/rebuild-orches-app-image.sh
# 产出 orches_orchestration-app_latest.tar 并打印 SHA256
# 复制到 windows-packaging/inputs/backend/images/
# 复制 SOURCE_REVISION.txt 到 inputs/backend/source/
```

等价手写命令（与 xdisplay_ai 配方相同，SOURCE_REVISION 已在包内）：

```bash
tar -xzf ai_orchestration-s63f-dd6ab3d50.tar.gz
cd ai_orchestration-s63f-dd6ab3d50
git_rev=$(tr -d '[:space:]' < SOURCE_REVISION.txt)
docker build \
  --label "xdisplayai.packaging.git-sha=${git_rev}" \
  --label "xdisplayai.packaging.tag=prod/s63f" \
  --tag "orches/orchestration-app:s63f-dd6ab3d50" \
  --tag "orches/orchestration-app:latest" \
  --file Dockerfile \
  .
docker save --output orches_orchestration-app_latest.tar orches/orchestration-app:s63f-dd6ab3d50
```

预期 app tar 约 1.8GB，超过本通道 25M/46M 附件上限，所以合法交付是 **源码包 + 配方**，由父机本地 Docker 构建。

## 本环境实测

```
command -v docker  -> not found
```

未构建、未 `docker save`、未加载旧 tar。companion 结论见 `COMPANION_IMAGES.md`。

## 密钥

- 包内无 `.env`
- `config/production_behaviour.env.snapshot` 文件头写明无密钥
- `.env.example` / `.env.orches.example` 无 API key 值
- 密钥扫描：无 `sk-` / `ghp_` / PEM / `AKIA` 命中
