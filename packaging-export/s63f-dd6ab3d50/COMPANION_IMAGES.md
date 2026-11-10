# Companion images vs s63f `dd6ab3d505827a94cbc9d59d7067fcce14db6fbe`

Packaging currently pins (xdisplay_ai `offline-inputs.0.1.4.json`, commit `04e713f22c5498143180315c632c039b125a0bff`):

| tar | sizeBytes | SHA256 |
|---|---:|---|
| `orches_embedding-http_latest.tar` | 177215488 | `E0619999C03EBF1D1EC78B5D2CB28438EC9C16D15151BF12D796F5DF835ADE9E` |
| `pgvector_pgvector_pg15.tar` | 439424512 | `D9C6F2F1AE5A7B320676553213163D813459FC7E232CD5C5CCE85376FEABF9F6` |
| `redis_7.tar` | 120237056 | `1E7BE24D93E435854DB82113E45D9F68DD12540C82E975AB382C7D3ABBB54CF7` |
| `orches_orchestration-app_latest.tar` | 1898128384 | `F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309` **FORBIDDEN as s63f** |

This cloud environment has **no Docker** (`command -v docker` empty). Those tars are not present here, so their internal image IDs are **UNKNOWN**.

## App image — must rebuild

- **FACT:** author card + packaging gate require a new `orches/orchestration-app:latest` from this revision.
- **FACT:** the previous tar `F3EECC91…` must not be renamed / relabeled as s63f.
- **FACT:** this executor did not produce a new app tar (no Docker). Parent must run `rebuild-orches-app-image.sh` (or the same `docker build` / `docker save` in `BUILD_RECIPE.md`).

## Embedding — source-compatible, tar bytes unproven

Files at this revision:

| file | last commit touching it | date | sha256 of file at this tip |
|---|---|---|---|
| `Dockerfile.embedding` | `7f96f7818fb65cad1173cfc2020235050bc4e3d3` | 2026-04-27 | `5000ee5cce85105342ef9d8f62a3a2eb3fcaffeac41e30370fda60697c469a6e` |
| `scripts/embedding_http_service.py` | same `7f96f781` | 2026-04-27 | `801a95cb457771ed4a4b5140f6473b0f8e88c3527d2930d284e01a4035e9e1a6` |
| compose service image | `orches/embedding-http:latest` | — | compose file sha256 `9d273caffeb693fc8090803ea7bce1d4791311c028d4f779cdc9a61a32a5121e` |

- **FACT:** embedding Dockerfile copies only `scripts/embedding_http_service.py`, base `python:3.11-slim`, pip `fastapi "uvicorn[standard]" pydantic`.
- **FACT:** those two source files last changed in April 2026, long before s63f.
- **INFERENCE / UNKNOWN:** whether `E0619999…` was actually `docker save` of an image built from those exact files. Reuse is allowed only after parent compares `docker image inspect` / rebuild fingerprint. Cheap rebuild from this snapshot is the proof path.

xdisplay_ai `Get-EmbeddingRuntimeFingerprintPaths` = `@('Dockerfile.embedding')` only.

## Postgres / Redis — compose refs unchanged, tar identity unknown

From `docker-compose.yml` at this tip:

```
postgres:  image: pgvector/pgvector:pg15
redis:     image: redis:7
```

- **FACT:** compose still names those two public tags. Last compose-file commit on this tip: `4967fe9e6d785b8547b3e47b19d6dac83c65c17d` (2026-06-02).
- **UNKNOWN:** whether the existing `D9C6F2F1…` / `1E7BE24D…` tars are docker-save of those exact tags on the builder (image ID / registry digest not inspectable here).
- Parent may reuse those two tars **only after** `docker load` + `docker image inspect` shows `pgvector/pgvector:pg15` and `redis:7`. Do not claim s63f provenance merely because the old pin file lists them.

## Packaging cache trap (do not use on this tree)

xdisplay_ai `Get-OrchestrationAppRuntimeFingerprintPaths` expects:

- `Dockerfile`
- `pyproject.toml`
- `docker\export_runtime_requirements.py`
- `docker\strict-ocr`
- `external\xdisplay\bin\xd_render_cli`

**FACT:** `docker/export_runtime_requirements.py` and `docker/strict-ocr` are **absent** at `prod/s63f`. `docker/strict-ocr` exists only on `resource-browser` / strict-* branches (`cb7817009`); `git merge-base --is-ancestor cb7817009 prod/s63f` is false.

Therefore `prepare-inputs.ps1` `Build-BackendImagesFromSource` fingerprinting **will throw** on this snapshot. Use the raw `docker build -f Dockerfile .` in `rebuild-orches-app-image.sh`. Do not pass `-SkipBackendImageBuild`.
