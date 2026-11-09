# s63f app image rebuild recipe (do not rename F3EECC91)

This cloud environment cannot read `github.com/molc/ai_orchestration` (GitHub 404 with the packaging token) and has no Docker. Parent’s Docker builder, which already has the approved repo, must produce the image. Do not label the existing `orches_orchestration-app_latest.tar` SHA256 `F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309` as s63f.

## Pin

- Repo: `https://github.com/molc/ai_orchestration`
- Branch: `codex/page-engineering-redesign` (for fetch only)
- Detach at tag `prod/s63f` **after** `git rev-parse HEAD` starts with `dd6ab3d50`
- Do **not** use branch HEAD

## Commands (Windows builder or Linux Docker host)

```bash
git fetch --tags origin
git checkout --detach prod/s63f
git rev-parse HEAD | grep -i '^dd6ab3d50' || exit 1
git submodule update --init --recursive
test -f Dockerfile && test -f app/main.py && test -f docker-compose.yml
printf '%s\n' "$(git rev-parse HEAD)" > SOURCE_REVISION.txt

docker build \
  --label "xdisplayai.packaging.git-sha=$(git rev-parse HEAD)" \
  --label "xdisplayai.packaging.tag=prod/s63f" \
  --tag "orches/orchestration-app:s63f-dd6ab3d50" \
  --tag "orches/orchestration-app:latest" \
  --file Dockerfile \
  .

docker image inspect orches/orchestration-app:s63f-dd6ab3d50 --format '{{.Id}} {{index .Config.Labels "xdisplayai.packaging.git-sha"}}'

docker save --output orches_orchestration-app_latest.tar orches/orchestration-app:s63f-dd6ab3d50
# record SHA256/SHA512/size of the tar; replace inputs/backend/images/orches_orchestration-app_latest.tar
# copy this SOURCE_REVISION.txt into inputs/backend/source/SOURCE_REVISION.txt together with the s63f source snapshot
```

Embedding / pgvector / redis tars may be reused **only after** comparing `Dockerfile.embedding`, compose image refs, and this tip. Until that fingerprint is recorded, they are unproven.

Runtime contract: the app image is the Python/runtime cache; `app/`, `data/`, prompts are the source snapshot bind-mounted at `/app`. Shipping an old image with new source, or new source without a matching image rebuild proof, is not s63f.
