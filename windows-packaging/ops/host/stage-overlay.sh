#!/bin/bash
# usage: stage-overlay.sh <run> <base-commit> [overlay-root]
# Stages every windows-packaging file changed between <base-commit> (what the builder tree currently equals) and HEAD
# under <overlay-root>/<run>/ with a manifest.json of SHA256s, for ops/builder/Sync-SourceOverlay.ps1.
# Serve <overlay-root> with: (cd <overlay-root> && python3 -m http.server 18049 --bind 172.19.103.18)
set -euo pipefail
RUN="${1:?run id}"; BASE="${2:?base commit}"; ROOT="${3:-/dev/shm/xdai-overlay}"
REPO="$(git rev-parse --show-toplevel)"; cd "$REPO/windows-packaging"
DST="$ROOT/$RUN"; rm -rf "$DST"; mkdir -p "$DST"
python3 - "$BASE" "$DST" <<'PY'
import subprocess, sys, pathlib, hashlib, json, shutil
base, dst = sys.argv[1], pathlib.Path(sys.argv[2])
files = [l for l in subprocess.check_output(['git','diff','--name-only','--relative','--diff-filter=ACMR',base,'HEAD','--','.'],text=True).split('\n') if l]
files = [f for f in files if not f.startswith(('acceptance/','ops/','backend-export/')) and not f.endswith('.md')]
man = {}
for f in files:
    src = pathlib.Path(f); (dst/src).parent.mkdir(parents=True, exist_ok=True); shutil.copy2(src, dst/src)
    man[f] = hashlib.sha256(src.read_bytes()).hexdigest().upper()
(dst/'manifest.json').write_text(json.dumps({'files': man}, indent=1), encoding='utf-8')
print(f'staged {len(man)} file(s) into {dst}'); [print('  ', f) for f in man]
PY
