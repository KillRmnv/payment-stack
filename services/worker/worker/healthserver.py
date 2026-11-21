"""Small HTTP server shared by worker and outbox: /health + /metrics."""

import json
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

log = logging.getLogger("health")


class HealthState:
    def __init__(self, ready=False, detail="starting"):
        self.ready = ready
        self.detail = detail


def start_health_server(port, state):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                status = 200 if state.ready else 503
                body = json.dumps(
                    {
                        "status": "ok" if state.ready else "degraded",
                        "ready": state.ready,
                        "detail": state.detail,
                    }
                ).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path == "/metrics":
                body = generate_latest()
                self.send_response(200)
                self.send_header("Content-Type", CONTENT_TYPE_LATEST)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(404)
            self.end_headers()

        def log_message(self, fmt, *args):
            log.debug(fmt, *args)

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    thread = Thread(target=server.serve_forever, name=f"health-{port}", daemon=True)
    thread.start()
    return server
