# Companion images vs s63i-hf2b `623b072320d2e8c68059ec5e7e33958267203a9c`

## Status: PENDING parent Linux amd64 docker-save + inspect

Do **not** copy these s63f / historical identities into the s63i-hf2b pin manifest as proven:

| tar | historical SHA256 | for this card |
|---|---|---|
| `orches_orchestration-app_latest.tar` | `514ACD60…` (s63f packaged) / `35E5F27E…` (cloud) / `F3EECC91…` (forbidden) | **FORBIDDEN to reuse as s63i-hf2b** |
| `orches_embedding-http_latest.tar` | `E0619999…` | unproven until inspect vs 623b07232 tree |
| `pgvector_pgvector_pg15.tar` | `D9C6F2F1…` | unproven until inspect |
| `redis_7.tar` | `1E7BE24D…` | unproven until inspect |

Parent must supply exact four Linux amd64 image tars with inspect records before cached packaging can pass.

## App image — must rebuild from 623b07232

- Source snapshot + Dockerfile pair required.
- Labels required: `xdisplayai.packaging.git-sha`, `xdisplayai.packaging.tag=prod/s63i-hf2`, `xdisplayai.packaging.runtime-fingerprint`.
- Companion tags: `orches/orchestration-app:s63i-hf2b-623b07232` and `orches/orchestration-app:latest`.

## Fingerprint inputs (do not require missing legacy paths)

Fingerprint inputs: Dockerfile, pyproject.toml, .dockerignore, xd_render_cli build files, **and** `docker/strict-ocr/{LICENSE-APACHE-2.0.txt,NOTICE.md,fetch_models.py,model-manifest.json}`. Do **not** require `docker/export_runtime_requirements.py`. Do **not** invent the fingerprint value.
