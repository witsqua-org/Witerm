"""Local-only meeting point for the joint Mac and iPhone continuity UI tests.

The Mac test runner is sandboxed and can write only inside its own container,
which the simulator's runner may not be allowed to read. Both runners can
reach loopback, so they exchange their few signals here instead: PUT stores a
signal, GET returns it (404 until it exists). Signals live in memory only and
vanish when the server stops. Never used by the app.
"""
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 18082
NAME = re.compile(r"^/signal/([a-z][a-z0-9.-]{0,40})$")
LIMIT = 16 * 1024
signals: dict[str, bytes] = {}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status, body=b""):
        try:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        match = NAME.match(self.path)
        if not match:
            return self._reply(404)
        with lock:
            body = signals.get(match.group(1))
        self._reply(200, body) if body is not None else self._reply(404)

    def do_PUT(self):
        match = NAME.match(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        if not match or length > LIMIT:
            return self._reply(400)
        body = self.rfile.read(length)
        with lock:
            signals[match.group(1)] = body
        print("signal", match.group(1), flush=True)
        self._reply(204)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else PORT
    print(f"E2E signal server listening on 127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
