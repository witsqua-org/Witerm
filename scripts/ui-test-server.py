"""Local-only slow fixture for cancellation UI tests. Never used by the app."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(3)
        data = {"service": "witerm", "protocol_version": 1, "capabilities": []}
        if self.path == "/readyz":
            data = {"status": "ok"}
        body = json.dumps(data).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    print("Slow UI-test fixture listening on 127.0.0.1:18081", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18081), Handler).serve_forever()
