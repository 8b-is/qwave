#!/usr/bin/env python3
"""Exercise real WebKit Markdown navigation against synthetic loopback pages.

Requires macOS, Xcode, Python 3, and the package's dependencies. No user browser
stores are used. Run separately from other package builds (two workers maximum).
"""
import argparse
import collections
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import socketserver
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--scratch-path', type=Path)
    parser.add_argument('--storage', action='store_true', help='Test isolated Markdown re-fetch storage and limits')
    parser.add_argument('--generated', action='store_true', help='Test local documents and generated error pages')
    args = parser.parse_args()
    if args.generated and args.storage:
        parser.error('Choose one of --generated or --storage')
    repo = Path(__file__).resolve().parent.parent
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    package = repo / 'Packages/QwaveKit'
    test_class = ('GeneratedPageNavigationIntegrationTests' if args.generated else
                  'MarkdownStorageIntegrationTests' if args.storage else 'MarkdownNavigationIntegrationTests')
    probe_folder = 'GeneratedNavigation' if args.generated else 'MarkdownStorage' if args.storage else 'MarkdownNavigation'
    target = package / 'Tests/EgressGuardTests' / (test_class + '.swift')
    if target.exists():
        raise SystemExit(f'Refusing to overwrite existing fixture: {target}')
    source = (repo / 'Tests' / probe_folder / 'Probe.swift').read_bytes()
    requests = []
    details = []
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            with lock:
                requests.append(self.path)
                number = requests.count(self.path)
                if args.storage and self.path != '/_storage_state':
                    details.append({'path': self.path, 'host': self.headers.get('Host', ''),
                                    'cookie': self.headers.get('Cookie', ''),
                                    'authorization': self.headers.get('Authorization', '')})
            # Keep even a failing reader-loop regression bounded and gentle.
            time.sleep(0.01 if number <= 8 else 0.05)
            status = 200
            headers = {}
            if self.path == '/_storage_state':
                with lock:
                    body = json.dumps(details)
                mime = 'application/json'
            elif self.path == '/auth/cache.md':
                cookie = self.headers.get('Cookie', '')
                marker = cookie.removeprefix('auth=')
                body, mime = '# Authenticated ' + marker, 'text/markdown'
                headers = {'Cache-Control': 'public, max-age=3600', 'Set-Cookie': 'responseOnly=discard; Path=/'}
            elif self.path in ['/redirect.md', '/transient.md']:
                status = 302
                port = self.server.server_port
                destination = f'http://127.0.0.1:{port}/transient.md' if self.path == '/redirect.md' else f'http://localhost:{port}/final.md'
                headers['Location'] = destination
                if self.path == '/redirect.md':
                    headers['Set-Cookie'] = 'transient=one-request; Path=/'
                body, mime = '', 'text/markdown'
            elif self.path == '/final.md':
                body, mime = '# Redirected destination', 'text/markdown'
                headers['Set-Cookie'] = 'responseOnly=discard; Path=/'
            elif self.path == '/cookie-slow.md':
                body, mime = '# Cancelled old response', 'text/markdown'
                headers['Set-Cookie'] = 'late=discard; Path=/'
            elif self.path == '/basic.md':
                status = 401
                headers['WWW-Authenticate'] = 'Basic realm="synthetic-qwave-test"'
                body, mime = 'Authentication required', 'text/plain'
            elif self.path in ['/oversize.md', '/oversize-stream.md']:
                body, mime = 'x' * (8 * 1024 * 1024 + 1), 'text/markdown'
            elif self.path == '/_state':
                with lock:
                    body = json.dumps(dict(collections.Counter(requests)))
                mime = 'application/json'
            elif self.path == '/direct.md':
                body, mime = '# Active Markdown fixture\n\nCookies: ' + self.headers.get('Cookie', ''), 'text/markdown'
                value = 'from-webkit' if number == 1 else 'refetch-must-not-replace'
                headers['Set-Cookie'] = f'nativeResponse={value}; Path=/'
            elif self.path == '/not-found.html':
                status = 404
                body, mime = '<script>window.syntheticErrorScript=true;</script>untrusted error', 'text/html'
            elif self.path == '/connection-failure.html':
                body, mime = '<h1>Unwanted network replay</h1>', 'text/html'
            elif self.path == '/forbidden.md':
                status = 403
                body = '# Untrusted error\n<script>window.syntheticErrorScript=true;</script>'
                mime = 'text/markdown'
            elif self.path == '/slow.md':
                if number >= 2:
                    time.sleep(0.8)
                body, mime = '# Stale slow Markdown fixture', 'text/markdown'
            elif self.path == '/newer.html':
                body = '<html><head><title>Newer</title></head><body>Newer page fixture</body></html>'
                mime = 'text/html'
            else:
                self.send_error(404)
                return
            data = body.encode()
            try:
                self.send_response(status)
                self.send_header('Content-Type', mime)
                if self.path != '/oversize-stream.md':
                    self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', headers.pop('Cache-Control', 'no-store'))
                for key, value in headers.items():
                    self.send_header(key, value)
                self.end_headers()
                if self.path == '/cookie-slow.md':
                    time.sleep(0.8)
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Expected when WebKit cancels a Markdown response.

        def log_message(self, *args):
            pass

    class Server(http.server.ThreadingHTTPServer):
        def server_bind(self):
            # Avoid hostname/DNS lookup; this listener is loopback only.
            socketserver.TCPServer.server_bind(self)
            self.server_name = 'localhost'
            self.server_port = self.server_address[1]

    server = Server(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    command = ['xcrun', 'swift', 'test', '-c', 'release', '--package-path', str(package),
               '--jobs', '2', '--disable-automatic-resolution', '--filter', (test_class + '|MarkdownLifecycleTests|MarkdownResponseTests|EgressGuardTests|MarkdownCompilerTests|MarkdownSanitisationTests|MarkdownSourceBlockTests') if args.storage else test_class]
    if args.scratch_path:
        command += ['--scratch-path', str(args.scratch_path.resolve())]
    env = os.environ.copy()
    env['QWAVE_PROBE_URL'] = f'http://127.0.0.1:{server.server_port}'
    env['QWAVE_PROBE_OUTPUT'] = str(output / 'observations.json')
    result = {'command': command, 'timeout_seconds': 300, 'status': 'running',
              'probe_sha256': hashlib.sha256(source).hexdigest()}
    started = time.monotonic()
    owns_fixture = False
    try:
        # Exclusive creation also protects against another test runner.
        with target.open('xb') as fixture:
            owns_fixture = True
            fixture.write(source)
        with (output / 'tests.log').open('w') as log:
            process = subprocess.Popen(command, cwd=repo, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
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
        if owns_fixture and target.exists() and target.read_bytes() == source:
            target.unlink()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        result['seconds'] = round(time.monotonic() - started, 2)
        with lock:
            result['request_counts'] = dict(collections.Counter(requests))
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
