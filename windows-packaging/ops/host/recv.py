from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import re, sys
PORT = int(sys.argv[1]); ROOT = Path(sys.argv[2]); ALLOWED = sys.argv[3] if len(sys.argv) > 3 else '172.19.103.27'
ROOT.mkdir(parents=True, exist_ok=True)
SAFE = re.compile(r'^[A-Za-z0-9 ._-]{1,120}$')
class H(BaseHTTPRequestHandler):
    def do_PUT(self):
        from urllib.parse import unquote
        name = unquote(self.path).lstrip('/')
        if self.client_address[0] != ALLOWED or not SAFE.match(name) or name.startswith('.'):
            self.send_error(403); return
        size = int(self.headers.get('Content-Length', '0')); tmp = ROOT / (name + '.partial')
        with tmp.open('wb') as f:
            remaining = size
            while remaining:
                b = self.rfile.read(min(1 << 20, remaining))
                if not b: raise ConnectionError('early EOF')
                f.write(b); remaining -= len(b)
        tmp.rename(ROOT / name)
        self.send_response(200); self.end_headers(); self.wfile.write(b'OK')
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'recv-r10 up\n')
    def log_message(self, fmt, *a):
        sys.stderr.write(("%s " % self.client_address[0]) + (fmt % a) + "\n")
HTTPServer(('172.19.103.18', PORT), H).serve_forever()
