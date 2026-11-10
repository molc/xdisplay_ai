#!/usr/bin/env bash
# Reassemble the s63f docker-save tar from 24MiB parts, then docker load.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# Prefer the cloud artifact store copy; fall back to this directory if parts were placed beside the script.
PARTS="${S63F_IMAGE_PARTS_DIR:-/cursor/stores/self/artifacts/s63f-app-image}"
if [ ! -f "$PARTS/orches_orchestration-app_latest.tar.part000" ]; then
  PARTS="$DIR"
fi
EXPECTED='35E5F27EEB4623B816120020116995216CBF2E601CD357ACC676A4384BE9E638'
OUT="${S63F_IMAGE_TAR:-$PWD/orches_orchestration-app_latest.tar}"
cat "$PARTS"/orches_orchestration-app_latest.tar.part??? > "$OUT"
ACTUAL="$(sha256sum "$OUT" | awk '{print toupper($1)}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "reassembled SHA256 $ACTUAL != $EXPECTED" >&2
  exit 1
fi
if [ "$ACTUAL" = "F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309" ]; then
  echo "refusing forbidden previous tar" >&2
  exit 1
fi
echo "reassembled $OUT sha256=$ACTUAL size=$(wc -c < "$OUT")"
if command -v docker >/dev/null 2>&1; then
  docker load --input "$OUT"
  docker image inspect orches/orchestration-app:s63f-dd6ab3d50 --format '{{.Id}} {{.Os}}/{{.Architecture}} {{index .Config.Labels "xdisplayai.packaging.git-sha"}}'
fi
