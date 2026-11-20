import contextlib
import logging
import time
import uuid

import psycopg
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from starlette.applications import Starlette
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from . import broker
from .config import load_settings
from .validation import InvalidTransfer, parse_transfer, to_minor

settings = load_settings()
logging.basicConfig(
    level=settings.log_level, format="%(asctime)s %(levelname)s %(name)s %(message)s"
)
log = logging.getLogger("api")
# Never log secrets: only safe fields.
log.info("starting api version=%s log_level=%s", settings.app_version, settings.log_level)

REQUESTS = Counter("api_requests_total", "HTTP requests", ["method", "path", "status"])
LATENCY = Histogram("api_request_duration_seconds", "Request latency", ["method", "path"])
PENDING = Gauge("api_pending_transfers", "Pending transfers")
OLDEST_PENDING = Gauge("api_oldest_pending_seconds", "Age of oldest PENDING transfer")


def count(request, response):
    path = (
        request.url.path.split("/")[1]
        if "/" in request.url.path[1:]
        else request.url.path.strip("/")
    )
    REQUESTS.labels(request.method, path or "root", response.status_code).inc()
    return response


async def health(request):
    checks = {}
    try:
        with psycopg.connect(settings.dsn) as conn:
            conn.execute("SELECT 1")
        checks["db"] = "up"
    except Exception as exc:  # noqa: BLE001 — any DB error means "down", never 500
        log.warning("health db down: %s", exc)
        checks["db"] = "down"
    checks["broker"] = "up" if broker.ping(settings) else "down"
    ok = all(v == "up" for v in checks.values())
    body = {"status": "ok" if ok else "degraded", "version": settings.app_version, "checks": checks}
    resp = JSONResponse(body, status_code=200 if ok else 503)
    return count(request, resp)


def row_to_json(row):
    return {
        "id": str(row[0]),
        "amount": f"{row[1] / 100:.2f}",
        "currency": row[2],
        "recipient": row[3],
        "status": row[4],
        "provider_reference": row[5],
        "client_ip": row[6],
    }


SELECT = "SELECT id, amount_minor, currency, recipient, status, provider_reference, client_ip FROM transfers WHERE id = %s"


async def create_transfer(request):
    start = time.time()
    try:
        try:
            amount, currency, recipient = parse_transfer(await request.json())
        except (InvalidTransfer, ValueError) as exc:
            return count(request, JSONResponse({"error": str(exc)}, status_code=400))
        transfer_id = uuid.uuid4()
        client_ip = request.client.host if request.client else None
        request_id = request.headers.get("x-request-id", str(transfer_id))
        try:
            with psycopg.connect(settings.dsn) as conn:
                conn.execute(
                    "INSERT INTO transfers (id, amount_minor, currency, recipient, status, client_ip) VALUES (%s, %s, %s, %s, %s, %s)",
                    (transfer_id, to_minor(amount), currency, recipient, "PENDING", client_ip),
                )
                row = conn.execute(SELECT, (transfer_id,)).fetchone()
            broker.publish(settings, {"transfer_id": str(transfer_id)})
        except Exception:
            log.exception("create_transfer failed request_id=%s", request_id)
            return count(request, JSONResponse({"error": "internal"}, status_code=500))
        log.info("transfer created id=%s request_id=%s", transfer_id, request_id)
        resp = JSONResponse(row_to_json(row), status_code=202, headers={"X-Request-Id": request_id})
        return count(request, resp)
    finally:
        # Latency на всех исходах (2xx/4xx/5xx), иначе p99 занижен.
        LATENCY.labels("POST", "transfers").observe(time.time() - start)


async def get_transfer(request):
    try:
        transfer_id = uuid.UUID(request.path_params["transfer_id"])
    except ValueError:
        return count(request, JSONResponse({"error": "not found"}, status_code=404))
    with psycopg.connect(settings.dsn) as conn:
        row = conn.execute(SELECT, (transfer_id,)).fetchone()
    if row is None:
        return count(request, JSONResponse({"error": "not found"}, status_code=404))
    return count(request, JSONResponse(row_to_json(row)))


async def metrics(request):
    try:
        with psycopg.connect(settings.dsn) as conn:
            prow = conn.execute(
                "SELECT count(*), COALESCE(EXTRACT(EPOCH FROM (now()-min(created_at))),0) FROM transfers WHERE status='PENDING'"
            ).fetchone()
            PENDING.set(prow[0] or 0)
            OLDEST_PENDING.set(float(prow[1] or 0))
    except Exception:  # noqa: BLE001 — /metrics must never 500 on DB outage
        # БД недоступна: не отдаем stale значения — сбрасываем в NaN,
        # иначе OldestPendingTooOld зависнет на последнем значении.
        with contextlib.suppress(Exception):  # gauges best-effort, never raise
            PENDING.set(float("nan"))
            OLDEST_PENDING.set(float("nan"))
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


app = Starlette(
    routes=[
        Route("/health", health),
        Route("/ready", health),
        Route("/metrics", metrics),
        Route("/transfers", create_transfer, methods=["POST"]),
        Route("/transfers/{transfer_id}", get_transfer),
    ]
)
