"""Tiny Alertmanager webhook sink for the stand.

It is intentionally dependency-free: receives Alertmanager webhooks, keeps a
bounded in-memory list for the alert self-test, and exposes /health + /metrics.
Replace the webhook URL with a real pager/webhook in production.
"""

import json
import logging
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("ALERT_SINK_PORT", "8080"))
MAX_ALERTS = 500
_lock = threading.Lock()
_alerts = []
_payloads = 0
log = logging.getLogger("alert-sink")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def snapshot():
    with _lock:
        return list(_alerts)


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, json.dumps({"status": "ok"}).encode())
        elif self.path == "/alerts":
            self._send(200, json.dumps(snapshot()).encode())
        elif self.path == "/metrics":
            with _lock:
                body = (
                    "# HELP alert_sink_up Alert sink process is up\n"
                    "# TYPE alert_sink_up gauge\n"
                    "alert_sink_up 1\n"
                    "# HELP alert_sink_alertmanager_payloads_total Webhook POSTs\n"
                    "# TYPE alert_sink_alertmanager_payloads_total counter\n"
                    f"alert_sink_alertmanager_payloads_total {_payloads}\n"
                    "# HELP alert_sink_alerts_total Alerts currently stored\n"
                    "# TYPE alert_sink_alerts_total gauge\n"
                    f"alert_sink_alerts_total {len(_alerts)}\n"
                ).encode()
            self._send(200, body, "text/plain; version=0.0.4")
        else:
            self._send(404, b"{}")

    def do_POST(self):
        global _payloads
        if self.path == "/reset":
            with _lock:
                _alerts.clear()
                _payloads = 0
            self._send(200, b'{"reset":true}')
            return
        if self.path != "/alerts":
            self._send(404, b"{}")
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw or b"[]")
        except json.JSONDecodeError:
            self._send(400, b'{"error":"invalid json"}')
            return
        if isinstance(payload, list):
            alerts = payload
        elif isinstance(payload, dict) and isinstance(payload.get("alerts"), list):
            # Alertmanager webhook v4 sends {"status":..., "alerts":[...]}.
            alerts = payload["alerts"]
        else:
            alerts = [payload]
        with _lock:
            _payloads += 1
            _alerts.extend(alerts)
            del _alerts[:-MAX_ALERTS]
        for alert in alerts:
            labels = alert.get("labels", {})
            log.info(
                "alert received name=%s status=%s", labels.get("alertname"), alert.get("status")
            )
        self._send(200, b"{}")

    def log_message(self, fmt, *args):
        log.debug(fmt, *args)


if __name__ == "__main__":
    log.info("alert sink listening on :%s", PORT)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
