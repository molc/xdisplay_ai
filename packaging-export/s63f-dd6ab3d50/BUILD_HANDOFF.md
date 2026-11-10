# s63f 构建交接包（小 artifact，不含 2.89MB 源码 tar）

父流程已核过源码包。本包只交 **配方 / 脚本 / 清单 / 无密钥 pins**，给 Linux/Windows Docker builder 原样执行，不要改 Dockerfile。

## 已核源码包（不在本小包内）

- 文件：`ai_orchestration-s63f-dd6ab3d50.tar.gz`
- SHA256：`767E9305A7C9C6B57CE9220A971C9F1BE0F8102E46F9A8C67444203253B76A84`
- size：2890098
- `SOURCE_REVISION.txt`：`dd6ab3d505827a94cbc9d59d7067fcce14db6fbe`
- tag：`prod/s63f`

## 本小包文件

| 文件 | 用途 |
|---|---|
| `BUILD_RECIPE.md` | 完整配方 |
| `rebuild-orches-app-image.sh` | `S63F_SOURCE_TAR=<已核 tar> ./rebuild-orches-app-image.sh` |
| `provenance.json` `key-file-hashes.json` `TAG_VERIFY.txt` `SOURCE_REVISION.txt` | 源/镜像 provenance |
| `XD_RENDER_CLI_PROOF.json` | 包内 Mach-O 实测 + Dockerfile 现编 Linux 的依据 |
| `WINDOWS_BINDMOUNT_AND_IMAGE_BASE.md` | 镜像烤什么 / workspace bind-mount 要什么 |
| `FINGERPRINT_CORRECTION.md` | 不要用 `docker/export_runtime_requirements.py` / `strict-ocr` |
| `image-pip-packages.from-Dockerfile.txt` | 真实 pip 清单 |
| `author-card-prompt-pins.env` | 提测卡 7 钉 + 90s |
| `sanitized-prompt-pins.env` | 生产行为整表（无密钥） |
| `COMPANION_IMAGES.md` | embedding/pg/redis known vs unknown |
| `citations/compose.windows.yml.tmpl` | 安装器 overlay 原文 |

## 父机一条命令

```bash
S63F_SOURCE_TAR=/path/to/ai_orchestration-s63f-dd6ab3d50.tar.gz \
  ./rebuild-orches-app-image.sh
```

脚本会校验源码包 SHA256，然后 `docker build -f Dockerfile .`（含 qt_builder 编 Linux `xd_render_cli`），`docker save` 出 `orches_orchestration-app_latest.tar`。禁止输出哈希为 `F3EECC91…`。

## 本环境未知 / 未做（不是无故卡住）

- **无 Docker** → 无新 app 镜像 tar、无从旧镜像抽 CLI
- **无 qmake6** → 无宿主机 Linux ELF；Linux CLI 的权威产物是镜像 stage 1
- 旧 embedding/pg/redis tar 的 image id **未知**（见 COMPANION_IMAGES.md）
- 未部署、未改业务代码、未合并、无密钥
