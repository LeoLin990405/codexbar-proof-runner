import json
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE_FILE = "/tmp/codexbar-proof/server_mode"

class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        mode = "success"
        try:
            with open(MODE_FILE) as handle:
                mode = handle.read().strip() or "success"
        except OSError:
            pass
        if mode == "fail":
            self._send(500, b'{"error":"fixture endpoint stopped responding"}')
            return
        self._send(200, json.dumps({"used": 42, "resets_in_seconds": 3600}).encode())

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
