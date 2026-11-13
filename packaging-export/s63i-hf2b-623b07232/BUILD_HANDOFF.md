# s63i-hf2b 构建交接包（metadata only；无源码 tar / 无 docker-save）

父流程尚未交付已核源码包与四镜像.inspect。本目录只交 **配方 / 脚本 / 清单 / 无密钥 pins**，给后续 Linux/Windows Docker builder 原样执行，不要改 Dockerfile。

## 待核源码包（不在本小包内）

- 文件：`ai_orchestration-s63i-hf2b-623b07232.sanitized.tar.gz`
- SHA256：`68B6E331A6942A9CBDE6FDDFA7579E1AD8227B57C1D05E0D6C724F32A8317278`（3205603 bytes；禁止进 git）
- `SOURCE_REVISION.txt`：`623b072320d2e8c68059ec5e7e33958267203a9c`
- tag：`prod/s63i-hf2`

## 本小包文件

| 文件 | 用途 |
|---|---|
| `BUILD_RECIPE.md` | 完整配方 |
| `rebuild-orches-app-image.sh` | 校验已核源码 SHA；构建镜像 |
| `provenance.json` `TAG_VERIFY.txt` `SOURCE_REVISION.txt` | 源/镜像 provenance |
| `WINDOWS_BINDMOUNT_AND_IMAGE_BASE.md` | 镜像烤什么 / workspace bind-mount 要什么 |
| `FINGERPRINT_CORRECTION.md` | 指纹输入含 `docker/strict-ocr/*`；不要用 `export_runtime_requirements.py` |
| `image-pip-packages.from-Dockerfile.txt` | 历史 Dockerfile pip 清单（待父机在 623b07232 上复核） |
| `author-card-prompt-pins.env` | 提测卡钉（PAGE_HTML v20 / link v1.10） |
| `sanitized-prompt-pins.env` | 行为键整表（无密钥） |
| `COMPANION_IMAGES.md` | embedding/pg/redis pending |
| `citations/compose.windows.yml.tmpl` | 安装器 overlay 原文 |

## 父机一条命令（哈希齐备后）

```bash
S63I_HF2B_SOURCE_TAR=/path/to/ai_orchestration-s63i-hf2b-623b07232.sanitized.tar.gz \
  ./rebuild-orches-app-image.sh
```

## 本环境未知 / 未做

- 源码 archive SHA 已核；**无** docker-save / Windows c186 exe 哈希
- **无 Docker** → 无新 app / companion 镜像 tar
- **无** Windows c186 release → 无 Windows 客户端 SHA/size
- 未部署、未改 `.21`、未跑 `.29` 验收、无密钥
