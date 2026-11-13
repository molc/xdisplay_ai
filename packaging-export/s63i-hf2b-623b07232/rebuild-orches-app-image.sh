#!/usr/bin/env bash
# Rebuild orches/orchestration-app from the s63i-hf2b snapshot.
# Do not invent a different Dockerfile.
# Do not retag F3EECC91… / 514ACD60… / 35E5F27E… as this card.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TAR="${S63I_HF2B_SOURCE_TAR:-$ROOT/ai_orchestration-s63i-hf2b-623b07232.sanitized.tar.gz}"
EXPECTED_SOURCE_SHA="${EXPECTED_SOURCE_SHA:-68B6E331A6942A9CBDE6FDDFA7579E1AD8227B57C1D05E0D6C724F32A8317278}"
REQUIRED_PREFIX='623b07232'
REQUIRED_TAG='prod/s63i-hf2'
FORBIDDEN_APP_SHA_LIST=(
  'F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309'
  '514ACD60DF0D7D6FAB00684116F9F863A6A58F161A4C9BAF73CFAD76E0B83A24'
  '35E5F27EEB4623B816120020116995216CBF2E601CD357ACC676A4384BE9E638'
)
WORK="${S63I_HF2B_BUILD_WORK:-$(mktemp -d /tmp/s63i-hf2b-app-image.XXXXXX)}"

if [ -z "$EXPECTED_SOURCE_SHA" ] || [ "$EXPECTED_SOURCE_SHA" = "PENDING" ]; then
  echo "EXPECTED_SOURCE_SHA missing. Use the verified sanitized archive SHA 68B6E331…." >&2
  exit 1
fi

if [ ! -f "$TAR" ]; then
  echo "missing source archive: $TAR" >&2
  echo "set S63I_HF2B_SOURCE_TAR to the parent-verified archive for $REQUIRED_PREFIX / $REQUIRED_TAG" >&2
  exit 1
fi
ACTUAL_SOURCE_SHA="$(sha256sum "$TAR" | awk '{print toupper($1)}')"
EXPECTED_SOURCE_SHA_UPPER="$(printf '%s' "$EXPECTED_SOURCE_SHA" | tr '[:lower:]' '[:upper:]')"
if [ "$ACTUAL_SOURCE_SHA" != "$EXPECTED_SOURCE_SHA_UPPER" ]; then
  echo "source archive SHA256 $ACTUAL_SOURCE_SHA != expected $EXPECTED_SOURCE_SHA_UPPER" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required on the builder host; this export cloud env did not have docker." >&2
  exit 1
fi

mkdir -p "$WORK"
tar -C "$WORK" -xzf "$TAR"
SRC="$WORK/ai_orchestration-s63i-hf2b-623b07232"
if [ ! -d "$SRC" ]; then
  # tolerate a single top-level directory name if parent used a different unpack folder
  SRC="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
fi
cd "$SRC"

REV="$(tr -d '[:space:]' < SOURCE_REVISION.txt)"
case "$REV" in
  ${REQUIRED_PREFIX}*) ;;
  *)
    echo "SOURCE_REVISION '$REV' is not $REQUIRED_PREFIX / $REQUIRED_TAG" >&2
    exit 1
    ;;
esac

test -f Dockerfile
test -f app/main.py
test -f docker-compose.yml
test -f external/xdisplay/bin/xd_render_cli/xd_render_cli.pro
test -f pyproject.toml

docker build \
  --label "xdisplayai.packaging.git-sha=${REV}" \
  --label "xdisplayai.packaging.tag=${REQUIRED_TAG}" \
  --tag "orches/orchestration-app:s63i-hf2b-${REQUIRED_PREFIX}" \
  --tag "orches/orchestration-app:latest" \
  --file Dockerfile \
  .

docker image inspect "orches/orchestration-app:s63i-hf2b-${REQUIRED_PREFIX}" \
  --format '{{.Id}} {{index .Config.Labels "xdisplayai.packaging.git-sha"}}'

OUT="${S63I_HF2B_IMAGE_TAR:-$PWD/../orches_orchestration-app_latest.tar}"
mkdir -p "$(dirname "$OUT")"
docker save --output "$OUT" "orches/orchestration-app:s63i-hf2b-${REQUIRED_PREFIX}"

HASH="$(sha256sum "$OUT" | awk '{print toupper($1)}')"
SIZE="$(wc -c < "$OUT" | tr -d ' ')"
echo "wrote $OUT"
echo "sha256=$HASH"
echo "sizeBytes=$SIZE"

for forbidden in "${FORBIDDEN_APP_SHA_LIST[@]}"; do
  if [ "$HASH" = "$forbidden" ]; then
    echo "refusing: rebuilt tar hashed to a forbidden previous image identity $forbidden" >&2
    exit 1
  fi
done
