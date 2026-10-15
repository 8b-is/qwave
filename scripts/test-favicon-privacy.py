#!/usr/bin/env python3
"""macOS regression: python3 scripts/test-favicon-privacy.py

Compiles the actual app loader and SQLite store, serves synthetic PNGs on
loopback, and checks isolation across two separate processes. Uses only a
fresh temporary directory, never the user's browser data. Requires Xcode's
Swift 6 compiler and Python 3 standard library; no downloaded dependencies.
"""
import collections
import http.server
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import threading
import time
import zlib

REPO = Path(__file__).resolve().parents[1]


def png(red, green, blue):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 1, 1, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes([0, red, green, blue]))) + chunk(b'IEND', b''))


def run(args, timeout=90):
    process = subprocess.Popen([str(arg) for arg in args], cwd=REPO, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise
    if process.returncode:
        raise RuntimeError(stdout + stderr)
    return stdout


def main():
    images = {'/red.png': png(255, 0, 0), '/blue.png': png(0, 0, 255)}
    requests = collections.Counter()
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            with lock:
                requests[self.path] += 1
            # Keep the concurrent-request case overlapping. A cacheable
            # response also catches accidental URLSession response reuse.
            time.sleep(0.05)
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', str(len(images[self.path])))
            self.send_header('Cache-Control', 'max-age=3600')
            self.end_headers()
            self.wfile.write(images[self.path])

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='qwave-favicon-privacy-') as temporary:
            build = Path(temporary)
            for name, data in images.items():
                (build / name.lstrip('/')).write_bytes(data)
            persistence = REPO / 'Packages/QwaveKit/Sources/Persistence'
            run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-name', 'Persistence',
                 '-emit-library', '-emit-module', '-emit-module-path', build / 'Persistence.swiftmodule',
                 '-o', build / 'libPersistence.dylib', persistence / 'SQLiteDatabase.swift',
                 persistence / 'FaviconStore.swift'])
            run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-I', build, '-L', build,
                 '-lPersistence', '-Xlinker', '-rpath', '-Xlinker', build,
                 REPO / 'Sources/QwaveApp/FaviconLoader.swift', REPO / 'Tests/FaviconPrivacy/Probe.swift',
                 '-o', build / 'probe'])
            results = []
            for mode in ['write', 'restart']:
                results.append(json.loads(run([build / 'probe', mode, build / 'browser.db',
                                               f'http://127.0.0.1:{server.server_port}',
                                               build / 'red.png', build / 'blue.png'], timeout=20)))
            # 10 network loads: repeat private URLs must not be served from
            # URLSession's cache; ordinary per-container reuse needs no load.
            assert dict(requests) == {'/red.png': 3, '/blue.png': 7}, dict(requests)
            print(json.dumps({'status': 'passed', 'processes': results,
                              'requests': dict(requests)}, indent=2))
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == '__main__':
    main()
