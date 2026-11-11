import json, hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
m = json.load(open(root/'artifacts-dev.json', encoding='utf-8-sig'))
bad = 0
for e in m:
    p = root / e['relativePath']
    h = hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else ''
    ok = p.exists() and p.stat().st_size == e['sizeBytes'] and h == e['sha256'].lower()
    print(('OK  ' if ok else 'BAD ') + e['relativePath'], e['sizeBytes'])
    bad += (not ok)
extra = sorted(set(q.name for q in root.iterdir() if q.is_file()) - set(e['relativePath'] for e in m) - {'artifacts-dev.json'})
print('BAD_COUNT', bad, 'EXTRA_NOT_IN_MANIFEST', extra)
sys.exit(1 if bad else 0)
