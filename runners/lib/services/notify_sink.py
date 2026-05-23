#!/usr/bin/env python3
"""Tiny HTTP sink that accepts POSTs and returns 200.

Used by webhook-pattern examples (countdown-*, etc.) so CI doesn't depend on
an external service like ntfy.sh. Reads ``NOTIFY_SINK_HOST`` /
``NOTIFY_SINK_PORT`` from env. Mirrors the shape of mock_llm.py.
"""

import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


HOST = os.environ.get("NOTIFY_SINK_HOST", "127.0.0.1")
PORT = int(os.environ.get("NOTIFY_SINK_PORT", "9999"))


class Handler(BaseHTTPRequestHandler):
    def _ok(self, body: bytes = b"ok") -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 — stdlib API
        self._ok()

    def do_POST(self) -> None:  # noqa: N802 — stdlib API
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 0:
            try:
                self.rfile.read(length)
            except Exception:
                pass
        self._ok()

    def do_PUT(self) -> None:  # noqa: N802 — stdlib API
        self.do_POST()

    def log_message(self, *_a, **_k) -> None:  # quiet
        pass


def main() -> None:
    server = HTTPServer((HOST, PORT), Handler)
    print(f"notify_sink listening on http://{HOST}:{PORT}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
