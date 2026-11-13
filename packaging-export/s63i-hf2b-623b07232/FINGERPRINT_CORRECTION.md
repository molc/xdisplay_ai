# 包装指纹必须跟 Dockerfile，不能跟不存在的路径

对 **s63i-hf2b / `623b072320d2e8c68059ec5e7e33958267203a9c`**，沿用已验证的指纹输入集合（与 s63f 纠正后一致），除非父机在源树证明不同：

- `Dockerfile`
- `pyproject.toml`
- `.dockerignore`
- `external/xdisplay/bin/xd_render_cli/main.cpp`
- `external/xdisplay/bin/xd_render_cli/render_runner.cpp`
- `external/xdisplay/bin/xd_render_cli/render_runner.h`
- `external/xdisplay/bin/xd_render_cli/xd_render_cli.pro`
- `external/xdisplay/bin/xd_render_cli/Makefile`

**不要** 要求 `docker/export_runtime_requirements.py` 或 `docker/strict-ocr`。
**不要** 抄写 s63f runtime-fingerprint `5f1b3896…` 当作本卡指纹。
