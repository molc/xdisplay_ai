# 包装指纹必须跟 Dockerfile 与本修订实际输入

对 **s63i-hf2b 卡 / 已验证 Git 标签 `prod/s63i-hf2` / `623b072320d2e8c68059ec5e7e33958267203a9c`**：

相对 s63f，`Dockerfile` 与 `pyproject.toml` 已变，且 **`docker/strict-ocr/*` 为新增**。旧 app 镜像与 fingerprint `5f1b3896…` **不兼容**，禁止复用。

## 运行时指纹输入（完整列表；不要发明指纹 *值*）

父机构建时用落地后的 `ci/Common.ps1` `Get-SourceContentFingerprint` / 安装侧 `Get-PathContentFingerprint -IncludeInputRows` 计算：

- `Dockerfile`
- `pyproject.toml`
- `.dockerignore`
- `external/xdisplay/bin/xd_render_cli/main.cpp`
- `external/xdisplay/bin/xd_render_cli/render_runner.cpp`
- `external/xdisplay/bin/xd_render_cli/render_runner.h`
- `external/xdisplay/bin/xd_render_cli/xd_render_cli.pro`
- `external/xdisplay/bin/xd_render_cli/Makefile`
- `docker/strict-ocr/LICENSE-APACHE-2.0.txt`
- `docker/strict-ocr/NOTICE.md`
- `docker/strict-ocr/fetch_models.py`
- `docker/strict-ocr/model-manifest.json`

## 仍不是输入

- `docker/export_runtime_requirements.py`（本修订仍不使用）

**不要** 抄写 s63f runtime-fingerprint `5f1b3896…` 当作本卡指纹。
