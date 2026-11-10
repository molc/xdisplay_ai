# 包装指纹必须跟 Dockerfile，不能跟不存在的路径

xdisplay_ai `Get-OrchestrationAppRuntimeFingerprintPaths`（PR#1 `windows-packaging/ci/Common.ps1`）当前写的是：

```
Dockerfile
pyproject.toml
docker\export_runtime_requirements.py
docker\strict-ocr
external\xdisplay\bin\xd_render_cli
```

对 **s63f / `dd6ab3d505827a94cbc9d59d7067fcce14db6fbe`**：

| 路径 | 本修订是否存在 | Dockerfile 是否使用 |
|---|---|---|
| `Dockerfile` | 是 | 是（构建文件本身） |
| `pyproject.toml` | 是 | `COPY` 进镜像；**不** `pip install -e` / **不** 读 lock |
| `docker/export_runtime_requirements.py` | **否** | 否 |
| `docker/strict-ocr` | **否**（只在 `resource-browser` / strict-* 分支，`git merge-base --is-ancestor cb7817009 prod/s63f` 为假） | 否 |
| `external/xdisplay/bin/xd_render_cli` | 是（源码 + Mach-O） | `COPY` 后 `rm -f` 二进制，用 `.pro`/`.cpp` 现编 |
| `uv.lock` | 是（打进源码包） | **否**（`.dockerignore` 排除） |
| `app/` `data/` `db/` | 是 | `app/` 有 COPY 但运行时被 bind-mount 覆盖；`data/` `db/` 被 dockerignore |

包装侧应改指纹为 Dockerfile **实际输入**（不要发明新构建步骤）：

- `Dockerfile`
- `pyproject.toml`
- `external/xdisplay/bin/xd_render_cli/` 目录（至少 `.pro` `main.cpp` `render_runner.cpp` `render_runner.h`）

**不要** 为过指纹而在 s63f 树上补 `docker/export_runtime_requirements.py` 或 `strict-ocr`。那会变成产品改动，且不是本镜像配方。

embedding 指纹保持 `Dockerfile.embedding` 即可（该文件自 `7f96f781` / 2026-04-27 未改）。旧 embedding/pg/redis tar 仍须按 `COMPANION_IMAGES.md` 核，不能只因旧 pin 文件存在就当 s63f。
