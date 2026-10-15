from pathlib import Path
from datetime import datetime, timezone
import hashlib
import http.server
import json
import os
import signal
import socketserver
import subprocess
import threading
import time

import argparse
parser = argparse.ArgumentParser()
parser.add_argument('--output-dir', type=Path, required=True)
parser.add_argument('--scratch-path', type=Path, required=True)
parser.add_argument('--native-input', action='store_true', help='Use native AppKit input in a synthetic WebKit window')
args = parser.parse_args()
OUT = args.output_dir.resolve()
OUT.mkdir(parents=True, exist_ok=True)
REPO = Path(__file__).resolve().parent.parent
HEAD = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
source = (REPO / 'Tests/InternalMessageBoundary' / ('NativeInputProbe.swift' if args.native_input else 'Probe.swift')).read_bytes()
target = REPO / 'Packages/QwaveKit/Tests/EgressGuardTests/InternalMessageBoundaryTests.swift'
requests = []

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        if self.path != '/synthetic.md':
            self.send_error(404)
            return
        body = b'''# Synthetic remote Markdown
<script>window.webkit.messageHandlers.qwave.postMessage({type:'submit',query:'synthetic query'});window.webkit.messageHandlers.qwave.postMessage({type:'remember',scope:'page',text:'synthetic memory'});window.webkit.messageHandlers.qwave.postMessage({type:'summarize',range:'today'});</script>
'''
        self.send_response(200)
        self.send_header('Content-Type', 'text/markdown')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]

server = Server(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
command = ['xcrun', 'swift', 'test', '-c', 'release', '--package-path', str(REPO / 'Packages/QwaveKit'),
           '--jobs', '2', '--disable-automatic-resolution', '--filter',
           'InternalMessageNativeInputTests' if args.native_input else 'InternalMessageBoundaryTests',
           '--scratch-path', str(args.scratch_path.resolve())]
env = os.environ.copy()
env['QWAVE_PROBE_URL'] = f'http://127.0.0.1:{server.server_port}/synthetic.md'
env['QWAVE_PROBE_OUTPUT'] = str(OUT / 'observations.json')
result = {'at': datetime.now(timezone.utc).isoformat(), 'source_sha': HEAD, 'command': command,
          'timeout_seconds': 300, 'status': 'running', 'probe_sha256': hashlib.sha256(source).hexdigest()}
started = time.monotonic()
owned = False
try:
    with target.open('xb') as fixture:
        owned = True
        fixture.write(source)
    with (OUT / 'tests.log').open('w') as log:
        process = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            result['exit'] = process.wait(timeout=300)
            result['timed_out'] = False
        except subprocess.TimeoutExpired:
            result['timed_out'] = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            result['exit'] = process.returncode
    result['status'] = 'passed' if result['exit'] == 0 else 'failed'
finally:
    if owned and target.exists() and target.read_bytes() == source:
        target.unlink()
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)
    result['elapsed_seconds'] = round(time.monotonic() - started, 2)
    result['requests'] = requests
    result['fixture_removed'] = not target.exists()
    (OUT / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
