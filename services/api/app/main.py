import asyncio
import json
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
from .idempotency import (
    IdempotencyConflict,
    InvalidIdempotencyKey,
    normalize_key,
    request_hash,
)
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
DB_UP = Gauge("api_db_up", "Database reachable from API (1/0)")
BROKER_UP = Gauge("api_broker_up", "RabbitMQ reachable from API (1/0)")
TRANSFERS = Gauge("api_transfers", "Transfers by status", ["status"])

INSERT_TRANSFER = """
INSERT INTO transfers
    (id, amount_minor, currency, recipient, status, client_ip, idempotency_key, request_hash)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
RETURNING id, amount_minor, currency, recipient, status, provider_reference
"""
INSERT_TRANSFER_IDEMPOTENT = """
INSERT INTO transfers
    (id, amount_minor, currency, recipient, status, client_ip, idempotency_key, request_hash)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING id, amount_minor, currency, recipient, status, provider_reference
"""
SELECT_BY_IDEMPOTENCY_KEY = """
SELECT id, amount_minor, currency, recipient, status, provider_reference, request_hash
FROM transfers WHERE idempotency_key = %s
"""
INSERT_OUTBOX = "INSERT INTO transfer_outbox (transfer_id, payload) VALUES (%s, %s::jsonb)"


def count(request, response):
    path = (
        request.url.path.split("/")[1]
        if "/" in request.url.path[1:]
        else request.url.path.strip("/")
    )
    REQUESTS.labels(request.method, path or "root", response.status_code).inc()
    return response


def _db_ok():
    try:
        with psycopg.connect(settings.dsn, connect_timeout=2) as conn:
            conn.execute("SELECT 1")
        return True
    except Exception as exc:  # noqa: BLE001 — any DB error means "down", never 500
        log.warning("health db down: %s", exc)
        return False


async def _check(fn, name):
    try:
        return await asyncio.wait_for(asyncio.to_thread(fn), timeout=2.5)
    except TimeoutError:
        log.warning("health %s timed out", name)
        return False


def _health_response(request, checks):
    ok = all(v == "up" for v in checks.values())
    body = {"status": "ok" if ok else "degraded", "version": settings.app_version, "checks": checks}
    return count(request, JSONResponse(body, status_code=200 if ok else 503))


async def health(request):
    # Liveness/diagnostics: broker is part of overall health.
    db_ok, broker_ok = await asyncio.gather(
        _check(_db_ok, "db"),
        _check(lambda: broker.ping(settings), "broker"),
    )
    DB_UP.set(1 if db_ok else 0)
    BROKER_UP.set(1 if broker_ok else 0)
    return _health_response(
        request,
        {"db": "up" if db_ok else "down", "broker": "up" if broker_ok else "down"},
    )


async def ready(request):
    # Readiness: with the outbox, the API can accept transfers whenever DB is
    # writable. A broker outage must not drain traffic from the write path.
    db_ok = await _check(_db_ok, "db")
    DB_UP.set(1 if db_ok else 0)
    return _health_response(request, {"db": "up" if db_ok else "down"})


def row_to_json(row):
    # client_ip хранится в БД, но наружу не отдаем (PII, без auth любой мог читать чужое).
    return {
        "id": str(row[0]),
        "amount": f"{row[1] / 100:.2f}",
        "currency": row[2],
        "recipient": row[3],
        "status": row[4],
        "provider_reference": row[5],
    }


SELECT = "SELECT id, amount_minor, currency, recipient, status, provider_reference FROM transfers WHERE id = %s"


async def create_transfer(request):
    start = time.time()
    try:
        try:
            amount, currency, recipient = parse_transfer(await request.json())
        except (InvalidTransfer, ValueError) as exc:
            return count(request, JSONResponse({"error": str(exc)}, status_code=400))

        try:
            idempotency_key = normalize_key(request.headers.get("idempotency-key"))
        except InvalidIdempotencyKey as exc:
            return count(request, JSONResponse({"error": str(exc)}, status_code=400))
        if settings.require_idempotency_key and idempotency_key is None:
            return count(
                request,
                JSONResponse({"error": "Idempotency-Key header is required"}, status_code=400),
            )

        transfer_id = uuid.uuid4()
        client_ip = request.client.host if request.client else None
        req_hash = request_hash(amount, currency, recipient)
        request_id = request.headers.get("x-request-id") or str(transfer_id)
        replayed = False
        try:
            with psycopg.connect(settings.dsn) as conn, conn.transaction():
                values = (
                    transfer_id,
                    to_minor(amount),
                    currency,
                    recipient,
                    "PENDING",
                    client_ip,
                    idempotency_key,
                    req_hash,
                )
                if idempotency_key is None:
                    row = conn.execute(INSERT_TRANSFER, values).fetchone()
                else:
                    row = conn.execute(INSERT_TRANSFER_IDEMPOTENT, values).fetchone()
                    if row is None:
                        existing = conn.execute(
                            SELECT_BY_IDEMPOTENCY_KEY, (idempotency_key,)
                        ).fetchone()
                        if existing is None:
                            raise RuntimeError("idempotency conflict without existing row")
                        if existing[6] != req_hash:
                            raise IdempotencyConflict
                        row = existing[:6]
                        replayed = True
                if not replayed:
                    conn.execute(
                        INSERT_OUTBOX,
                        (transfer_id, json.dumps({"transfer_id": str(transfer_id)})),
                    )
        except IdempotencyConflict:
            log.warning("idempotency key reused with a different body request_id=%s", request_id)
            return count(
                request,
                JSONResponse(
                    {"error": "idempotency key reused with a different request"},
                    status_code=409,
                ),
            )
        except Exception:
            log.exception("create_transfer failed request_id=%s", request_id)
            return count(request, JSONResponse({"error": "internal"}, status_code=500))

        status = 200 if replayed else 202
        headers = {"X-Request-Id": request_id}
        if replayed:
            headers["X-Idempotent-Replay"] = "true"
        log.info(
            "transfer %s id=%s request_id=%s",
            "replayed" if replayed else "created",
            row[0],
            request_id,
        )
        return count(request, JSONResponse(row_to_json(row), status_code=status, headers=headers))
    finally:
        # Latency на всех исходах (2xx/4xx/5xx), иначе p99 занижен.
        LATENCY.labels("POST", "transfers").observe(time.time() - start)


async def get_transfer(request):
    start = time.time()
    try:
        try:
            transfer_id = uuid.UUID(request.path_params["transfer_id"])
        except ValueError:
            return count(request, JSONResponse({"error": "not found"}, status_code=404))
        try:
            with psycopg.connect(settings.dsn) as conn:
                row = conn.execute(SELECT, (transfer_id,)).fetchone()
        except Exception:
            log.exception("get_transfer db failed")
            return count(request, JSONResponse({"error": "internal"}, status_code=500))
        if row is None:
            return count(request, JSONResponse({"error": "not found"}, status_code=404))
        return count(request, JSONResponse(row_to_json(row)))
    finally:
        LATENCY.labels("GET", "transfers").observe(time.time() - start)


async def metrics(request):
    # Health gauges must be fresh even when /health is not being called; this is
    # what DbDown/BrokerDown rely on when the API itself is still serving.
    db_ok, broker_ok = await asyncio.gather(
        _check(_db_ok, "db"),
        _check(lambda: broker.ping(settings), "broker"),
    )
    DB_UP.set(1 if db_ok else 0)
    BROKER_UP.set(1 if broker_ok else 0)
    try:
        with psycopg.connect(settings.dsn) as conn:
            prow = conn.execute(
                "SELECT count(*), COALESCE(EXTRACT(EPOCH FROM (now()-min(created_at))),0) FROM transfers WHERE status='PENDING'"
            ).fetchone()
            PENDING.set(prow[0] or 0)
            OLDEST_PENDING.set(float(prow[1] or 0))
            counts = {
                status: int(count)
                for status, count in conn.execute(
                    "SELECT status, count(*) FROM transfers GROUP BY status"
                )
            }
            for status in ("PENDING", "COMPLETED", "FAILED"):
                TRANSFERS.labels(status).set(counts.get(status, 0))
    except Exception:  # noqa: BLE001 — /metrics must never 500 on DB outage
        # БД недоступна: gauges НЕ трогаем (храним последнее значение),
        # отсутствие свежих данных ловит алерт MetricsStaleBusiness.
        # Раньше писали NaN — Prometheus дропал серию и OldestPendingTooOld молчал.
        log.warning("metrics db down, keeping last gauge values")
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


app = Starlette(
    routes=[
        Route("/health", health),
        Route("/ready", ready),
        Route("/metrics", metrics),
        Route("/transfers", create_transfer, methods=["POST"]),
        Route("/transfers/{transfer_id}", get_transfer),
    ]
)
