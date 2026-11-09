# s63f app image rebuild recipe

Parent Docker builder owns `rebuild-orches-app-image.sh`. This file is the packaging contract that script must satisfy. Cloud has no Docker and must not invent a Linux `xd_render_cli` ELF.

## Approved source

- Archive SHA256: `767E9305A7C9C6B57CE9220A971C9F1BE0F8102E46F9A8C67444203253B76A84`
- `SOURCE_REVISION.txt`: `dd6ab3d505827a94cbc9d59d7067fcce14db6fbe`
- `SOURCE_TAG.txt`: `prod/s63f`
- `SOURCE_SUBMODULE.txt` gitlink: `0c657ad3eac7ece814206bd40fea807ec6568f81`
- Do **not** use branch HEAD
- Do **not** label `orches_orchestration-app_latest.tar` SHA256 `F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309` as s63f

## What the tree actually builds

Dockerfile (python:3.11-slim-bookworm):

1. `qt_builder`: apt `build-essential g++ make pkg-config qt6-base-dev qmake6 libgl-dev`
2. `COPY external/xdisplay/bin/xd_render_cli` then **`rm -f xd_render_cli && qmake6 xd_render_cli.pro && make`**
3. Runtime stage: Qt6 libs, `COPY app`, `COPY pyproject.toml`, pip packages from Dockerfile (not `uv.lock`)
4. `playwright==1.56.0` and Chromium revision **1194** (`chromium-1194` and `chromium_headless_shell-1194`)

`.dockerignore` lists `uv.lock`. `docker/export_runtime_requirements.py` and `docker/strict-ocr` **do not exist**.

The sanctioned source archive **contains** `external/xdisplay/bin/xd_render_cli/xd_render_cli` 50200 bytes SHA256 `58618EC212229AC900E48304922AFD50EDFFD0F54CB325DCFA60F34382A606EA` (Mach-O 64-bit). That leftover is **not** a missing-binary block and **not** a required cached Linux ELF. Dockerfile deletes it and rebuilds on Debian.

Runtime compose bind-mounts `app/`, `data/`, `.env` over `/app`. SQL migrations `0001_init.sql` / `0002_rag.sql` / `0003_orch_runtime.sql` are separate inputs; no new data migration in this release. s63f still needs **both** a rebuilt app image and the `dd6ab3d50` source snapshot.

## Fingerprint inputs (must exist; Mach-O binary must not be required)

- `Dockerfile`
- `pyproject.toml`
- `.dockerignore`
- `external/xdisplay/bin/xd_render_cli/{main.cpp,render_runner.cpp,render_runner.h,xd_render_cli.pro,Makefile}`

## Commands the sanctioned rebuild script must perform

```bash
test "$(tr -d '[:space:]' < SOURCE_REVISION.txt)" = "dd6ab3d505827a94cbc9d59d7067fcce14db6fbe"
test "$(tr -d '[:space:]' < SOURCE_TAG.txt)" = "prod/s63f"
grep -q 0c657ad3eac7ece814206bd40fea807ec6568f81 SOURCE_SUBMODULE.txt
test ! -e docker/export_runtime_requirements.py
test ! -e docker/strict-ocr
grep -qx 'uv.lock' .dockerignore
# leftover Mach-O may or may not be present; do not fail if it is, do not require Linux ELF

docker build \
  --label "xdisplayai.packaging.git-sha=dd6ab3d505827a94cbc9d59d7067fcce14db6fbe" \
  --label "xdisplayai.packaging.tag=prod/s63f" \
  --label "xdisplayai.packaging.runtime-fingerprint=<sha256 from Get-SourceContentFingerprint>" \
  --tag "orches/orchestration-app:s63f-dd6ab3d50" \
  --tag "orches/orchestration-app:latest" \
  --tag "orches/orchestration-app:xdisplayai-runtime-cache" \
  --file Dockerfile \
  .

docker image inspect orches/orchestration-app:s63f-dd6ab3d50 \
  > orches_orchestration-app_latest.inspect.json
docker save --output orches_orchestration-app_latest.tar \
  orches/orchestration-app:s63f-dd6ab3d50
```

Companion inspect JSON must include:

- `Id`
- `RepoTags` containing `orches/orchestration-app:s63f-dd6ab3d50` and `orches/orchestration-app:latest`
- labels `xdisplayai.packaging.git-sha`, `xdisplayai.packaging.tag=prod/s63f`, `xdisplayai.packaging.runtime-fingerprint`

Place tar + inspect JSON under `inputs/backend/images/` and the source snapshot (with `SOURCE_REVISION.txt` / `SOURCE_TAG.txt` / `SOURCE_SUBMODULE.txt`) under `inputs/backend/source/`. Windows cached packaging then uses `-UseExistingBackendInputs` **without** pretending `-SkipBackendImageBuild` can reuse F3EECC91.

Embedding / pgvector / redis tars stay historical until inspect proves `Dockerfile.embedding` + `scripts/embedding_http_service.py` and compose image ids `pgvector/pgvector:pg15` / `redis:7`.
