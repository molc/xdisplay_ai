#!/usr/bin/env python3
"""Word-fix guard: freeze the client files that carry the 莫工 Word feedback fixes and the official runtime resources.

  --write                 regenerate manifests/pins/word-fix-guard.json from the client repo tags
  --check <commit-ish>    verify a client commit before it is synced to the builder:
                          (1) client/c-185 (PR #1 Word fixes) and client/c-184 (resources) are ancestors,
                          (2) every guarded source file is byte-identical to its c-185 version,
                          (3) every guarded resource file is byte-identical to its c-184 version.
Exit 1 on any drift, listing the files; a drift is not forbidden, it means the Word items must be re-verified on .29
and the manifest regenerated on purpose (--write) with that decision recorded in the commit message.
"""
import argparse, hashlib, json, pathlib, subprocess, sys, datetime
here = pathlib.Path(__file__).resolve()
manifest_path = here.parents[2] / 'manifests' / 'pins' / 'word-fix-guard.json'
WORD_FIX_TAG = 'client/c-185'      # PR #1: c-181 (7 Word items + 转换工具白窗), c-182, c-183
RESOURCE_TAG = 'client/c-184'      # official 2.4.4 runtime resources tracked in the repo
RESOURCE_ROOTS = ['data', 'res', 'images', 'doc', 'qrcode_about.jpg', 'logo.png', 'logo_about.png']

def git(repo, *args):
    return subprocess.check_output(['git', '-c', 'core.quotepath=off', '-C', str(repo), *args], text=True)

def blob_sha256(repo, commit, path):
    data = subprocess.check_output(['git', '-C', str(repo), 'show', f'{commit}:{path}'], stderr=subprocess.DEVNULL)
    return hashlib.sha256(data).hexdigest()

def changed_src_files(repo):
    base = git(repo, 'rev-parse', 'client/c-180').strip()
    out = git(repo, 'diff', '--name-only', '--diff-filter=ACMR', base, WORD_FIX_TAG, '--', 'src')
    return sorted(l for l in out.split('\n') if l)

def tree_files(repo, commit, roots):
    files = []
    for root in roots:
        out = git(repo, 'ls-tree', '-r', '--name-only', commit, '--', root)
        files += [l for l in out.split('\n') if l]
    return sorted(set(files))

def write(repo):
    src = changed_src_files(repo)
    res = tree_files(repo, RESOURCE_TAG, RESOURCE_ROOTS)
    m = {
        'generatedAtUtc': datetime.datetime.utcnow().isoformat() + 'Z',
        'purpose': 'Client source files carrying the Word-feedback fixes (PR #1) and the official runtime resources; any drift means the Word items must be re-verified on .29 before packaging. ASCII only: Windows PowerShell 5.1 reads BOM-less files as CP936.',
        'wordFixTag': WORD_FIX_TAG, 'wordFixCommit': git(repo, 'rev-parse', WORD_FIX_TAG).strip(),
        'resourceTag': RESOURCE_TAG, 'resourceCommit': git(repo, 'rev-parse', RESOURCE_TAG).strip(),
        'sourceFiles': {p: blob_sha256(repo, WORD_FIX_TAG, p) for p in src},
        'resourceFiles': {p: blob_sha256(repo, RESOURCE_TAG, p) for p in res},
    }
    manifest_path.write_text(json.dumps(m, indent=1, ensure_ascii=True) + '\n', encoding='utf-8')
    print(f'wrote {manifest_path}: {len(src)} source files, {len(res)} resource files')

def word_fix_added_lines(repo, path):
    """Non-trivial lines PR #1 added to a file (c-180 -> c-185); these are the lines a merge must not lose."""
    base = git(repo, 'rev-parse', 'client/c-180').strip()
    try: diff = git(repo, 'diff', base, WORD_FIX_TAG, '--', path)
    except subprocess.CalledProcessError: return []
    lines = []
    for l in diff.split('\n'):
        if l.startswith('+') and not l.startswith('+++'):
            t = l[1:].strip()
            if len(t) >= 12 and not t.startswith(('//', '*', '/*')): lines.append(t)
    return sorted(set(lines))

def retained_report(repo, commit, path):
    added = word_fix_added_lines(repo, path)
    if not added: return None
    try: now = subprocess.check_output(['git', '-C', str(repo), 'show', f'{commit}:{path}'], stderr=subprocess.DEVNULL).decode('utf-8', 'replace')
    except subprocess.CalledProcessError: return (0, len(added), added[:5])
    missing = [l for l in added if l not in now]
    return (len(added) - len(missing), len(added), missing[:5])

def check(repo, commit):
    m = json.loads(manifest_path.read_text(encoding='utf-8'))
    full = git(repo, 'rev-parse', commit).strip()
    problems = []
    for tag, key in ((m['wordFixTag'], 'wordFixCommit'), (m['resourceTag'], 'resourceCommit')):
        rc = subprocess.call(['git', '-C', str(repo), 'merge-base', '--is-ancestor', m[key], full])
        print(f'{tag} ({m[key][:8]}) ancestor of {full[:8]}: {"yes" if rc == 0 else "NO"}')
        if rc != 0: problems.append(f'{tag} is not an ancestor of {full[:8]}')
    for section in ('sourceFiles', 'resourceFiles'):
        drift = []
        for path, sha in m[section].items():
            try: actual = blob_sha256(repo, full, path)
            except subprocess.CalledProcessError: actual = 'MISSING'
            if actual != sha: drift.append((path, actual[:12]))
        print(f'{section}: {len(m[section])} guarded, {len(drift)} drifted')
        for path, actual in drift:
            line = f'   DRIFT {path} ({actual})'
            if section == 'sourceFiles':
                rep = retained_report(repo, full, path)
                if rep:
                    kept, total, missing = rep
                    line += f'  Word-fix lines retained {kept}/{total}'
                    if missing: line += '  MISSING e.g. ' + ' | '.join(x[:70] for x in missing[:3])
            print(line)
        problems += [f'{section}: {p}' for p, _ in drift]
    if problems:
        print(f'WORD-FIX GUARD: {len(problems)} problem(s). Re-verify the Word items on .29 before packaging this commit.')
        return 1
    print('WORD-FIX GUARD: OK (Word-fix sources and official resources are intact at this commit)')
    return 0

if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', default=str(pathlib.Path.home() / 'Documents/tricolor_work/xdisplay'))
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--write', action='store_true'); g.add_argument('--check', metavar='COMMIT')
    a = ap.parse_args()
    if a.write: write(a.repo)
    else: sys.exit(check(a.repo, a.check))
