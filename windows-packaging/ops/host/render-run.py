#!/usr/bin/env python3
"""Render the .29 acceptance scripts and the evidence generator for one packaging run.

usage: render-run.py --run r12 --bundle-sha <sha256 of XDisplayAI-0.1.4-dev.exe> --http-port 18055 \
                     --packaging-commit <8-40 hex> --share /tmp/xdisplay29-rdp-results/xdai --host-dir /tmp/xdai-s63f

The .ps1 files are written with a UTF-8 BOM (Windows PowerShell 5.1 otherwise reads the Chinese literals as CP936
and dies with parse errors before writing anything). Nothing is overwritten unless --force is given.
"""
import argparse, pathlib, re, sys
here = pathlib.Path(__file__).resolve().parent
templates = here.parent / 'dot29' / 'templates'
ap = argparse.ArgumentParser()
ap.add_argument('--run', required=True, help='run id, lowercase, e.g. r12')
ap.add_argument('--bundle-sha', required=True, help='sha256 (hex) of the built XDisplayAI-0.1.4-dev.exe')
ap.add_argument('--http-port', required=True, type=int, help='port on 172.19.103.18 serving the run\'s dist for .29')
ap.add_argument('--packaging-commit', required=True, help='windows-packaging commit the run was built from')
ap.add_argument('--share', default='/tmp/xdisplay29-rdp-results/xdai', help='RDP drive dir seen by .29 as \\\\tsclient\\results\\xdai')
ap.add_argument('--host-dir', default='/tmp/xdai-s63f', help='where make-evidence-<run>.py is written on the host')
ap.add_argument('--force', action='store_true')
a = ap.parse_args()
if not re.fullmatch(r'r\d+', a.run): sys.exit('run id must look like r12')
if not re.fullmatch(r'[0-9a-fA-F]{64}', a.bundle_sha): sys.exit('bundle sha must be 64 hex chars')
subs = {'__RUN__': a.run, '__RUNU__': a.run.upper(), '__BUNDLE_SHA__': a.bundle_sha.lower(),
        '__HTTP_PORT__': str(a.http_port), '__PACKAGING_COMMIT__': a.packaging_commit}
def render(text):
    for k, v in subs.items(): text = text.replace(k, v)
    left = re.findall(r'__[A-Z_]+__', text)
    if left: sys.exit(f'unrendered placeholders: {sorted(set(left))}')
    return text
share = pathlib.Path(a.share); host = pathlib.Path(a.host_dir)
share.mkdir(parents=True, exist_ok=True); host.mkdir(parents=True, exist_ok=True)
written = []
for tmpl in sorted(templates.glob('*.ps1.tmpl')):
    name = tmpl.name[:-len('.ps1.tmpl')]
    dst = share / f'{name}-{a.run.upper()}-29.ps1'
    if dst.exists() and not a.force: sys.exit(f'{dst} exists (use --force)')
    dst.write_bytes(b'\xef\xbb\xbf' + render(tmpl.read_text(encoding='utf-8')).encode('utf-8'))
    written.append(dst)
ev = host / f'make-evidence-{a.run}.py'
if ev.exists() and not a.force: sys.exit(f'{ev} exists (use --force)')
ev.write_text(render((templates / 'make-evidence.py.tmpl').read_text(encoding='utf-8')), encoding='utf-8')
written.append(ev)
for p in written: print('wrote', p)
