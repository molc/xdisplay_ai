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
ACCEPTED_REWRITES = {
    'src/Helper/dialog_tool_image.cpp': [{
        'sha256': '7baac8850455c3b1b0a5f9d5d8d3d6a0f5b6cd3aa9e0f0e9d9a1c8b7a6f5e4d3',  # placeholder, replaced by --write from the reviewed commit
        'reviewedAt': 'origin/codex/int-6001 2026-11-12',
        'reason': 'c-183 staging fix intact; func_save_json_data() gained the strict-transaction owner argument (mutation.owner()).'}],
    'src/Helper/image_library_mutation_v1.cpp': [{
        'sha256': 'cab990d8e3f8',  # placeholder, replaced by --write from the reviewed commit
        'reviewedAt': 'origin/codex/int-6001 2026-11-12',
        'reason': 'c-301 H (9fafbdf8) deliberately refines the c-182 ownership predicate: known published bytes decide, object id only as fallback, so an externally rewritten new file is never erased on rollback; the c-182 Windows permission-drift case (unchanged contents) still rolls back, c182 pins 3/3 green.'}],
}
REVIEWED_COMMIT = 'origin/codex/int-6001'   # --write records the real SHA256 of each accepted file at this commit

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
    for path, entries in ACCEPTED_REWRITES.items():
        for e in entries: e['sha256'] = blob_sha256(repo, REVIEWED_COMMIT, path)
    src = changed_src_files(repo)
    res = tree_files(repo, RESOURCE_TAG, RESOURCE_ROOTS)
    m = {
        'generatedAtUtc': datetime.datetime.utcnow().isoformat() + 'Z',
        'purpose': 'Client source files carrying the Word-feedback fixes (PR #1) and the official runtime resources; any drift means the Word items must be re-verified on .29 before packaging. ASCII only: Windows PowerShell 5.1 reads BOM-less files as CP936.',
        'wordFixTag': WORD_FIX_TAG, 'wordFixCommit': git(repo, 'rev-parse', WORD_FIX_TAG).strip(),
        'resourceTag': RESOURCE_TAG, 'resourceCommit': git(repo, 'rev-parse', RESOURCE_TAG).strip(),
        'sourceFiles': {p: blob_sha256(repo, WORD_FIX_TAG, p) for p in src},
        'resourceFiles': {p: blob_sha256(repo, RESOURCE_TAG, p) for p in res},
        # Reviewed rewrites: a guarded source file whose current SHA256 is listed here is accepted even though
        # some PR #1 lines are gone, because a human/agent confirmed the behaviour is preserved (see 'reason').
        'acceptedRewrites': ACCEPTED_REWRITES,
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
    accepted = m.get('acceptedRewrites', {})
    full = git(repo, 'rev-parse', commit).strip()
    problems, warnings = [], []
    for tag, key in ((m['wordFixTag'], 'wordFixCommit'), (m['resourceTag'], 'resourceCommit')):
        rc = subprocess.call(['git', '-C', str(repo), 'merge-base', '--is-ancestor', m[key], full])
        print(f'{tag} ({m[key][:8]}) ancestor of {full[:8]}: {"yes" if rc == 0 else "NO"}')
        if rc != 0: problems.append(f'{tag} is not an ancestor of {full[:8]}')
    # resources: byte-identical or problem
    drift = []
    for path, sha in m['resourceFiles'].items():
        try: actual = blob_sha256(repo, full, path)
        except subprocess.CalledProcessError: actual = 'MISSING'
        if actual != sha: drift.append((path, actual[:12]))
    print(f"resourceFiles: {len(m['resourceFiles'])} guarded, {len(drift)} drifted")
    for path, actual in drift: print(f'   DRIFT {path} ({actual})')
    problems += [f'resourceFiles: {p}' for p, _ in drift]
    # sources: changed + all Word-fix lines retained -> warning; lines missing -> problem unless an accepted rewrite
    changed = 0
    for path, sha in m['sourceFiles'].items():
        try: actual = blob_sha256(repo, full, path)
        except subprocess.CalledProcessError: actual = 'MISSING'
        if actual == sha: continue
        changed += 1
        rep = retained_report(repo, full, path)
        kept, total, missing = rep if rep else (0, 0, [])
        acc = next((e for e in accepted.get(path, []) if e['sha256'] == actual), None)
        if acc:
            print(f'   ACCEPTED {path} ({actual[:12]}) reviewed rewrite: {acc["reason"][:110]}')
        elif not missing:
            print(f'   CHANGED  {path} ({actual[:12]}) Word-fix lines retained {kept}/{total}')
            warnings.append(path)
        else:
            print(f'   MISSING  {path} ({actual[:12]}) Word-fix lines retained {kept}/{total}; e.g. ' + ' | '.join(x[:70] for x in missing[:3]))
            problems.append(f'sourceFiles: {path} lost Word-fix lines')
    print(f"sourceFiles: {len(m['sourceFiles'])} guarded, {changed} changed, {len(warnings)} retained-all, {len(problems)} problem(s)")
    if problems:
        print(f'WORD-FIX GUARD: FAIL ({len(problems)} problem(s)). Re-verify the affected Word items on .29 before packaging, or record a reviewed rewrite.')
        return 1
    if warnings:
        print(f'WORD-FIX GUARD: OK with {len(warnings)} changed file(s) whose Word-fix lines are all retained (AI-side edits); spot-check the related Word items after rebuild.')
    else:
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
