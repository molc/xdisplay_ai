# backend-export

s63f 后端离线安装器输入的来源记录。安装器本身不读取这个目录；它存在是为了让 `inputs/backend/*` 的每个字节都能追溯。

## s63f-dd6ab3d50/

来自 [ai_orchestration PR #13](https://github.com/molc/ai_orchestration/pull/13)（分支 `cursor/s63f-offline-backend-export-7db6`，提交 `baa7c8675`）的 `packaging-export/s63f-dd6ab3d50/` 原样拷贝：

- `ai_orchestration-s63f-dd6ab3d50.tar.gz`：`prod/s63f` = `dd6ab3d505827a94cbc9d59d7067fcce14db6fbe` 的无密钥源码快照（SHA256 `767E9305…`）。解压后即 `-BackendRepoPath`；`inputs/backend/source` 由 `ci/prepare-inputs.ps1` 从它同步。
- `rebuild-orches-app-image.sh` / `BUILD_RECIPE.md`：app 镜像配方。与 `manifests/pins/s63f-app-image-build-recipe.md` 一致。
- `image-build/`：PR #13 在云 VM 上构建过一次的 provenance（tar SHA256 `35E5F27E…`）。**该 tar 从未传回**，不是安装器使用的镜像。
- `builder-image/orches_orchestration-app_latest.inspect.json`：**实际进入 0.1.4 安装器的 app 镜像**，在 `win11-wsl2-builder` 的 Docker Desktop 上按同一配方从同一源码快照构建（2026-11-09），tar SHA256 `514ACD60…`，标签 `git-sha=dd6ab3d50… / tag=prod/s63f / runtime-fingerprint=5f1b3896…`。对应 pin 在 `manifests/pins/offline-inputs.s63f.json` 的 `files[]` 与 `backend.appImage`。

## 重建时

1. 解压源码包到 builder（例如 `T:\work\backend`），确认 `SOURCE_REVISION.txt` / `SOURCE_TAG.txt` / `SOURCE_SUBMODULE.txt` 在根目录。
2. 在 builder 的交互用户会话里运行 `build-offline-package.ps1 -SkipClientBuild -BackendRepoPath <解压目录> ...`（会自己 `docker build` 并写出 `*.inspect.json`），或按 `rebuild-orches-app-image.sh` 手工构建后用 `-UseExistingBackendInputs`。
3. 镜像 tar 的 SHA256 每次重建都会变；把新值写回 `offline-inputs.s63f.json` 的 `files[]`，否则缓存模式的输入门会按旧 pin 拒绝。
