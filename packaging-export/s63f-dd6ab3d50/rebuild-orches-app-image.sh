#!/usr/bin/env bash
# Rebuild orches/orchestration-app from the s63f snapshot. Do not invent a
# different Dockerfile. Do not retag F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TAR="${S63F_SOURCE_TAR:-$ROOT/ai_orchestration-s63f-dd6ab3d50.tar.gz}"
EXPECTED_SOURCE_SHA='767E9305A7C9C6B57CE9220A971C9F1BE0F8102E46F9A8C67444203253B76A84'
REQUIRED_PREFIX='dd6ab3d50'
FORBIDDEN_APP_SHA='F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309'
WORK="${S63F_BUILD_WORK:-$(mktemp -d /tmp/s63f-app-image.XXXXXX)}"

if [ ! -f "$TAR" ]; then
  echo "missing source archive: $TAR" >&2
  echo "set S63F_SOURCE_TAR to the parent-verified 2890098-byte tar (SHA256 $EXPECTED_SOURCE_SHA)" >&2
  exit 1
fi
ACTUAL_SOURCE_SHA="$(sha256sum "$TAR" | awk '{print toupper($1)}')"
if [ "$ACTUAL_SOURCE_SHA" != "$EXPECTED_SOURCE_SHA" ]; then
  echo "source archive SHA256 $ACTUAL_SOURCE_SHA != expected $EXPECTED_SOURCE_SHA" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required on the builder host; this export cloud env did not have docker." >&2
  exit 1
fi

mkdir -p "$WORK"
tar -C "$WORK" -xzf "$TAR"
SRC="$WORK/ai_orchestration-s63f-dd6ab3d50"
cd "$SRC"

REV="$(tr -d '[:space:]' < SOURCE_REVISION.txt)"
case "$REV" in
  ${REQUIRED_PREFIX}*) ;;
  *)
    echo "SOURCE_REVISION '$REV' is not $REQUIRED_PREFIX / prod/s63f" >&2
    exit 1
    ;;
esac

test -f Dockerfile
test -f app/main.py
test -f docker-compose.yml
test -f external/xdisplay/bin/xd_render_cli/xd_render_cli.pro
test -f pyproject.toml

# Packaging fingerprint files docker/export_runtime_requirements.py and
# docker/strict-ocr are NOT in this revision. Do not call the xdisplay_ai
# prepare-inputs.ps1 runtime-cache fingerprint path against this tree.

docker build \
  --label "xdisplayai.packaging.git-sha=${REV}" \
  --label "xdisplayai.packaging.tag=prod/s63f" \
  --tag "orches/orchestration-app:s63f-${REQUIRED_PREFIX}" \
  --tag "orches/orchestration-app:latest" \
  --file Dockerfile \
  .

docker image inspect "orches/orchestration-app:s63f-${REQUIRED_PREFIX}" \
  --format '{{.Id}} {{index .Config.Labels "xdisplayai.packaging.git-sha"}}'

OUT="${S63F_IMAGE_TAR:-$PWD/../orches_orchestration-app_latest.tar}"
mkdir -p "$(dirname "$OUT")"
docker save --output "$OUT" "orches/orchestration-app:s63f-${REQUIRED_PREFIX}"

HASH="$(sha256sum "$OUT" | awk '{print toupper($1)}')"
SIZE="$(wc -c < "$OUT" | tr -d ' ')"
echo "wrote $OUT"
echo "sha256=$HASH"
echo "sizeBytes=$SIZE"

if [ "$HASH" = "$FORBIDDEN_APP_SHA" ]; then
  echo "refusing: rebuilt tar hashed to the forbidden previous 0.1.4 image" >&2
  exit 1
fi
